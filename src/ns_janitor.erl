%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% Monitor and maintain the vbucket layout of each bucket.

-module(ns_janitor).

-export([cleanup/3, current_states/2]).

cleanup(Bucket, Map, Servers) ->
    Replicas = lists:keysort(1, map_to_replicas(Map)),
    lists:foreach(fun ({_, Dst, V}) ->
                          ns_memcached:set_vbucket_state(Dst, Bucket, V, replica)
                  end, Replicas),
    ReplicaGroups = misc:keygroup(1, Replicas),
    NodesReplicas = lists:map(fun ({Src, R}) -> % R is the replicas for this node
                                      {Src, [{V, Dst} || {_, Dst, V} <- R]}
                              end, ReplicaGroups),
    lists:foreach(fun ({Src, R}) ->
                          ns_vbm_sup:set_replicas(Src, Bucket, R)
                  end, NodesReplicas),
    sanify_masters(Bucket, Map, Servers).

sanify_masters(Bucket, Map, Servers) ->
    {States, _Zombies} = current_states(Servers, Bucket),
    ActiveNodes = [{VBucket, Node} || {Node, VBucket, active} <- States],
    sanify_master(Bucket, ActiveNodes, Map, 0).

sanify_master(_, _, [], _) ->
    ok;
sanify_master(Bucket, Nodes, [[Master|Replicas]|Map], VBucket) ->
    BadNodes = lists:keydelete(Master, 1, Nodes),
    lists:foreach(fun (Node) ->
                          case lists:member(Node, Replicas) of
                              true ->
                                  error_logger:error_msg("~p:sanify_master(~p): active replica ~p for vbucket ~p~n",
                                                         [?MODULE, Bucket, Node, VBucket]);
                              false ->
                                  error_logger:error_msg("~p:sanify_master(~p): extra active node ~p for vbucket ~p, setting to dead~n",
                                                         [?MODULE, Bucket, VBucket, Node]),
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
    sanify_master(Bucket, Nodes, Map, VBucket+1).

%% [{Node, VBucket, State}...]
-spec current_states(list(atom()), string()) ->
                            list({atom(), integer(), atom()}).
current_states(Nodes, Buckets) ->
    current_states(Nodes, Buckets, 5).

current_states(Nodes, Bucket, Tries) ->
    case ns_memcached:list_vbuckets_multi(Nodes, Bucket) of
        {Replies, []} ->
            error_logger:info_msg("got replies ~p~n", [Replies]),
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
