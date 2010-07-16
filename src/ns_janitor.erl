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

-export([cleanup/3, current_states/2, graphviz/1]).

cleanup(Bucket, Map, Servers) ->
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
    lists:foreach(fun ({Src, R}) ->
                          catch ns_vbm_sup:set_replicas(Src, Bucket, R)
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

sanify(Bucket, Map, Servers) ->
    {ok, States, Zombies} = current_states(Servers, Bucket),
    [sanify_chain(Bucket, States, Chain, VBucket, Zombies)
     || {VBucket, Chain} <- misc:enumerate(Map, 0)].

sanify_chain(Bucket, States, Chain, VBucket, Zombies) ->
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
            Chain;
        [{Master, State}|ReplicaStates] when State == pending orelse
                                             State == replica ->
            %% If we have any active nodes, do nothing, otherwise, set
            %% it to active.
            case [N || {N, active} <- ReplicaStates ++ ExtraStates] of
                [] ->
                    %% We'll let the next pass catch the replicas.
                    ns_memcached:set_vbucket_state(Master, Bucket, VBucket, active),
                    Chain;
                [Node] ->
                    %% One active node, but it's not the master
                    case misc:position(Node, Chain) of
                        undefined ->
                            %% It's an extra node
                            ?log_warning(
                               "Master for vbucket ~p is not active, but ~p is, so making that the master.",
                              [VBucket, Node]),
                            [Node|lists:duplicate(length(Chain) - 1,
                                                  undefined)];
                        Pos ->
                            [Node|lists:nthtail(1, Pos)]
                    end;
                Nodes ->
                    ?log_error(
                      "Extra active nodes ~p for vbucket ~p. This should never happen!",
                      [Nodes, VBucket]),
                    Chain
            end;
        C = [{_, active}|ReplicaStates] ->
            lists:foreach(
              fun ({_, {N, active}}) ->
                      ?log_error("Active replica ~p for vbucket ~p. "
                                 "This should never happen, but we have an "
                                 "active master, so I'm deleting it.",
                                 [N]),
                      ns_memcached:set_vbucket_state(N, Bucket, VBucket, dead),
                      ns_vbm_sup:kill_children(N, Bucket, [VBucket]);
                  ({_, {_, replica}})-> % This is what we expect
                      ok;
                  ({_, {undefined, missing}}) -> % Probably fewer nodes than copies
                      ok;
                  ({{M, _}, {N, _}}) ->
                      %% Only do anything if the replica's not a zombie
                      case lists:member(N, Zombies) of
                          true->
                              ok;
                          false ->
                              ns_vbm_sup:kill_children(M, Bucket, [VBucket])
                      end
              end, misc:pairs(C)),
            HaveAllCopies = lists:all(
                              fun ({undefined, _}) -> false;
                                  ({_, replica}) -> true;
                                  (_) -> false
                              end, ReplicaStates),
            lists:foreach(
              fun ({N, State}) ->
                      ns_memcached:set_vbucket_state(N, Bucket, VBucket, dead),
                      case {HaveAllCopies, State} of
                          {true, _} ->
                              ns_memcached:delete_vbucket(N, Bucket, VBucket);
                          {false, dead} ->
                              ok;
                          {false, _} ->
                              ns_memcached:set_vbucket_state(
                                N, Bucket, VBucket, dead)
                      end
              end, ExtraStates),
            Chain;
        [{Master, State}|ReplicaStates] ->
            case [N||{N, RState} <- ReplicaStates ++ ExtraStates,
                     lists:member(RState, [active, pending, replica])] of
                [] ->
                    ns_memcached:set_vbucket_state(Master, Bucket, VBucket, active),
                    Chain;
                X ->
                    case lists:member(Master, Zombies) of
                        true -> ok;
                        false ->
                            ?log_error("Master ~p in state ~p for vbucket ~p but we have extra nodes ~p!",
                                       [Master, State, VBucket, X])
                    end,
                    Chain
            end
    end.

%% [{Node, VBucket, State}...]
-spec current_states(list(atom()), string()) ->
                            {ok, list({atom(), integer(), atom()})}.
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
