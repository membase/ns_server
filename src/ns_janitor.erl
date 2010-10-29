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

-export([cleanup/1, current_states/2, graphviz/1]).


-spec cleanup(string()) -> ok.
cleanup(Bucket) ->
    {Map, Servers} =
        case ns_bucket:config(Bucket) of
            {NumReplicas, NumVBuckets, _, []} ->
                S = ns_cluster_membership:active_nodes(),
                M = ns_rebalancer:generate_initial_map(NumReplicas, NumVBuckets,
                                                       S),
                ns_bucket:set_servers(Bucket, S),
                ns_bucket:set_map(Bucket, M),
                {M, S};
            {_, _, M, S} ->
                {M, S}
        end,
    case Servers of
        [] -> ok;
        _ ->
            case wait_for_memcached(Servers, Bucket, 5) of
                [] ->
                    case sanify(Bucket, Map, Servers) of
                        Map -> ok;
                        Map1 ->
                            ns_bucket:set_map(Bucket, Map1)
                    end,
                    Replicas = lists:keysort(1, map_to_replicas(Map)),
                    ReplicaGroups = lists:ukeymerge(1, misc:keygroup(1, Replicas),
                                                    [{N, []} || N <- lists:sort(Servers)]),
                    NodesReplicas = lists:map(fun ({Src, R}) -> % R is the replicas for this node
                                                      {Src, [{V, Dst} || {_, Dst, V} <- R]}
                                              end, ReplicaGroups),
                    ns_vbm_sup:set_replicas(Bucket, NodesReplicas);
                Down ->
                    ?log_error("Bucket ~p not yet ready on ~p", [Bucket, Down])
            end
    end.


state_color(active) ->
    "color=green";
state_color(pending) ->
    "color=blue";
state_color(replica) ->
    "color=yellow";
state_color(dead) ->
    "color=red".


-spec node_vbuckets(non_neg_integer(), node(), [{node(), vbucket_id(),
                                                 vbucket_state()}], map()) ->
                           iolist().
node_vbuckets(I, Node, States, Map) ->
    GState = lists:keysort(1,
               [{VBucket, state_color(State)} || {N, VBucket, State} <- States,
                                                 N == Node]),
    GMap = [{VBucket, "color=gray"} || {VBucket, Chain} <- misc:enumerate(Map, 0),
                                         lists:member(Node, Chain)],
    [io_lib:format("n~Bv~B [style=filled label=\"~B\" group=g~B ~s];~n",
                   [I, V, V, V, Style]) ||
        {V, Style} <- lists:ukeymerge(1, GState, GMap)].

graphviz(Bucket) ->
    {_, _, Map, Servers} = ns_bucket:config(Bucket),
    {ok, States, Zombies} = current_states(Servers, Bucket),
    Nodes = lists:sort(Servers),
    NodeColors = lists:map(fun (Node) ->
                                   case lists:member(Node, Zombies) of
                                       true -> {Node, "red"};
                                       false -> {Node, "black"}
                                   end
                           end, Nodes),
    SubGraphs = [io_lib:format("subgraph cluster_n~B {~ncolor=~s;~nlabel=\"~s\";~n~s}~n",
                              [I, Color, Node, node_vbuckets(I, Node, States, Map)]) ||
                    {I, {Node, Color}} <- misc:enumerate(NodeColors)],
    Replicants = lists:sort(map_to_replicas(Map)),
    Replicators = lists:sort(ns_vbm_sup:replicators(Nodes, Bucket)),
    AllRep = lists:umerge(Replicants, Replicators),
    Edges = [io_lib:format("n~pv~B -> n~pv~B [color=~s];~n",
                            [misc:position(Src, Nodes), V,
                             misc:position(Dst, Nodes), V,
                             case {lists:member(R, Replicants), lists:member(R, Replicators)} of
                                 {true, true} -> "black";
                                 {true, false} -> "red";
                                 {false, true} -> "blue"
                             end]) ||
                R = {Src, Dst, V} <- AllRep],
    ["digraph G { rankdir=LR; ranksep=6;", SubGraphs, Edges, "}"].


-spec sanify(string(), map(), [atom()]) -> map().
sanify(Bucket, Map, Servers) ->
    {ok, States, Zombies} = current_states(Servers, Bucket),
    [sanify_chain(Bucket, States, Chain, VBucket, Zombies)
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
                    ?log_info("Setting vbucket ~p in ~p on ~p to active.",
                              [VBucket, Bucket, Master]),
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
                      ns_memcached:set_vbucket(N, Bucket, VBucket, dead),
                      ns_vbm_sup:kill_children(N, Bucket, [VBucket]);
                  ({_, {_, replica}})-> % This is what we expect
                      ok;
                  ({_, {_, missing}}) ->
                      %% Either fewer nodes than copies or replicator
                      %% hasn't started yet
                      ok;
                  ({{_, zombie}, _}) -> ok;
                  ({_, {_, zombie}}) -> ok;
                  ({{undefined, _}, _}) -> ok;
                  ({{M, _}, _} = Pair) ->
                      ?log_info("Killing replicators for vbucket ~p on"
                                " master ~p because of ~p", [VBucket, M, Pair]),
                      ns_vbm_sup:kill_children(M, Bucket, [VBucket])
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

map_to_replicas(Map) ->
    map_to_replicas(Map, 0, []).

map_to_replicas([], _, Replicas) ->
    lists:append(Replicas);
map_to_replicas([Chain|Rest], V, Replicas) ->
    Pairs = [{Src, Dst, V}||{Src, Dst} <- misc:pairs(Chain),
                            Src /= undefined andalso Dst /= undefined],
    map_to_replicas(Rest, V+1, [Pairs|Replicas]).


%%
%% Internal functions
%%

wait_for_memcached(Nodes, _Bucket, 0) ->
    Nodes;
wait_for_memcached(Nodes, Bucket, Tries) ->
    case [Node || Node <- Nodes, not ns_memcached:connected(Node, Bucket)] of
        [] ->
            [];
        Down ->
            timer:sleep(1000),
            ?log_info("Waiting for ~p on ~p", [Bucket, Down]),
            wait_for_memcached(Down, Bucket, Tries-1)
    end.
