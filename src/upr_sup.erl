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
%% @doc suprevisor for upr_replicator's
%%
-module(upr_sup).

-behavior(supervisor).

-include("ns_common.hrl").

-export([start_link/1, init/1]).

-export([get_actual_replications/1, setup_replication/3]).

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
            lists:sort([{Node, upr_replicator:get_partitions(Node, Bucket)} || Node <- Nodes])
    end.

setup_replication(Bucket, ProducerNode, Partitions) ->
    case Partitions of
        [] ->
            kill_replicator(Bucket, ProducerNode);
        _ ->
            maybe_start_replicator(Bucket, ProducerNode),
            upr_replicator:setup_replication(ProducerNode, Bucket, Partitions)
    end.

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
     {upr_replicator, start_link, [ProducerNode, Bucket]},
     temporary, 60000, worker, [upr_replicator]}.


maybe_start_replicator(Bucket, ProducerNode) ->
    case lists:member(ProducerNode, get_producer_nodes(Bucket)) of
        false ->
            ?log_info("Starting UPR replication from ~p for bucket ~p", [ProducerNode, Bucket]),

            case supervisor:start_child(server_name(Bucket),
                                        build_child_spec(ProducerNode, Bucket)) of
                {ok, _} -> ok;
                {ok, _, _} -> ok
            end;
        true ->
            ok
    end.

kill_replicator(Bucket, ProducerNode) ->
    ?log_info("Going to stop UPR replication from ~p for bucket ~p", [ProducerNode, Bucket]),
    _ = supervisor:terminate_child(server_name(Bucket), ProducerNode),
    ok.
