%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% Monitor and maintain the vbucket layout of each bucket.

-module(ns_janitor).

-export([cleanup/3, current_states/2, graphviz/1]).

cleanup(Bucket, Map, Servers) ->
    sanify(Bucket, Map, Servers),
    Replicas = lists:keysort(1, map_to_replicas(Map)),
    ReplicaGroups = misc:keygroup(1, Replicas),
    NodesReplicas = lists:map(fun ({Src, R}) -> % R is the replicas for this node
                                      {Src, [{V, Dst} || {_, Dst, V} <- R]}
                              end, ReplicaGroups),
    lists:foreach(fun ({Src, R}) ->
                          ns_vbm_sup:set_replicas(Src, Bucket, R)
                  end, NodesReplicas).

state_color(active) ->
    "color=green";
state_color(pending) ->
    "color=blue";
state_color(replica) ->
    "color=yellow";
state_color(dead) ->
    "color=red".

node_vbuckets(I, Node, States, Map) ->
    GState = lists:keysort(1,
               [{VBucket, state_color(State)} || {N, VBucket, State} <- States,
                                                 N == Node]),
    GMap = [{VBucket, "color=gray"} || {VBucket, Chain} <- misc:enumerate(Map, 0),
                                         lists:member(Node, Chain)],
    [io_lib:format("n~Bv~B [style=filled label=\"~B\" ~s];~n", [I, V, V, Style]) ||
        {V, Style} <- lists:ukeymerge(1, GState, GMap)].

graphviz(Bucket) ->
    {_, _, Map, Servers} = ns_bucket:config(Bucket),
    {States, Zombies} = current_states(Servers, Bucket),
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
    ["digraph G {", SubGraphs, Edges, "}"].

sanify(Bucket, Map, Servers) ->
    {States, _Zombies} = current_states(Servers, Bucket),
    sanify(Bucket, States, Map, 0).

sanify(_, _, [], _) ->
    ok;
sanify(Bucket, States, [Chain|Map], VBucket) ->
    NodeStates = [{N, S} || {N, V, S} <- States, V == VBucket],
    ChainStates = lists:map(fun (N) ->
                                    case lists:keyfind(N, 1, NodeStates) of
                                        false -> {N, missing};
                                        X -> X
                                    end
                            end, Chain),
    ExtraStates = [X || X = {N, _} <- NodeStates,
                        not lists:member(N, Chain)],
    case ChainStates of
        [{undefined, _}|_] ->
            error_logger:info_msg("~p:sanify: No master for vbucket ~p~n",
                                  [?MODULE, VBucket]);
        [{Master, State}|ReplicaStates] when State == pending orelse
                                             State == replica ->
            %% If we have any active nodes, do nothing, otherwise, set
            %% it to active.
            case [N || {N, active} <- ReplicaStates ++ ExtraStates] of
                [] ->
                    %% We'll let the next pass catch the replicas.
                    error_logger:info_msg(
                      "~p:sanify: Setting master ~p from ~p to active for vbucket ~p~n",
                      [?MODULE, Master, State, VBucket]),
                    ns_memcached:set_vbucket_state(Master, Bucket, VBucket, active);
                Nodes ->
                    error_logger:error_msg(
                      "~p:sanify: Extra active nodes ~p for vbucket ~p. If there is only one, we should probably just change the map, but this should never happen, so I'm going to do nothing.~n",
                      [?MODULE, Nodes, VBucket])
            end;
        [{_, active}|ReplicaStates] ->
            lists:foreach(
              fun ({N, active}) ->
                      error_logger:error_msg("~p:sanify: Active replica ~p for vbucket ~p. This should never happen, but we have an active master, so I'm deleting it.~n",
                                             [?MODULE, N]),
                      ns_memcached:set_vbucket_state(N, Bucket, VBucket, dead),
                      ns_memcached:delete_vbucket(N, Bucket, VBucket),
                      ns_vbm_sup:kill_children(N, Bucket, [VBucket]);
                  ({_, replica})-> % This is what we expect
                      ok;
                  ({undefined, missing}) -> % Probably fewer nodes than copies
                      ok;
                  ({N, State}) ->
                      error_logger:error_msg("~p:sanify: Replica on ~p in ~p state for vbucket ~p. Killing any existing replicators for that vbucket.~n",
                                             [?MODULE, N, State, VBucket]),
                      ns_vbm_sup:kill_children(N, Bucket, [VBucket])
              end, ReplicaStates),
            %% Clean up turds
            lists:foreach(
              fun ({N, State}) ->
                      error_logger:info_msg("~p:sanify: deleting old data for vbucket ~p in state ~p on node ~p~n",
                                            [?MODULE, VBucket, State, N]),
                      %% There'd better not be any replicators, but kill any
                      %% just in case.
                      ns_vbm_sup:kill_children(N, Bucket, [VBucket]),
                      ns_memcached:set_vbucket_state(N, Bucket, VBucket, dead),
                      ns_memcached:delete_vbucket(N, Bucket, VBucket)
              end, ExtraStates);
        [{Master, State}|ReplicaStates] ->
            case [N||{N, RState} <- ReplicaStates ++ ExtraStates,
                     lists:member(RState, [active, pending, replica])] of
                [] ->
                    error_logger:info_msg("~p:sanify: Setting master ~p for (hopefully new) vbucket ~p from ~p to active~n",
                                          [?MODULE, Master, VBucket, State]),
                    ns_memcached:set_vbucket_state(Master, Bucket, VBucket, active);
                X ->
                    error_logger:error_msg("~p:sanify: Master ~p in state ~p for vbucket ~p but we have extra nodes ~p!~n",
                                           [?MODULE, Master, State, VBucket, X])
            end
    end,
    sanify(Bucket, States, Map, VBucket+1).

%% [{Node, VBucket, State}...]
-spec current_states(list(atom()), string()) ->
                            list({atom(), integer(), atom()}).
current_states(Nodes, Buckets) ->
    current_states(Nodes, Buckets, 5).

current_states(Nodes, Bucket, Tries) ->
    case ns_memcached:list_vbuckets_multi(Nodes, Bucket) of
        {Replies, []} ->
            {GoodReplies, BadReplies} = lists:partition(fun ({_, {ok, _}}) -> true;
                                                            (_) -> false
                                                        end, Replies),
            ErrorNodes = [Node || {Node, _} <- BadReplies],
            States = [{Node, VBucket, State} || {Node, {ok, Reply}} <- GoodReplies,
                                                {VBucket, State} <- Reply],
            {States, ErrorNodes};
        {_, BadNodes} ->
            error_logger:info_msg("~p:current_states: can't reach nodes ~p: trying again~n", [?MODULE, BadNodes]),
            timer:sleep(1000),
            current_states(Nodes, Bucket, Tries-1)
    end.

map_to_replicas(Map) ->
    map_to_replicas(Map, 0, []).

map_to_replicas([], _, Replicas) ->
    lists:append(Replicas);
map_to_replicas([Chain|Rest], V, Replicas) ->
    Pairs = [{Src, Dst, V}||{Src, Dst} <- misc:pairs(Chain),
                            Src /= undefined andalso Dst /= undefined],
    map_to_replicas(Rest, V+1, [Pairs|Replicas]).
