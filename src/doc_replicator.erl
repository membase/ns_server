%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
%% @doc process responsible for pushing document changes to other nodes
%%

-module(doc_replicator).

-include("ns_common.hrl").
-include("couch_db.hrl").

-export([start_link/1, start_link_xdcr/0, server_name/1]).

start_link_xdcr() ->
    proc_lib:start_link(erlang, apply, [fun start_loop/1, [xdcr]]).

start_link(Bucket) ->
    single_bucket_sup:ignore_if_not_couchbase_bucket(
      Bucket,
      fun (_) ->
              proc_lib:start_link(erlang, apply, [fun start_loop/1, [Bucket]])
      end).

start_loop(Bucket) ->
    ServerName = doc_replication_srv:proxy_server_name(Bucket),
    erlang:register(server_name(Bucket), self()),
    proc_lib:init_ack({ok, self()}),
    DocMgr = ns_couchdb_api:wait_for_doc_manager(),

    %% anytime we disconnect or reconnect, force a replicate event.
    erlang:spawn_link(
      fun () ->
              ok = net_kernel:monitor_nodes(true),
              nodeup_monitoring_loop(DocMgr)
      end),

    %% Explicitly ask all available nodes to send their documents to us
    [{ServerName, N} ! replicate_newnodes_docs ||
        N <- get_remote_nodes(Bucket)],

    loop(Bucket, ServerName, []).

loop(Bucket, ServerName, RemoteNodes) ->
    NewRemoteNodes =
        receive
            {replicate_change, Doc} ->
                [replicate_change_to_node(ServerName, Node, Doc)
                 || Node <- RemoteNodes],
                RemoteNodes;
            {replicate_newnodes_docs, Docs} ->
                AllNodes = get_remote_nodes(Bucket),
                ?log_debug("doing replicate_newnodes_docs"),

                NewNodes = AllNodes -- RemoteNodes,
                case NewNodes of
                    [] ->
                        ok;
                    _ ->
                        [monitor(process, {ServerName, Node}) || Node <- NewNodes],
                        [replicate_change_to_node(ServerName, S, D)
                         || S <- NewNodes,
                            D <- Docs]
                end,
                AllNodes;
            {'DOWN', _Ref, _Type, {Server, RemoteNode}, Error} ->
                ?log_warning("Remote server node ~p process down: ~p",
                             [{Server, RemoteNode}, Error]),
                RemoteNodes -- [RemoteNode];
            Msg ->
                ?log_error("Got unexpected message: ~p", [Msg]),
                exit({unexpected_message, Msg})
        end,

    loop(Bucket, ServerName, NewRemoteNodes).

replicate_change_to_node(ServerName, Node, Doc) ->
    ?log_debug("Sending ~s to ~s", [Doc#doc.id, Node]),
    gen_server:cast({ServerName, Node}, {replicated_update, Doc}).

get_remote_nodes(xdcr) ->
    ns_node_disco:nodes_wanted() -- [node()];
get_remote_nodes(Bucket) ->
    case ns_bucket:get_bucket(Bucket) of
        {ok, Conf} ->
            proplists:get_value(servers, Conf) -- [node()];
        not_present ->
            []
    end.

nodeup_monitoring_loop(Parent) ->
    receive
        {nodeup, _} ->
            ?log_debug("got nodeup event. Considering ddocs replication"),
            Parent ! replicate_newnodes_docs;
        _ ->
            ok
    end,
    nodeup_monitoring_loop(Parent).

server_name(xdcr) ->
    list_to_atom("xdcr_" ++ ?MODULE_STRING);
server_name(Bucket) ->
    list_to_atom("capi_" ++ ?MODULE_STRING ++ "-" ++ Bucket).
