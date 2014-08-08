%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
%% @doc suprevisor for dcp_replicator's
%%
-module(dcp_sup).

-behavior(supervisor).

-include("ns_common.hrl").

-export([start_link/1, init/1]).

-export([get_actual_replications/1, set_desired_replications/2, nuke/1]).

start_link(Bucket) ->
    supervisor:start_link({local, server_name(Bucket)}, ?MODULE, []).

-spec server_name(bucket_name()) -> atom().
server_name(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).

init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.

get_actual_replications(Bucket) ->
    case get_producer_nodes(Bucket) of
        not_running ->
            not_running;
        Nodes ->
            lists:sort([{Node, dcp_replicator:get_partitions(Node, Bucket)} || Node <- Nodes])
    end.

set_desired_replications(Bucket, DesiredReps) ->
    ProducerNodes = get_producer_nodes(Bucket),
    NeededNodes = [Node || {Node, [_|_]} <- DesiredReps],

    [kill_replicator(Bucket, Node) || Node <- ProducerNodes -- NeededNodes],

    [start_replicator(Bucket, Node) || Node <- NeededNodes -- ProducerNodes],

    [dcp_replicator:setup_replication(Node, Bucket, Partitions)
     || {Node, [_|_] = Partitions} <- DesiredReps].

-spec get_producer_nodes(bucket_name()) -> list() | not_running.
get_producer_nodes(Bucket) ->
    try supervisor:which_children(server_name(Bucket)) of
        RawKids ->
            [Id || {Id, _Child, _Type, _Mods} <- RawKids]
    catch exit:{noproc, _} ->
            not_running
    end.

build_child_spec(ProducerNode, Bucket) ->
    {ProducerNode,
     {dcp_replicator, start_link, [ProducerNode, Bucket]},
     temporary, 60000, worker, [dcp_replicator]}.


start_replicator(Bucket, ProducerNode) ->
    ?log_debug("Starting DCP replication from ~p for bucket ~p", [ProducerNode, Bucket]),

    case supervisor:start_child(server_name(Bucket),
                                build_child_spec(ProducerNode, Bucket)) of
        {ok, _} -> ok;
        {ok, _, _} -> ok
    end.

kill_replicator(Bucket, ProducerNode) ->
    ?log_debug("Going to stop DCP replication from ~p for bucket ~p", [ProducerNode, Bucket]),
    _ = supervisor:terminate_child(server_name(Bucket), ProducerNode),
    ok.

get_children(Bucket) ->
    try supervisor:which_children(server_name(Bucket)) of
        RawKids ->
            [Child || {_, Child, _, _} <- RawKids]
    catch exit:{noproc, _} ->
            []
    end.

nuke(Bucket) ->
    Children = get_children(Bucket),
    misc:terminate_and_wait({shutdown, nuke}, Children),

    Connections = get_remaining_connections(Bucket),
    misc:parallel_map(
      fun (ConnName) ->
              dcp_proxy:nuke_connection(consumer, ConnName, node(), Bucket)
      end,
      Connections,
      infinity),
    Children =/= [] andalso Connections =/= [].

get_remaining_connections(Bucket) ->
    {ok, Connections} =
        ns_memcached:raw_stats(
          node(), Bucket, <<"dcp">>,
          fun(<<"eq_dcpq:ns_server:", K/binary>>, <<"consumer">>, Acc) ->
                  case binary:longest_common_suffix([K, <<":type">>]) of
                      5 ->
                          ["ns_server:" ++ binary_to_list(binary:part(K, {0, byte_size(K) - 5})) | Acc];
                      _ ->
                          Acc
                  end;
             (_, _, Acc) ->
                  Acc
          end, []),
    Connections.
