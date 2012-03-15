%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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
-module(ns_janitor_vis).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([graphviz/1]).

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
    {ok, Config} = ns_bucket:get_bucket(Bucket),
    Map = proplists:get_value(map, Config, []),
    Servers = proplists:get_value(servers, Config, []),
    {ok, States, Zombies} = ns_janitor:current_states(Servers, Bucket),
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
    Replicants = lists:sort(ns_bucket:map_to_replicas(Map)),
    Replicators = ns_vbm_sup:replicas(Bucket, Nodes),
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
