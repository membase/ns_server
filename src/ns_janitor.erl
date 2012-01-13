%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% Monitor and maintain the vbucket layout of each bucket.
%%
-module(ns_janitor).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([cleanup/2, current_states/2]).

-define(WAIT_FOR_MEMCACHED_TRIES, 5).

-spec cleanup(string(), list()) -> ok | {error, any()}.
cleanup(Bucket, Options) ->
    {ok, Config} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(Config) of
        membase -> do_cleanup(Bucket, Options, Config);
        _ -> ok
    end.

do_cleanup(Bucket, Options, Config) ->
    {Map, Servers} =
        case proplists:get_value(map, Config) of
            X when X == undefined; X == [] ->
                S = ns_cluster_membership:active_nodes(),
                Config1 = lists:keystore(servers, 1, Config, {servers, S}),
                NumVBuckets = proplists:get_value(num_vbuckets, Config1),
                NumReplicas = ns_bucket:num_replicas(Config1),
                ns_bucket:set_bucket_config(Bucket, Config1),
                wait_for_memcached(S, Bucket, up),
                NewMap = case ns_janitor_map_recoverer:read_existing_map(Bucket, S, NumVBuckets, NumReplicas) of
                             {ok, M} ->
                                 M;
                             {error, no_map} ->
                                 ns_rebalancer:generate_initial_map(Config1)
                         end,

                Config6 = lists:keystore(map, 1, Config1, {map, NewMap}),
                ns_bucket:set_bucket_config(Bucket, Config6),
                {NewMap, S};
            M ->
                {M, proplists:get_value(servers, Config)}
        end,
    case Servers of
        [] -> ok;
        _ ->
            case {wait_for_memcached(Servers, Bucket, connected, proplists:get_value(timeout, Options, 5)),
                  proplists:get_bool(best_effort, Options)} of
                {[_|_] = Down, false} ->
                    ?log_error("Bucket ~p not yet ready on ~p", [Bucket, Down]),
                    {error, wait_for_memcached_failed};
                {Down, _} ->
                    ReadyServers = ordsets:subtract(lists:sort(Servers),
                                                    lists:sort(Down)),
                    Map1 =
                        case sanify(Bucket, Map, ReadyServers, Down) of
                            Map -> Map;
                            MapNew ->
                                ns_bucket:set_map(Bucket, MapNew),
                                MapNew
                        end,
                    %% ReplicasTriples are [{Src::node(), Dst::node(), VBucketId::non_neg_integer()}]
                    ReplicasTriples = ns_bucket:map_to_replicas(Map1),
                    Replicas = lists:keysort(2, ReplicasTriples),
                    ReplicaGroups = lists:ukeymerge(1, misc:keygroup(2, Replicas),
                                                    [{N, []} || N <- lists:sort(Servers)]),
                    NodesReplicas = lists:map(fun ({Dst, R}) -> % R is the replicas for this node
                                                      {Dst, [{V, Src} || {Src, _, V} <- R]}
                                              end, ReplicaGroups),
                    ns_vbm_sup:set_replicas_dst(Bucket, NodesReplicas),
                    capi_ddoc_replication_srv:force_update(Bucket),
                    case Down of
                        [] ->
                            maybe_stop_replication_status();
                        _ -> ok
                    end,
                    ok
            end
    end.

-spec sanify(string(), map(), [atom()], [atom()]) -> map().
sanify(Bucket, Map, Servers, DownNodes) ->
    {ok, States, Zombies} = current_states(Servers, Bucket),
    [sanify_chain(Bucket, States, Chain, VBucket, Zombies ++ DownNodes)
     || {VBucket, Chain} <- misc:enumerate(Map, 0)].

sanify_chain(Bucket, State, Chain, VBucket, Zombies) ->
    NewChain = do_sanify_chain(Bucket, State, Chain, VBucket, Zombies),
    %% Fill in any missing replicas
    case length(NewChain) < length(Chain) of
        false ->
            NewChain;
        true ->
            NewChain ++ lists:duplicate(length(Chain) - length(NewChain),
                                        undefined)
    end.


do_sanify_chain(Bucket, States, Chain, VBucket, Zombies) ->
    NodeStates = [{N, S} || {N, V, S} <- States, V == VBucket],
    ChainStates = lists:map(fun (N) ->
                                    case lists:keyfind(N, 1, NodeStates) of
                                        false -> {N, case lists:member(N, Zombies) of
                                                         true -> zombie;
                                                         _ -> missing
                                                     end};
                                        X -> X
                                    end
                            end, Chain),
    ExtraStates = [X || X = {N, _} <- NodeStates,
                        not lists:member(N, Chain)],
    case ChainStates of
        [{undefined, _}|_] ->
            Chain;
        [{Master, State}|ReplicaStates] when State /= active andalso State /= zombie ->
            case [N || {N, active} <- ReplicaStates ++ ExtraStates] of
                [] ->
                    %% We'll let the next pass catch the replicas.
                    ?log_info("Setting vbucket ~p in ~p on ~p from ~p to active.",
                              [VBucket, Bucket, Master, State]),
                    ns_memcached:set_vbucket(Master, Bucket, VBucket, active),
                    Chain;
                [Node] ->
                    %% One active node, but it's not the master
                    case misc:position(Node, Chain) of
                        false ->
                            %% It's an extra node
                            ?log_warning(
                               "Master for vbucket ~p in ~p is not active, but ~p is, so making that the master.",
                              [VBucket, Bucket, Node]),
                            [Node];
                        Pos ->
                            [Node|lists:nthtail(Pos, Chain)]
                    end;
                Nodes ->
                    ?log_error(
                      "Extra active nodes ~p for vbucket ~p in ~p. This should never happen!",
                      [Nodes, Bucket, VBucket]),
                    Chain
            end;
        C = [{_, MasterState}|ReplicaStates] when MasterState =:= active orelse MasterState =:= zombie ->
            lists:foreach(
              fun ({_, {N, active}}) ->
                      ?log_error("Active replica ~p for vbucket ~p in ~p. "
                                 "This should never happen, but we have an "
                                 "active master, so I'm deleting it.",
                                 [N, Bucket]),
                      %% %% ns_vbm_sup:stop_outgoing_replications(N, Bucket, [VBucket]),
                      %%
                      %% was here, but because we're going to call
                      %% set_replicas_dst at the end of janitor pass
                      %% this is not required.
                      ns_memcached:set_vbucket(N, Bucket, VBucket, dead);
                  ({_, {_, replica}})-> % This is what we expect
                      ok;
                  ({_, {_, missing}}) ->
                      %% Either fewer nodes than copies or replicator
                      %% hasn't started yet
                      ok;
                  ({{_, zombie}, _}) -> ok;
                  ({_, {_, zombie}}) -> ok;
                  ({{undefined, _}, _}) -> ok;
                  ({_, {DstNode, _}} = Pair) ->
                      ?log_info("Killing incoming replicators for vbucket ~p on"
                                " replica ~p because of ~p", [VBucket, DstNode, Pair]),
                      ns_vbm_sup:stop_incoming_replications(DstNode, Bucket, [VBucket])
              end, misc:pairs(C)),
            HaveAllCopies = lists:all(
                              fun ({undefined, _}) -> false;
                                  ({_, replica}) -> true;
                                  (_) -> false
                              end, ReplicaStates),
            lists:foreach(
              fun ({N, State}) ->
                      case {HaveAllCopies, State} of
                          {true, dead} ->
                              ?log_info("Deleting dead vbucket ~p in ~p on ~p",
                                        [VBucket, Bucket, N]),
                              ns_memcached:delete_vbucket(N, Bucket, VBucket);
                          {true, _} ->
                              ?log_info("Deleting vbucket ~p in ~p on ~p",
                                        [VBucket, Bucket, N]),
                              ns_memcached:set_vbucket(
                                N, Bucket, VBucket, dead),
                              ns_memcached:delete_vbucket(N, Bucket, VBucket);
                          {false, dead} ->
                              ok;
                          {false, _} ->
                              ?log_info("Setting vbucket ~p in ~p on ~p from ~p"
                                        " to dead because we don't have all "
                                        "copies", [N, Bucket, VBucket, State]),
                              ns_memcached:set_vbucket(N, Bucket, VBucket, dead)
                      end
              end, ExtraStates),
            Chain;
        [{Master, State}|ReplicaStates] ->
            case [N||{N, RState} <- ReplicaStates ++ ExtraStates,
                     lists:member(RState, [active, pending, replica])] of
                [] ->
                    ?log_info("Setting vbucket ~p in ~p on master ~p to active",
                              [VBucket, Bucket, Master]),
                    ns_memcached:set_vbucket(Master, Bucket, VBucket,
                                                   active),
                    Chain;
                X ->
                    case lists:member(Master, Zombies) of
                        true -> ok;
                        false ->
                            ?log_error("Master ~p in state ~p for vbucket ~p in ~p but we have extra nodes ~p!",
                                       [Master, State, VBucket, Bucket, X])
                    end,
                    Chain
            end
    end.

%% [{Node, VBucket, State}...]
-spec current_states(list(atom()), string()) ->
                            {ok, list({atom(), integer(), atom()}), list(atom())}.
current_states(Nodes, Bucket) ->
    {Replies, DownNodes} = ns_memcached:list_vbuckets_multi(Nodes, Bucket),
    {GoodReplies, BadReplies} = lists:partition(fun ({_, {ok, _}}) -> true;
                                                    (_) -> false
                                                     end, Replies),
    ErrorNodes = [Node || {Node, _} <- BadReplies],
    States = [{Node, VBucket, State} || {Node, {ok, Reply}} <- GoodReplies,
                                        {VBucket, State} <- Reply],
    {ok, States, ErrorNodes ++ DownNodes}.

%%
%% Internal functions
%%

wait_for_memcached(Nodes, Bucket, Type) ->
    wait_for_memcached(Nodes, Bucket, Type, ?WAIT_FOR_MEMCACHED_TRIES).

wait_for_memcached(Nodes, Bucket, Type, Tries) when Tries > 0 ->
    ReadyNodes = ns_memcached:ready_nodes(Nodes, Bucket, Type, default),
    DownNodes = ordsets:subtract(ordsets:from_list(Nodes),
                                 ordsets:from_list(ReadyNodes)),
    case DownNodes of
        [] ->
            [];
        _ ->
            case Tries - 1 of
                0 ->
                    DownNodes;
                X ->
                    ?log_info("Waiting for ~p on ~p", [Bucket, DownNodes]),
                    timer:sleep(1000),
                    wait_for_memcached(Nodes, Bucket, Type, X)
            end
    end.

maybe_stop_replication_status() ->
    Status = try ns_orchestrator:rebalance_progress_full()
             catch E:T ->
                     ?log_error("janitor maybe_stop_replication_status cannot reach orchestrator: ~p:~p", [E,T]),
                     error
             end,
    case Status of
        not_running ->
            Fun = fun (Value) ->
                          case Value of
                              running ->
                                  {none, <<"status stopped by janitor">>};
                              _ -> Value
                          end
                  end,
            ns_config:update_key(rebalance_status, Fun);
        _ ->
            ok
    end.
