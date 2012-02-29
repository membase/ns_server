%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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
%% @doc Functions for manipulating vbucket maps. All code here is
%% supposed to be purely functional. At least on outside.

-module(mb_map).

-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([balance/3,
         is_balanced/3,
         is_valid/1,
         random_map/3]).


-export([counts/1]). % for testing

%%
%% API
%%

%% @doc Generate a balanced map.
balance(Map, Nodes, Options) ->
    KeepNodes = lists:sort(Nodes),
    NumNodes = length(KeepNodes),
    NumVBuckets = length(Map),
    NumNodes = length(Nodes),
    OrigCopies = length(hd(Map)),
    NumCopies = erlang:min(NumNodes, OrigCopies),
    %% Strip nodes we're removing along with extra copies
    Map1 = map_strip(Map, NumCopies, Nodes),
    %% We always use the slave assignment machinery.
    MaxSlaves = proplists:get_value(max_slaves, Options, NumNodes - 1),
    Slaves = slaves(Nodes, MaxSlaves),
    Chains = chains(Nodes, NumVBuckets, NumCopies, Slaves),
    %% Turn the map into a list of {VBucket, Chain} pairs.
    NumberedMap = lists:zip(lists:seq(0, length(Map) - 1), Map1),
    %% Sort the candidate chains.
    SortedChains = lists:sort(Chains),
    {Pairs, [], []} =
        lists:foldl(fun (Shift, {R, M, C}) ->
                            {R1, M1, C1} = balance1(M, C, Shift),
                            {R1 ++ R, M1, C1}
                    end, {[], NumberedMap, SortedChains},
                    lists:seq(0, NumCopies)),
    %% We can simply sort the pairs because the first element of the
    %% first tuple is the vbucket number.
    Map2 = [Chain || {_, Chain} <- lists:sort(Pairs)],
    if NumCopies < OrigCopies ->
            %% Extend the map back out the original number of copies
            Extension = lists:duplicate(OrigCopies - NumCopies, undefined),
            [Chain ++ Extension || Chain <- Map2];
       true ->
            Map2
    end.


%% @doc Test that a map is valid and balanced.
is_balanced(Map, Nodes, Options) ->
    case is_valid(Map) of
        true ->
            NumCopies = erlang:min(length(hd(Map)), length(Nodes)),
            case lists:all(
                   fun (Chain) ->
                           {Active, Inactive} = lists:split(NumCopies, Chain),
                           lists:all(
                             fun (Node) -> lists:member(Node, Nodes) end,
                             Active) andalso
                               case Inactive of
                                   [] ->
                                       true;
                                   _ ->
                                       lists:all(fun (N) -> N == undefined end,
                                                 Inactive)
                               end
                   end, Map) of
                false ->
                    false;
                true ->
                    Histograms = histograms(Map),
                    case lists:all(
                           fun (ChainHist) ->
                                   lists:max(ChainHist) -
                                       lists:min(ChainHist) =< 2
                           end, lists:sublist(Histograms, NumCopies)) of
                        false ->
                            io:fwrite("Histograms = ~w~n", [Histograms]),
                            io:fwrite("Counts = ~p~n", [dict:to_list(counts(Map))]),
                            false;
                        true ->
                            Counts = counts(Map),
                            SlaveCounts = count_slaves(Counts),
                            NumNodes = length(Nodes),
                            NumSlaves = erlang:min(
                                          proplists:get_value(
                                            max_slaves, Options, NumNodes-1),
                                          NumNodes-1),
                            io:fwrite("Counts = ~p~n", [dict:to_list(counts(Map))]),
                            dict:fold(
                              fun (_, {Min, Max, SlaveCount}, Acc) ->
                                      Acc andalso SlaveCount == NumSlaves
                                          andalso Min /= really_big
                                          andalso Max > 0
                                          andalso Max - Min =< 2
                              end, true, SlaveCounts)
                    end
            end
    end.


%% @private
%% @doc Return the number of nodes replicating from a given node
count_slaves(Counts) ->
    dict:fold(
      fun ({_, undefined, _}, _, Dict) -> Dict;
          ({undefined, _, _}, _, Dict) -> Dict;
          ({Master, _, Turn}, VBucketCount, Dict) ->
              Key = {Master, Turn},
              {Min, Max, SlaveCount} = case dict:find(Key, Dict) of
                                           {ok, Value} -> Value;
                                           error -> {really_big, 0, 0}
                                       end,
              dict:store(Key, {erlang:min(Min, VBucketCount),
                               erlang:max(Max, VBucketCount),
                               SlaveCount + 1}, Dict)
      end, dict:new(), Counts).


has_repeats([Chain|Map]) ->
    lists:any(fun ({_, C}) -> C > 1 end,
              misc:uniqc(lists:filter(fun (N) -> N /= undefined end, Chain)))
        orelse has_repeats(Map);
has_repeats([]) ->
    false.


%% @doc Test that a map is valid.
is_valid(Map) ->
    case length(Map) of
        0 ->
            empty;
        _ ->
            case length(hd(Map)) of
                0 ->
                    empty;
                NumCopies ->
                    case lists:all(fun (Chain) -> length(Chain) == NumCopies end,
                                   Map) of
                        false ->
                            different_length_chains;
                        true ->
                            case has_repeats(Map) of
                                true ->
                                    has_repeats;
                                false ->
                                    true
                            end
                    end
            end
    end.


%% @doc Generate a random map for testing.
random_map(0, _, _) -> [];
random_map(NumVBuckets, NumCopies, NumNodes) when is_integer(NumNodes) ->
    Nodes = [undefined | testnodes(NumNodes)],
    random_map(NumVBuckets, NumCopies, Nodes);
random_map(NumVBuckets, NumCopies, Nodes) when is_list(Nodes) ->
    [random_chain(NumCopies, Nodes) | random_map(NumVBuckets-1, NumCopies,
                                                 Nodes)].


%%
%% Internal functions
%%

balance1(NumberedMap, SortedChains, Shift) ->
    Fun = fun ({_, A}, {_, B}) ->
                  lists:nthtail(Shift, A) =< lists:nthtail(Shift, B)
          end,
    SortedMap = lists:sort(Fun, NumberedMap),
    Cmp = fun ({_, C1}, Candidate) ->
                  listcmp(lists:nthtail(Shift, C1), Candidate)
          end,
    genmerge(Cmp, SortedMap, SortedChains).


%% @private
%% @doc Pick the node with the lowest total vbuckets from the
%% beginning of a sorted list consisting of counts of vbuckets *at
%% this turn for this master* followed by the node name. Also returns
%% the remainder of the list to make it easy to update the count.
best_node(NodeCounts, Turn, Counts, Blacklist) ->
    NodeCounts1 = [{Count, dict:fetch({total, Node, Turn}, Counts), Node}
                   || {Count, Node} <- NodeCounts,
                      not lists:member(Node, Blacklist)],
    {Count, _, Node} = lists:min(NodeCounts1),
    {Count, Node}.


%% @private
%% @doc Generate the desired set of replication chains we want to end
%% up with, insensitive to which vbucket is assigned to which chain.
chains(Nodes, NumVBuckets, NumCopies, Slaves) ->
    %% Create a dictionary mapping each node and turn to a list of
    %% slaves with counts of how many have been assigned vbuckets
    %% already. Starts at 0 obviously.
    List = [{{undefined, 1}, [{0, N} || N <- Nodes]} |
            [{{total, N, T}, 0} || N <- Nodes, T <- lists:seq(1, NumCopies)]],
    Counts1 = dict:from_list(List),
    TurnSeq = lists:seq(2, NumCopies),
    Counts2 =
        lists:foldl(
          fun (Node, D1) ->
                  D3 = lists:foldl(
                         fun (Turn, D2) ->
                                 dict:store({Node, Turn},
                                            [{0, N}
                                             || N <- dict:fetch(Node, Slaves)],
                                            D2)
                         end, D1, TurnSeq),
                  %% We also store the total using
                  %% just the node as the key.
                  dict:store(Node, 0, D3)
          end, Counts1, Nodes),
    chains1(Counts2, NumVBuckets, NumCopies).


chains1(_, 0, _) ->
    [];
chains1(Counts, NumVBuckets, NumCopies) ->
    {Chain, Counts1} = chains2(Counts, undefined, 1, NumCopies, []),
    [Chain | chains1(Counts1, NumVBuckets - 1, NumCopies)].


chains2(Counts, PrevNode, Turn, Turns, ChainReversed) when Turn =< Turns ->
    Key = {PrevNode, Turn},
    %% The first node in the list for this master and turn is the node
    %% with the lowest count. We keep the list sorted by count.
    NodeCounts = dict:fetch({PrevNode, Turn}, Counts),
    {Count, Node} =
        best_node(NodeCounts, Turn, Counts, ChainReversed),
    Counts1 = dict:update_counter({total, Node, Turn}, 1, Counts),
    Counts2 = dict:store(Key, lists:keyreplace(Node, 2, NodeCounts,
                                               {Count+1, Node}), Counts1),
    chains2(Counts2, Node, Turn+1, Turns, [Node|ChainReversed]);
chains2(Counts, _, _, _, ChainReversed)  ->
    {lists:reverse(ChainReversed), Counts}.


%% @private
%% @doc Count the number of nodes a given node has replicas on.
counts(Map) ->
    lists:foldl(fun (Chain, Dict) ->
                        counts_chain(Chain, undefined, 1, 1, Dict)
                end, dict:new(), Map).


%% @private
%% @doc Count master/slave relatioships for a single replication chain.
counts_chain([Node|Chain], PrevNode, Turn, C, Dict) ->
    Dict1 = dict:update_counter({PrevNode, Node, Turn}, C, Dict),
    counts_chain(Chain, Node, Turn + 1, C, Dict1);
counts_chain([], _, _, _, Dict) ->
    Dict.


%% @private
%% @doc Generalized merge function. Takes a comparison function which
%% must return -1, 0, or 1 depending on whether the first item is less
%% than, equal to, or greater than the second element respectively,
%% and returns a tuple whose first element is a list of pairs of
%% matching items from the two lists, the unused items from the first
%% list, and the unused items from the second list. One of the second
%% or third element will always be an empty list.
genmerge(Cmp, [H1|T1] = L1, [H2|T2] = L2) ->
    case Cmp(H1, H2) of
        -1 ->
            {R, R1, R2} = genmerge(Cmp, T1, L2),
            {R, [H1|R1], R2};
        0 ->
            {R, R1, R2} = genmerge(Cmp, T1, T2),
            {[{H1, H2} | R], R1, R2};
        1 ->
            {R, R1, R2} = genmerge(Cmp, L1, T2),
            {R, R1, [H2|R2]}
    end;
genmerge(_, L1, L2) ->
    {[], L1, L2}.


%% @private
%% @doc A list of lists of the number of vbuckets on each node at each
%% turn, but without specifying which nodes.
histograms(Map) ->
    [[C || {_, C} <- misc:uniqc(lists:sort(L))]
     || L <- misc:rotate(Map)].


%% @private
%% @doc Compare the elements of two lists of possibly unequal lengths,
%% returning -1 if the first non-matching element of the first list is
%% less, 1 if it's greater, or 0 if there are no non-matching
%% elements.
listcmp([H1|T1], [H2|T2]) ->
    if H1 == H2 ->
            listcmp(T1, T2);
       H1 < H2 ->
            -1;
       true ->
            1
    end;
listcmp(_, _) ->
    0.


%% @private
%% @doc Strip nodes that we're removing from the cluster, along with
%% extra copies we don't care about for this rebalancing operation.
map_strip([Chain|Map], NumCopies, Nodes) ->
    Chain1 =
        [case lists:member(Node, Nodes) of true -> Node; false -> undefined end
         || Node <- lists:sublist(Chain, NumCopies)],
    [Chain1 | map_strip(Map, NumCopies, Nodes)];
map_strip([], _, _) ->
    [].


%% @private
%% @doc Generate a random valid replication chain.
random_chain(0, _) -> [];
random_chain(NumCopies, Nodes) ->
    Node = lists:nth(random:uniform(length(Nodes)), Nodes),
    Nodes1 = case Node of
                 undefined ->
                     Nodes;
                 _ ->
                     Nodes -- [Node]
             end,
    [Node|random_chain(NumCopies-1, Nodes1)].


%% @private
%% @doc Generate a set of {Master, Slave} pairs from a list of nodes
%% and the number of slaves you want for each.
slaves(Nodes, NumSlaves) ->
    slaves(Nodes, [], NumSlaves, dict:new()).


slaves([Node|Nodes], Rest, NumSlaves, Dict) ->
    Dict1 = dict:store(Node, lists:sublist(Nodes ++ Rest, NumSlaves), Dict),
    slaves(Nodes, Rest ++ [Node], NumSlaves, Dict1);
slaves([], _, _, Set) ->
    Set.


%% @private
%% @doc Generate a list of nodes for testing.
testnodes(NumNodes) ->
    [list_to_atom([$n | integer_to_list(N)]) || N <- lists:seq(1, NumNodes)].


%%
%% Tests
%%

balance_test_() ->
    MapSizes = [1,2,1024,4096],
    NodeNums = [1,2,3,4,5,10,100],
    CopySizes = [1,2,3],
    SlaveNums = [1,2,10],
    {timeout, 120,
     [{inparallel,
       [balance_test_gen(MapSize, CopySize, NumNodes, NumSlaves)
        || NumSlaves <- SlaveNums,
           CopySize <- CopySizes,
           NumNodes <- NodeNums,
           MapSize <- MapSizes,
           trunc(trunc(MapSize/NumNodes) /
                     NumSlaves)
               > 0]}]}.


balance_test_gen(MapSize, CopySize, NumNodes, NumSlaves) ->
    Title = lists:flatten(
              io_lib:format(
                "MapSize: ~p, NumNodes: ~p, CopySize: ~p, NumSlaves: ~p~n",
                [MapSize, NumNodes, CopySize, NumSlaves])),
    Fun = fun () ->
                  Map1 = random_map(MapSize, CopySize, NumNodes),
                  Nodes = testnodes(NumNodes),
                  Opts = [{max_slaves, NumSlaves}],
                  Map2 = balance(Map1, Nodes, Opts),
                  ?assert(is_balanced(Map2, Nodes, Opts))
          end,
    {timeout, 300, {Title, Fun}}.


validate_test() ->
    ?assertEqual(is_valid([]), empty),
    ?assertEqual(is_valid([[]]), empty).
