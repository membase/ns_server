%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc this module implements upgrade of erlang XDCR configuration to goxdcr
%%

-module(goxdcr_upgrade).
-include("ns_common.hrl").

-export([maybe_upgrade/4,
         config_upgrade/1,
         updates_allowed/0]).

maybe_upgrade(undefined, _, _, _) ->
    %% this happens during the cluster initialization. no upgrade needed
    ok;
maybe_upgrade(CurrentVersion, NewVersion, Config, NodesWanted) when CurrentVersion < [4, 0] andalso
                                                                    NewVersion >= [4, 0] ->
    ?log_debug("Initiating goxdcr upgrade due to version change from ~p to ~p",
               [CurrentVersion, NewVersion]),
    upgrade(Config, NodesWanted);
maybe_upgrade(_, _, _, _) ->
    ok.

upgrade(Config, Nodes) ->
    try
        case ns_config:search(Config, goxdcr_upgrade) of
            false ->
                ns_config:set(goxdcr_upgrade, started),
                do_upgrade(Config, Nodes);
            {value, started} ->
                ?log_debug("Found unfinished goxdcr upgrade. Continue."),
                do_upgrade(Config, Nodes)
        end,
        ok
    catch T:E ->
            ale:error(?USER_LOGGER, "Unsuccessful goxdcr upgrade.~n~p",
                      [{T,E,erlang:get_stacktrace()}]),
            {error, goxdcr_upgrade}
    end.


do_upgrade(Config, Nodes) ->
    %% this will make sure that goxdcr_upgrade is propagated everywhere
    %% and xdcr rest api is blocked on all nodes
    sync_config(Nodes),

    %% this will make sure that our node has latest replications
    ?log_debug("Pull replication docs from other nodes synchronously."),
    ok = doc_replicator:pull_docs(xdcr, Nodes -- [ns_node_disco:ns_server_node()]),

    Json = build_json(),
    ?log_debug("Starting goxdcr upgrade with the following configuration: ~p", [Json]),

    ok = run_upgrade(Config, Json),
    ?log_debug("Goxdcr configuration was successfully upgraded").

config_upgrade(Config) ->
    StopRequests = [{set, {node, N, stop_xdcr}, true} || N <- ns_node_disco:nodes_wanted(Config)],
    [{delete, goxdcr_upgrade} | StopRequests].

run_upgrade(Config, Json) ->
    {Name, Cmd, Args, Opts} = ns_ports_setup:create_goxdcr_upgrade_spec(Config),
    Log = proplists:get_value(log, Opts),
    true = Log =/= undefined,

    Logger = start_logger(Name, Log),

    Opts0 = proplists:delete(log, Opts),
    Opts1 = Opts0 ++ [{args, Args}, {line, 8192}],

    misc:executing_on_new_process(
      fun () ->
              Port = open_port({spawn_executable, Cmd}, Opts1),

              Port ! {self(), {command, Json}},
              Port ! {self(), {command, <<"\n">>}},
              Port ! {self(), {command, <<"\n">>}},

              process_upgrade_output(Port, Logger)
      end).

process_upgrade_output(Port, Logger) ->
    receive
        {Port, {data, {_, Msg}}} ->
            ale:debug(Logger, [Msg, $\n]),
            process_upgrade_output(Port, Logger);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Status}} ->
            ?log_error("Goxdcr returned error status ~p", [Status]),
            throw({unexpected_status, Status});
        Msg ->
            ?log_error("Got unexpected message. Port = ~p", [Port]),
            throw({unexpected_message, Msg})
    end.

start_logger(Name, Log) ->
    Sink = Logger = Name,
    ok = ns_server:start_disk_sink(Sink, Log),
    ale:stop_logger(Logger),
    ok = ale:start_logger(Logger, debug, ale_noop_formatter),
    ok = ale:add_sink(Logger, Sink, debug),
    Logger.

build_json() ->
    RemoteClusters = menelaus_web_remote_clusters:get_remote_clusters(),
    ClustersData = lists:map(fun (KV) ->
                                     menelaus_web_remote_clusters:build_remote_cluster_info(KV, true)
                             end, RemoteClusters),

    RepsData =
        lists:map(fun (Props) ->
                          Id = misc:expect_prop_value(id, Props),
                          {ok, Doc} = xdc_rdoc_api:get_full_replicator_doc(Id),
                          {Props ++ menelaus_web_xdc_replications:build_replication_settings(Doc)}
                  end, xdc_rdoc_api:find_all_replication_docs()),

    GlobalSettings = menelaus_web_xdc_replications:build_global_replication_settings(),

    ejson:encode({[{remoteClusters, ClustersData},
                   {replicationDocs, RepsData},
                   {replicationSettings, {GlobalSettings}}
                  ]}).

sync_config(Nodes) ->
    try
        ns_config:sync_announcements(),
        case ns_config_rep:synchronize_remote(Nodes) of
            ok -> ok;
            {error, BadNodes} ->
                ale:error(?USER_LOGGER, "Was unable to sync goxdcr config update to some nodes: ~p",
                          [BadNodes]),
                throw({error, sync_config})
        end
    catch T:E ->
            ale:error(?USER_LOGGER, "Got problems trying to replicate goxdcr config update~n~p",
                      [{T,E,erlang:get_stacktrace()}]),
            throw({error, sync_config})
    end.

updates_allowed() ->
    case ns_config:search(goxdcr_upgrade) of
        {value, started} ->
            false;
        false ->
            true
    end.
