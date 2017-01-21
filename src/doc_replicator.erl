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

-export([start_link/4]).

start_link(Module, Name, GetNodes, ServerName) ->
    proc_lib:start_link(erlang, apply, [fun start_loop/4, [Module, Name, GetNodes, ServerName]]).

start_loop(Module, Name, GetNodes, ServerName) ->
    erlang:register(Name, self()),
    proc_lib:init_ack({ok, self()}),
    DocMgr = replicated_storage:wait_for_startup(),

    %% anytime we disconnect or reconnect, force a replicate event.
    erlang:spawn_link(
      fun () ->
              ok = net_kernel:monitor_nodes(true),
              nodeup_monitoring_loop(DocMgr)
      end),

    %% Explicitly ask all available nodes to send their documents to us
    [{ServerName, N} ! replicate_newnodes_docs ||
        N <- GetNodes()],

    loop(Module, GetNodes, ServerName, []).

loop(Module, GetNodes, ServerName, RemoteNodes) ->
    NewRemoteNodes =
        receive
            {replicate_change, Doc} ->
                [replicate_change_to_node(Module, ServerName, Node, Doc)
                 || Node <- RemoteNodes],
                RemoteNodes;
            {replicate_newnodes_docs, Docs} ->
                AllNodes = GetNodes(),
                ?log_debug("doing replicate_newnodes_docs"),

                NewNodes = AllNodes -- RemoteNodes,
                case NewNodes of
                    [] ->
                        ok;
                    _ ->
                        [monitor(process, {ServerName, Node}) || Node <- NewNodes],
                        [replicate_change_to_node(Module, ServerName, S, D)
                         || S <- NewNodes,
                            D <- Docs]
                end,
                AllNodes;
            {'$gen_call', From, {pull_docs, Nodes, Timeout}} ->
                gen_server:reply(From, handle_pull_docs(ServerName, Nodes, Timeout)),
                RemoteNodes;
            {'DOWN', _Ref, _Type, {Server, RemoteNode}, Error} ->
                ?log_warning("Remote server node ~p process down: ~p",
                             [{Server, RemoteNode}, Error]),
                RemoteNodes -- [RemoteNode];
            Msg ->
                ?log_error("Got unexpected message: ~p", [Msg]),
                exit({unexpected_message, Msg})
        end,

    loop(Module, GetNodes, ServerName, NewRemoteNodes).

replicate_change_to_node(Module, ServerName, Node, Doc) ->
    ?log_debug("Sending ~p to ~p", [Module:get_id(Doc), Node]),
    gen_server:cast({ServerName, Node}, {replicated_update, Doc}).

nodeup_monitoring_loop(Parent) ->
    receive
        {nodeup, _} ->
            ?log_debug("got nodeup event. Considering ddocs replication"),
            Parent ! replicate_newnodes_docs;
        _ ->
            ok
    end,
    nodeup_monitoring_loop(Parent).

handle_pull_docs(ServerName, Nodes, Timeout) ->
    {RVs, BadNodes} = gen_server:multi_call(Nodes, ServerName, get_all_docs, Timeout),
    case BadNodes of
        [] ->
            lists:foreach(
              fun ({_N, Docs}) ->
                      [gen_server:cast(ServerName, {replicated_update, Doc}) ||
                          Doc <- Docs]
              end, RVs),
            gen_server:call(ServerName, sync, Timeout);
        _ ->
            {error, {bad_nodes, BadNodes}}
    end.
