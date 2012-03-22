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
%% supposed to be purely functional. At least on outside. Well,
%% there's slight use of per-process randomness state in random_map/3
%% (quite naturally) and generate_map/3 (less naturally)

-module(mb_map).

-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([promote_replicas/2,
         generate_map/3,
         is_balanced/3,
         is_valid/1,
         random_map/3,
         vbucket_movements/2]).


-export([counts/1]). % for testing

%% removes RemapNodes from head of vbucket map Map. Returns new map
promote_replicas(undefined, _RemapNode) ->
    undefined;
promote_replicas(Map, RemapNodes) ->
    [promote_replica(Chain, RemapNodes) || Chain <- Map].

%% removes RemapNodes from head of vbucket map Chain for vbucket
%% V. Actually switches master if head of Chain is in
%% RemapNodes. Returns new chain.
promote_replica(Chain, RemapNodes) ->
    Chain1 = [case lists:member(Node, RemapNodes) of
                  true -> undefined;
                  false -> Node
              end || Node <- Chain],
    %% Chain now might begin with undefined - put all the undefineds
    %% at the end
    {Undefineds, Rest} = lists:partition(fun (undefined) -> true;
                                             (_) -> false
                                         end, Chain1),
    Rest ++ Undefineds.

vbucket_movements_rec(AccMasters, AccReplicas, AccRest, [], []) ->
    {AccMasters, AccReplicas, AccRest};
vbucket_movements_rec(AccMasters, AccReplicas, AccRest, [[MasterSrc|_] = SrcChain | RestSrcChains], [[MasterDst|RestDst] | RestDstChains]) ->
    true = (MasterDst =/= undefined),
    AccMasters2 = case MasterSrc =:= MasterDst of
                      true ->
                          AccMasters;
                      false ->
                          AccMasters+1
                  end,
    BetterReplicas  = case SrcChain of
                          [_] ->
                              SrcChain;
                          [MasterSrc, FirstSrcReplica | _RestSrc] ->
                              [MasterSrc, FirstSrcReplica]
                      end,
    AccReplicas2 = case RestDst =:= [] orelse hd(RestDst) =:= undefined orelse lists:member(hd(RestDst), BetterReplicas) of
                       true ->
                           AccReplicas;
                       false ->
                           AccReplicas+1
                   end,
    AccRest2 = lists:foldl(
                 fun (DstNode, Acc) ->
                         case DstNode =:= undefined orelse lists:member(DstNode, SrcChain) of
                             true -> Acc;
                             false -> Acc+1
                         end
                 end, AccRest, RestDst),
    vbucket_movements_rec(AccMasters2, AccReplicas2, AccRest2, RestSrcChains, RestDstChains).

%% returns 'score' for difference between Src and Dst map. It's a
%% triple. First element is number of takeovers (regardless if from
%% scratch or not), second element is number first replicas that will
%% be backfilled from scratch, third element is number any replicas
%% that will be built from scratch.
%%
%% NOTE: we naively assume master and 1st replica are up-to-date so if
%% future first replica is past master of first replica we think it
%% won't require backfill.
vbucket_movements(Src, Dst) ->
    vbucket_movements_rec(0, 0, 0, Src, Dst).


map_nodes_set(Map) ->
    lists:foldl(
      fun (Chain, Acc) ->
              lists:foldl(
                fun (Node, Acc1) ->
                        case Node of
                            undefined ->
                                Acc1;
                            _ ->
                                sets:add_element(Node, Acc1)
                        end
                end, Acc, Chain)
      end, sets:new(), Map).

matching_renamings(KeepNodesSet, CurrentMap, CandidateMap) ->
    case length(CandidateMap) =:= length(CurrentMap) of
        false ->
            [];
        _ ->
            case length(hd(CandidateMap)) =:= length(hd(CurrentMap)) of
                true ->
                    matching_renamings_same_vbuckets_count(KeepNodesSet, CurrentMap, CandidateMap);
                false ->
                    []
            end
    end.

matching_renamings_same_vbuckets_count(KeepNodesSet, CurrentMap, CandidateMap) ->
    CandidateNodesSet = map_nodes_set(CandidateMap),
    case sets:size(CandidateNodesSet) =:= sets:size(KeepNodesSet) of
        false ->
            [];
        true ->
            CurrentNotCommon = sets:subtract(KeepNodesSet, CandidateNodesSet),
            case sets:size(CurrentNotCommon) of
                0 ->
                    Moves = vbucket_movements(CurrentMap, CandidateMap),
                    [{CandidateMap, Moves}];
                1 ->
                    [NewNode] = sets:to_list(CurrentNotCommon),
                    [OldNode] = sets:to_list(sets:subtract(CandidateNodesSet, KeepNodesSet)),
                    NewMap = misc:rewrite_value(OldNode, NewNode, CandidateMap),
                    [{NewMap, vbucket_movements(CurrentMap, NewMap)}];
                2 ->
                    [NewNodeA, NewNodeB] = sets:to_list(CurrentNotCommon),
                    [OldNodeA, OldNodeB] = sets:to_list(sets:subtract(CandidateNodesSet, KeepNodesSet)),
                    NewMapA = misc:rewrite_value(OldNodeB, NewNodeB,
                                                 misc:rewrite_value(OldNodeA, NewNodeA, CandidateMap)),
                    NewMapB = misc:rewrite_value(OldNodeA, NewNodeB,
                                                 misc:rewrite_value(OldNodeB, NewNodeA, CandidateMap)),
                    [{NewMapA, vbucket_movements(CurrentMap, NewMapA)},
                     {NewMapB, vbucket_movements(CurrentMap, NewMapB)}];
                _ ->
                    %% just try some random mapping just in case. It
                    %% will work nicely if NewNode-s are all being
                    %% added to cluster (and CurrentNode-s thus
                    %% removed). Because in such case exact mapping
                    %% doesn't really matter, because we'll backfill
                    %% new nodes and it doesn't matter which.
                    NewNotCommon = sets:to_list(sets:subtract(CandidateNodesSet, KeepNodesSet)),
                    NewMap = lists:foldl(
                               fun ({CurrentNode, CandidateNode}, MapAcc) ->
                                       misc:rewrite_value(CandidateNode, CurrentNode, MapAcc)
                               end,
                               CandidateMap, lists:zip(sets:to_list(CurrentNotCommon), NewNotCommon)),
                    [{NewMap, vbucket_movements(CurrentMap, NewMap)}]
            end
    end.

%%
%% API
%%

map_scores_less(ScoreA, ScoreB) ->
    {element(1, ScoreA) + element(2, ScoreA), element(3, ScoreA)} < {element(1, ScoreB) + element(2, ScoreB), element(3, ScoreB)}.

generate_map(Map, Nodes, Options) ->
    KeepNodes = lists:sort(Nodes),
    MapsHistory = proplists:get_value(maps_history, Options, []),
    NonHistoryOptionsNow = lists:sort(lists:keydelete(maps_history, 1, Options)),

    NaturalMap = balance(Map, KeepNodes, Options),
    NaturalMapScore = {NaturalMap, vbucket_movements(Map, NaturalMap)},

    ?log_debug("Natural map score: ~p", [element(2, NaturalMapScore)]),

    RndMap1 = balance(Map, misc:shuffle(Nodes), Options),
    RndMap2 = balance(Map, misc:shuffle(Nodes), Options),

    AllRndMapScores = [RndMap1Score, RndMap2Score] = [{M, vbucket_movements(Map, M)} || M <- [RndMap1, RndMap2]],

    ?log_debug("Rnd maps scores: ~p, ~p", [S || {_, S} <- AllRndMapScores]),

    NodesSet = sets:from_list(Nodes),
    MapsFromPast = lists:flatmap(fun ({PastMap, NonHistoryOptions}) ->
                                         case lists:sort(NonHistoryOptions) =:= NonHistoryOptionsNow of
                                             true ->
                                                 matching_renamings(NodesSet, Map, PastMap);
                                             false ->
                                                 []
                                         end
                                 end, MapsHistory),

    AllMaps = sets:to_list(sets:from_list([NaturalMapScore, RndMap1Score, RndMap2Score | MapsFromPast])),

    ?log_debug("Considering ~p maps:~n~p", [length(AllMaps), [S || {_, S} <- AllMaps]]),

    BestMapScore = lists:foldl(fun ({_, CandidateScore} = Candidate, {_, BestScore} = Best) ->
                                  case map_scores_less(CandidateScore, BestScore) of
                                      true ->
                                          Candidate;
                                      false ->
                                          Best
                                  end
                          end, hd(AllMaps), tl(AllMaps)),

    BestMap = element(1, BestMapScore),
    ?log_debug("Best map score: ~p (~p,~p,~p)", [element(2, BestMapScore), (BestMap =:= NaturalMap), (BestMap =:= RndMap1), (BestMap =:= RndMap2)]),
    BestMap.

%% @doc Generate a balanced map.
balance(Map, KeepNodes, Options) ->
    NumNodes = length(KeepNodes),
    NumVBuckets = length(Map),
    OrigCopies = length(hd(Map)),
    NumCopies = erlang:min(NumNodes, OrigCopies),
    %% Strip nodes we're removing along with extra copies
    Map1 = map_strip(Map, NumCopies, KeepNodes),
    %% We always use the slave assignment machinery.
    MaxSlaves = proplists:get_value(max_slaves, Options, NumNodes - 1),
    Slaves = slaves(KeepNodes, MaxSlaves),
    Chains = chains(KeepNodes, NumVBuckets, NumCopies, Slaves),
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

do_failover_and_rebalance_back_trial(NodesCount, FailoverIndex, VBucketCount, ReplicaCount) ->
    Nodes = testnodes(NodesCount),
    InitialMap = lists:duplicate(VBucketCount, lists:duplicate(ReplicaCount+1, undefined)),
    SlavesOptions = [{max_slaves, 10}],
    FirstMap = generate_map(InitialMap, Nodes, SlavesOptions),
    true = is_balanced(FirstMap, Nodes, SlavesOptions),
    FailedNode = lists:nth(FailoverIndex, Nodes),
    FailoverMap = promote_replicas(FirstMap, [FailedNode]),
    LiveNodes = lists:sublist(Nodes, FailoverIndex-1) ++ lists:nthtail(FailoverIndex, Nodes),
    false = lists:member(FailedNode, LiveNodes),
    true = lists:member(FailedNode, Nodes),
    ?assertEqual(NodesCount, length(LiveNodes) + 1),
    ?assertEqual(NodesCount, length(lists:usort(LiveNodes)) + 1),
    false = is_balanced(FailoverMap, LiveNodes, SlavesOptions),
    true = (lists:sort(LiveNodes) =:= lists:sort(sets:to_list(map_nodes_set(FailoverMap)))),
    RebalanceBackMap = generate_map(FailoverMap, Nodes, [{maps_history, [{FirstMap, SlavesOptions}]} | SlavesOptions]),
    true = (RebalanceBackMap =/= generate_map(FailoverMap, Nodes, [{maps_history, [{FirstMap, lists:keyreplace(max_slaves, 1, SlavesOptions, {max_slaves, 3})}]} | SlavesOptions])),
    ?assertEqual(FirstMap, RebalanceBackMap).

failover_and_rebalance_back_one_replica_test() ->
    do_failover_and_rebalance_back_trial(4, 1, 32, 1),
    do_failover_and_rebalance_back_trial(6, 2, 1260, 1),
    do_failover_and_rebalance_back_trial(12, 7, 1260, 2).

do_replace_nodes_rebalance_trial(NodesCount, RemoveIndexes, AddIndexes, VBucketCount, ReplicaCount) ->
    Nodes = testnodes(NodesCount),
    RemoveIndexes = RemoveIndexes -- AddIndexes,
    AddIndexes = AddIndexes -- RemoveIndexes,
    AddedNodes = [lists:nth(I, Nodes) || I <- AddIndexes],
    RemovedNodes = [lists:nth(I, Nodes) || I <- RemoveIndexes],
    InitialNodes = Nodes -- AddedNodes,
    ReplacementNodes = Nodes -- RemovedNodes,
    InitialMap = lists:duplicate(VBucketCount, lists:duplicate(ReplicaCount+1, undefined)),
    SlavesOptions = [{max_slaves, 10}],
    FirstMap = generate_map(InitialMap, InitialNodes, SlavesOptions),
    ReplaceMap = generate_map(FirstMap, ReplacementNodes, [{maps_history, [{FirstMap, SlavesOptions}]} | SlavesOptions]),
    ?log_debug("FirstMap:~n~p~nReplaceMap:~n~p~n", [FirstMap, ReplaceMap]),
    %% we expect all change to be just some rename (i.e. mapping
    %% from/to) RemovedNodes to AddedNodes. We can find it by finding
    %% matching 'master_signature'-s. I.e. lists of vbuckets where
    %% certain node is master. We know it'll uniquely identify node
    %% 'inside' map structurally. So it can be used as 100% precise
    %% guard for our isomorphizm search.
    AddedNodesSignature0 = [{N, master_vbucket_signature(ReplaceMap, N)} || N <- AddedNodes],
    ?log_debug("AddedNodesSignature0:~n~p~n", [AddedNodesSignature0]),
    RemovedNodesSignature0 = [{N, master_vbucket_signature(FirstMap, N)} || N <- RemovedNodes],
    ?log_debug("RemovedNodesSignature0:~n~p~n", [RemovedNodesSignature0]),
    AddedNodesSignature = lists:keysort(2, AddedNodesSignature0),
    RemovedNodesSignature = lists:keysort(2, RemovedNodesSignature0),
    Mapping = [{Rem, Add} || {{Rem, _}, {Add, _}} <- lists:zip(RemovedNodesSignature, AddedNodesSignature)],
    ?log_debug("Discovered mapping: ~p~n", [Mapping]),
    %% now rename according to mapping and check
    ReplaceMap2 = lists:foldl(
                    fun ({Rem, Add}, Map) ->
                            misc:rewrite_value(Rem, Add, Map)
                    end, FirstMap, Mapping),
    ?assertEqual(ReplaceMap2, ReplaceMap).

replace_nodes_rebalance_test() ->
    do_replace_nodes_rebalance_trial(9, [7, 3], [5, 1], 32, 1),
    do_replace_nodes_rebalance_trial(10, [2, 4], [5, 1], 1260, 2),
    do_replace_nodes_rebalance_trial(19, [2, 4, 19, 17], [5, 1, 9, 7], 1260, 3),
    do_replace_nodes_rebalance_trial(51, [23], [37], 1440, 2).


master_vbucket_signature(Map, Node) ->
    master_vbucket_signature_rec(Map, Node, [], 0).

master_vbucket_signature_rec([], _Node, Acc, _Idx) ->
    Acc;
master_vbucket_signature_rec([[Node | _] | Rest], Node, Acc, Idx) ->
    master_vbucket_signature_rec(Rest, Node, [Idx | Acc], Idx+1);
master_vbucket_signature_rec([_ | Rest], Node, Acc, Idx) ->
    master_vbucket_signature_rec(Rest, Node, Acc, Idx+1).
