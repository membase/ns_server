%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% Monitor and maintain the vbucket layout of each bucket.

-module(ns_janitor).

-export([cleanup/3, current_states/2, graphviz/1]).

cleanup(Bucket, Map, Servers) ->
    Replicas = lists:keysort(1, map_to_replicas(Map)),
    ReplicaGroups = misc:keygroup(1, Replicas),
    NodesReplicas = lists:map(fun ({Src, R}) -> % R is the replicas for this node
                                      {Src, [{V, Dst} || {_, Dst, V} <- R]}
                              end, ReplicaGroups),
    lists:foreach(fun ({Src, R}) ->
                          ns_vbm_sup:set_replicas(Src, Bucket, R)
                  end, NodesReplicas),
    sanify_masters(Bucket, Map, Servers).

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
    [io_lib:format("n~Bv~B [style=filled ~s];~n", [I, V, Style]) ||
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

sanify_masters(Bucket, Map, Servers) ->
    {States, _Zombies} = current_states(Servers, Bucket),
    ActiveNodes = [{VBucket, Node} || {Node, VBucket, active} <- States],
    sanify_master(Bucket, ActiveNodes, Map, 0).

sanify_master(_, _, [], _) ->
    ok;
sanify_master(Bucket, ActiveStates, [[Master|Replicas]|Map], VBucket) ->
    Nodes = [N || {V, N} <- ActiveStates, V == VBucket],
    BadNodes = lists:delete(Master, Nodes),
    lists:foreach(fun (Node) ->
                          case lists:member(Node, Replicas) of
                              true ->
                                  error_logger:error_msg("~p:sanify_master(~p): active replica ~p for vbucket ~p~n",
                                                         [?MODULE, Bucket, Node, VBucket]);
                              false ->
                                  error_logger:error_msg("~p:sanify_master(~p): extra active node ~p for vbucket ~p, setting to dead~n",
                                                         [?MODULE, Bucket, Node, VBucket]),
                                  ns_memcached:set_vbucket_state(Node, Bucket, VBucket, dead)
                          end
                  end, BadNodes),
    case lists:member(Master, Nodes) of
        true -> ok;
        false ->
            error_logger:info_msg("~p:sanify_master(~p): setting master node ~p for vbucket ~p to active state~n",
                                  [?MODULE, Bucket, Master, VBucket]),
            ns_memcached:set_vbucket_state(Master, Bucket, VBucket, active)
    end,
    sanify_master(Bucket, ActiveStates, Map, VBucket+1).

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
