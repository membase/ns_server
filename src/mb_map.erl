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
         promote_replicas_for_graceful_failover/2,
         generate_map/3,
         is_balanced/3,
         is_valid/1,
         random_map/3,
         vbucket_movements/2,
         run_rebalance_counts_experiment/0,
         find_matching_past_maps/4, score_maps/3, best_map/2]).


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

promote_replicas_for_graceful_failover(Map, RemoveNode) ->
    [promote_replicas_for_graceful_failover_for_chain(Chain, RemoveNode) || Chain <- Map].

promote_replicas_for_graceful_failover_for_chain(Chain, RemoveNode) ->
    {RealChain, Undefineds} = lists:partition(fun (N) -> N =/= undefined end, Chain),
    ChangedChain = case RealChain of
                       [RemoveNode | Rest = [_|_]] ->
                           Rest ++ [RemoveNode];
                       _ ->
                           RealChain
                   end,
    ChangedChain ++ Undefineds.

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

vbucket_movements_star(Src, Dst) ->
    {Takeovers, _, ReplicaChanges} = vbucket_movements(Src, Dst),
    {Takeovers, ReplicaChanges}.

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
    matching_renamings_with_tags(KeepNodesSet,
                                 {CurrentMap, undefined}, {CandidateMap, undefined}).

matching_renamings_with_tags(KeepNodesSet,
                             {CurrentMap, CurrentTags0}, {CandidateMap, CandidateTags0}) ->
    CurrentTags = case CurrentTags0 of
                      undefined ->
                          [];
                      _ ->
                          CurrentTags0
                  end,
    CandidateTags = case CandidateTags0 of
                        undefined ->
                            [];
                        _ ->
                            CandidateTags0
                    end,

    case length(CandidateMap) =:= length(CurrentMap) of
        false ->
            [];
        _ ->
            case length(hd(CandidateMap)) =:= length(hd(CurrentMap)) of
                true ->
                    matching_renamings_same_vbuckets_count(KeepNodesSet, CurrentTags,
                                                           CandidateMap, CandidateTags);
                false ->
                    []
            end
    end.

do_rewrite(Term, Pairs) ->
    misc:rewrite(
      fun (T) ->
              case lists:keyfind(T, 1, Pairs) of
                  false ->
                      continue;
                  {_, NewT} ->
                      {stop, NewT}
              end
      end, Term).

rewrite_map(CandidateMap, CandidateTags, CurrentTags, Pairs) ->
    CandidateMap1 = do_rewrite(CandidateMap, Pairs),
    CandidateTags1 = lists:sort(do_rewrite(CandidateTags, Pairs)),
    CurrentTags1 = lists:sort(CurrentTags),
    case CandidateTags1 =:= CurrentTags1 of
        true ->
            [CandidateMap1];
        false ->
            matching_tag_renaming(CandidateMap1, CandidateTags1, CurrentTags1)
    end.

matching_tag_renaming(CandidateMap, CandidateTags, CurrentTags) ->
    [CandidateHist, CurrentHist] =
        lists:map(
          fun (Tags) ->
                  Hist = lists:foldl(
                           fun ({Node, Tag}, D) ->
                                   dict:update(
                                     Tag,
                                     fun ({C, S}) ->
                                             {C + 1, sets:add_element(Node, S)}
                                     end, {1, sets:from_list([Node])}, D)
                           end, dict:new(), Tags),

                  lists:sort(
                    fun ({_, {CountA, _}}, {_, {CountB, _}}) ->
                            CountA =< CountB
                    end, dict:to_list(Hist))
          end, [CandidateTags, CurrentTags]),

    case [C || {_, {C, _}} <- CandidateHist] =:= [C || {_, {C, _}} <- CurrentHist] of
        true ->
            matching_tag_renaming_with_hists(CandidateMap, CandidateHist, CurrentHist);
        false ->
            []
    end.

matching_tag_renaming_with_hists(CandidateMap, CandidateHist, CurrentHist) ->
    TagRenaming = build_tag_renaming(lists:zip(CandidateHist, CurrentHist)),
    MapRenaming =
        lists:foldl(
          fun ({{_, CandidateNodes}, {_, CurrentNodes}}, Acc) ->
                  OldNodes = sets:to_list(sets:subtract(CandidateNodes, CurrentNodes)),
                  NewNodes = sets:to_list(sets:subtract(CurrentNodes, CandidateNodes)),

                  lists:zip(OldNodes, NewNodes) ++ Acc
          end, [], TagRenaming),

    [do_rewrite(CandidateMap, MapRenaming)].

build_tag_renaming([]) ->
    [];
build_tag_renaming([{{_, {Count, _}}, _} | _] = Hists) ->
    {EqualTags, Rest} =
        lists:splitwith(
          fun ({{_, {C, _}}, {_, {C, _}}}) ->
                  C == Count
          end, Hists),

    {CandidateTags, CurrentTags} = lists:unzip(EqualTags),

    {[], TagRenaming} =
        lists:foldl(
          fun ({CandidateTag, {_, CandidateNodes}}, {AccCurrentTags, AccRenaming}) ->
                  {{BestTag, {_, BestNodes}} = Best, _} =
                      lists:foldl(
                        fun ({_CurrentTag, {_, CurrentNodes}} = Current, AccBest) ->
                                CommonNodes = sets:intersection(CurrentNodes, CandidateNodes),
                                CommonSize = sets:size(CommonNodes),

                                case AccBest of
                                    undefined ->
                                        {Current, CommonSize};
                                    {_Other, OtherSize} when OtherSize < CommonSize ->
                                        {Current, CommonSize};
                                    _ ->
                                        AccBest
                                end
                        end, undefined, AccCurrentTags),
                  AccCurrentTags1 = AccCurrentTags -- [Best],
                  Renaming = {{CandidateTag, CandidateNodes}, {BestTag, BestNodes}},
                  {AccCurrentTags1, [Renaming | AccRenaming]}
          end, {CurrentTags, []}, CandidateTags),

    TagRenaming ++ build_tag_renaming(Rest).

matching_renamings_same_vbuckets_count(KeepNodesSet, CurrentTags,
                                       CandidateMap, CandidateTags) ->
    CandidateNodesSet = map_nodes_set(CandidateMap),
    case sets:size(CandidateNodesSet) =:= sets:size(KeepNodesSet) of
        false ->
            [];
        true ->
            CurrentNotCommon = sets:subtract(KeepNodesSet, CandidateNodesSet),
            case sets:size(CurrentNotCommon) of
                0 ->
                    case lists:sort(CandidateTags) == lists:sort(CurrentTags) of
                        true ->
                            [CandidateMap];
                        false ->
                            matching_tag_renaming(CandidateMap,
                                                  CandidateTags, CurrentTags)
                    end;
                1 ->
                    [NewNode] = sets:to_list(CurrentNotCommon),
                    [OldNode] = sets:to_list(sets:subtract(CandidateNodesSet, KeepNodesSet)),

                    rewrite_map(CandidateMap, CandidateTags, CurrentTags,
                                [{OldNode, NewNode}]);
                2 ->
                    [NewNodeA, NewNodeB] = sets:to_list(CurrentNotCommon),
                    [OldNodeA, OldNodeB] = sets:to_list(sets:subtract(CandidateNodesSet, KeepNodesSet)),

                    rewrite_map(CandidateMap, CandidateTags, CurrentTags,
                                [{OldNodeA, NewNodeA}, {OldNodeB, NewNodeB}]) ++
                        rewrite_map(CandidateMap, CandidateTags, CurrentTags,
                                    [{OldNodeA, NewNodeB}, {OldNodeB, NewNodeA}]);
                _ ->
                    %% just try some random mapping just in case. It
                    %% will work nicely if NewNode-s are all being
                    %% added to cluster (and CurrentNode-s thus
                    %% removed). Because in such case exact mapping
                    %% doesn't really matter, because we'll backfill
                    %% new nodes and it doesn't matter which.
                    CandidateNotCommon = sets:to_list(sets:subtract(CandidateNodesSet, KeepNodesSet)),

                    rewrite_map(CandidateMap, CandidateTags, CurrentTags,
                                lists:zip(CandidateNotCommon, sets:to_list(CurrentNotCommon)))
            end
    end.

%%
%% API
%%

generate_map(Map, Nodes, Options) ->
    Topology = proplists:get_value(replication_topology, Options, chain),
    Tags = proplists:get_value(tags, Options),
    NumReplicas = length(hd(Map)) - 1,

    UseOldCode = Topology =:= chain
        orelse (Tags =:= undefined andalso NumReplicas =< 1),

    case UseOldCode of
        true ->
            generate_map_chain(Map, Nodes, Options);
        false ->
            generate_map_star(Map, Nodes, Options)
    end.

is_compatible_past_star_map(OptionsPast0, OptionsNow0, NumReplicas) ->
    OptionsPast = lists:keydelete(tags, 1, OptionsPast0),
    OptionsNow = lists:keydelete(tags, 1, OptionsNow0),

    case OptionsNow =:= OptionsPast of
        true ->
            true;
        false ->
            NonTopologyOptionsPast =
                lists:keydelete(replication_topology, 1, OptionsPast),
            NonTopologyOptionsNow =
                lists:keydelete(replication_topology, 1, OptionsNow),

            NonTopologyOptionsPast =:= NonTopologyOptionsNow andalso
                NumReplicas =:= 1
    end.

generate_map_star(Map, Nodes, Options) ->
    KeepNodes = lists:sort(Nodes),
    MapsHistory = proplists:get_value(maps_history, Options, []),

    NumVBuckets = length(Map),
    NumSlaves = proplists:get_value(max_slaves, Options, 10),
    NumReplicas = length(hd(Map)) - 1,
    Tags = proplists:get_value(tags, Options),

    MapsFromPast0 = find_matching_past_maps(Nodes, Map, Options, MapsHistory),
    MapsFromPast = score_maps(Map, Options, MapsFromPast0),
    ?log_debug("Scores for past maps:~n~p", [[S || {_, S} <- MapsFromPast]]),

    GeneratedMaps0 =
        lists:append(
          %% vbmap itself randomizes some things internally so let's give it a
          %% chance
          [[invoke_vbmap(Map, ShuffledNodes, NumVBuckets,
                         NumSlaves, NumReplicas, Tags) ||
               _ <- lists:seq(1, 3)] ||
              ShuffledNodes <- [misc:shuffle(KeepNodes) || _ <- lists:seq(1, 3)]]),

    GeneratedMaps = score_maps(Map, Options, GeneratedMaps0),
    ?log_debug("Scores for generated maps:~n~p", [[S || {_, S} <- GeneratedMaps]]),

    AllMaps = sets:to_list(sets:from_list(GeneratedMaps ++ MapsFromPast)),

    ?log_debug("Considering ~p maps:~n~p",
               [length(AllMaps), [S || {_, S} <- AllMaps]]),
    BestMapScore = best_map(Options, AllMaps),
    BestMap = element(1, BestMapScore),
    ?log_debug("Best map score: ~p (~p)",
               [element(2, BestMapScore),
                lists:keymember(BestMap, 1, GeneratedMaps)]),
    BestMap.

map_scores_less({_, ScoreA}, {_, ScoreB}) ->
    {element(1, ScoreA) + element(2, ScoreA), element(3, ScoreA)} < {element(1, ScoreB) + element(2, ScoreB), element(3, ScoreB)}.

generate_map_chain(Map, Nodes, Options) ->
    KeepNodes = lists:sort(Nodes),
    MapsHistory = proplists:get_value(maps_history, Options, []),

    NaturalMap = balance(Map, KeepNodes, Options),
    [NaturalMapScore] = score_maps(Map, Options, [NaturalMap]),

    ?log_debug("Natural map score: ~p", [element(2, NaturalMapScore)]),

    RndMap1 = balance(Map, misc:shuffle(Nodes), Options),
    RndMap2 = balance(Map, misc:shuffle(Nodes), Options),

    AllRndMapScores = [RndMap1Score, RndMap2Score] = score_maps(Map, Options, [RndMap1, RndMap2]),

    ?log_debug("Rnd maps scores: ~p, ~p", [S || {_, S} <- AllRndMapScores]),

    MapsFromPast0 = find_matching_past_maps(Nodes, Map, Options, MapsHistory),
    MapsFromPast = score_maps(Map, Options, MapsFromPast0),

    AllMaps = sets:to_list(sets:from_list([NaturalMapScore, RndMap1Score, RndMap2Score | MapsFromPast])),

    ?log_debug("Considering ~p maps:~n~p", [length(AllMaps), [S || {_, S} <- AllMaps]]),

    BestMapScore = best_map(Options, AllMaps),

    BestMap = element(1, BestMapScore),
    ?log_debug("Best map score: ~p (~p,~p,~p)", [element(2, BestMapScore), (BestMap =:= NaturalMap), (BestMap =:= RndMap1), (BestMap =:= RndMap2)]),
    BestMap.

%% @doc Generate a balanced map.
balance(Map, KeepNodes, Options) ->
    NumNodes = length(KeepNodes),
    NumVBuckets = length(Map),
    OrigCopies = length(hd(Map)),
    NumCopies = erlang:min(NumNodes, OrigCopies),
    %% We always use the slave assignment machinery.
    MaxSlaves = proplists:get_value(max_slaves, Options, NumNodes - 1),
    Slaves = slaves(KeepNodes, MaxSlaves),
    Chains = chains(KeepNodes, NumVBuckets, NumCopies, Slaves),
    Map1 = simple_minimize_moves(Map, Chains, NumCopies, KeepNodes),
    if NumCopies < OrigCopies ->
            %% Extend the map back out the original number of copies
            Extension = lists:duplicate(OrigCopies - NumCopies, undefined),
            [Chain ++ Extension || Chain <- Map1];
       true ->
            Map1
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
                            ?log_debug("Histograms = ~w~n", [Histograms]),
                            ?log_debug("Counts = ~p~n", [dict:to_list(counts(Map))]),
                            false;
                        true ->
                            Counts = counts(Map),
                            SlaveCounts = count_slaves(Counts),
                            NumNodes = length(Nodes),
                            NumSlaves = erlang:min(
                                          proplists:get_value(
                                            max_slaves, Options, NumNodes-1),
                                          NumNodes-1),
                            ?log_debug("Counts = ~p~n", [dict:to_list(counts(Map))]),
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

find_matching_past_maps(Nodes, Map, Options, History) ->
    Topology = proplists:get_value(replication_topology, Options, chain),
    Options1 = lists:sort(lists:keydelete(maps_history, 1, Options)),
    NodesSet = sets:from_list(Nodes),
    find_matching_past_maps(Topology, NodesSet, Map, Options1, History).

find_matching_past_maps(chain, NodesSet, Map, Options, History) ->
    lists:flatmap(fun ({PastMap, NonHistoryOptions0}) ->
                          NonHistoryOptions = lists:sort(NonHistoryOptions0),
                          case NonHistoryOptions =:= Options of
                              true ->
                                  matching_renamings(NodesSet, Map, PastMap);
                              false ->
                                  []
                          end
                  end, History);
find_matching_past_maps(star, NodesSet, Map, Options, History) ->
    NumReplicas = length(hd(Map)) - 1,
    Tags = proplists:get_value(tags, Options),

    lists:flatmap(fun ({PastMap, NonHistoryOptions0}) ->
                          NonHistoryOptions = lists:sort(NonHistoryOptions0),
                          PastTags = proplists:get_value(tags, NonHistoryOptions),

                          Compatible =
                              is_compatible_past_star_map(NonHistoryOptions, Options, NumReplicas),
                          case Compatible of
                              true ->
                                  matching_renamings_with_tags(NodesSet, {Map, Tags},
                                                               {PastMap, PastTags});
                              false ->
                                  []
                          end
                  end, History).

score_maps(CurrentMap, Options, Maps) ->
    Topology = proplists:get_value(replication_topology, Options, chain),
    do_score_maps(Topology, CurrentMap, Maps).

do_score_maps(chain, CurrentMap, Maps) ->
    [{M, vbucket_movements(CurrentMap, M)} || M <- Maps];
do_score_maps(star, CurrentMap, Maps) ->
    [{M, vbucket_movements_star(CurrentMap, M)} || M <- Maps].

best_map(Options, Maps) ->
    Topology = proplists:get_value(replication_topology, Options, chain),
    do_best_map(Topology, Maps).

do_best_map(chain, Maps) ->
    misc:min_by(fun map_scores_less/2, Maps);
do_best_map(star, Maps) ->
    misc:keymin(2, Maps).


%%
%% Internal functions
%%

simple_minimize_moves(Map, Chains, NumCopies, KeepNodes) ->
    %% Strip nodes we're removing along with extra copies
    Map1 = map_strip(Map, NumCopies, KeepNodes),

    %% Turn the map into a list of {VBucket, Chain} pairs.
    NumberedMap = lists:zip(lists:seq(0, length(Map1) - 1), Map1),

    %% Sort the candidate chains.
    SortedChains = lists:sort(Chains),

    {Pairs, [], []} =
        lists:foldl(fun (Shift, {R, M, C}) ->
                            {R1, M1, C1} = do_simple_minimize_moves(M, C, Shift),
                            {R1 ++ R, M1, C1}
                    end, {[], NumberedMap, SortedChains},
                    lists:seq(0, NumCopies)),

    %% We can simply sort the pairs because the first element of the
    %% first tuple is the vbucket number.
    [Chain || {_, Chain} <- lists:sort(Pairs)].

do_simple_minimize_moves(NumberedMap, SortedChains, Shift) ->
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
    [list_to_atom([$n | tl(integer_to_list(1000+N))]) || N <- lists:seq(1, NumNodes)].

invoke_vbmap(CurrentMap, Nodes, NumVBuckets, NumSlaves, NumReplicas, Tags) ->
    VbmapName =
        case erlang:system_info(system_architecture) of
            "win32" ->
                "vbmap.exe";
            _ ->
                "vbmap"
        end,

    VbmapPath = path_config:component_path(bin, VbmapName),
    DiagPath = path_config:tempfile("vbmap_diag", ""),

    try
        {ok, Map} = do_invoke_vbmap(VbmapPath, DiagPath, CurrentMap, Nodes,
                                    NumVBuckets, NumSlaves, NumReplicas, Tags),
        Map
    after
        file:delete(DiagPath)
    end.

do_invoke_vbmap(VbmapPath, DiagPath,
                CurrentMap, Nodes, NumVBuckets, NumSlaves, NumReplicas, Tags) ->
    misc:executing_on_new_process(
      fun () ->
              do_invoke_vbmap_body(VbmapPath, DiagPath, CurrentMap, Nodes,
                                   NumVBuckets, NumSlaves, NumReplicas, Tags)
      end).

do_invoke_vbmap_body(VbmapPath, DiagPath, CurrentMap, Nodes,
                     NumVBuckets, NumSlaves, NumReplicas, Tags) ->
    NumNodes = length(Nodes),

    Args0 = ["--diag", DiagPath,
             "--output-format", "json",
             "--num-vbuckets", integer_to_list(NumVBuckets),
             "--num-nodes", integer_to_list(NumNodes),
             "--num-slaves", integer_to_list(NumSlaves),
             "--num-replicas", integer_to_list(NumReplicas),
             "--relax-all"],
    Args = vbmap_tags_args(Nodes, Tags) ++ Args0,

    Port = erlang:open_port({spawn_executable, VbmapPath},
                            [stderr_to_stdout, binary,
                             stream, exit_status, hide,
                             {args, Args}]),

    PortResult = collect_vbmap_output(Port),

    case file:read_file(DiagPath) of
        {ok, Diag} ->
            ?log_debug("vbmap diag output:~n~s", [Diag]);
        Error ->
            ?log_warning("Couldn't read vbmap diag output: ~p", [Error])
    end,

    case PortResult of
        {ok, Output} ->
            NodesMapping = dict:from_list(misc:enumerate(Nodes, 0)),

            try
                Chains0 = ejson:decode(Output),
                Chains = lists:map(
                           fun (Chain) ->
                                 [dict:fetch(N, NodesMapping) || N <- Chain]
                           end, Chains0),

                EffectiveNumCopies = length(hd(Chains)),

                Map0 = simple_minimize_moves(CurrentMap, Chains,
                                             EffectiveNumCopies, Nodes),

                Map =
                    case EffectiveNumCopies < NumReplicas + 1 of
                        true ->
                            N = NumReplicas + 1 - EffectiveNumCopies,
                            Extension = lists:duplicate(N, undefined),
                            [Chain ++ Extension || Chain <- Map0];
                        false ->
                            Map0
                    end,

                {ok, Map}
            catch
                E:T ->
                    ?log_error("seems that vbmap produced invalid json (error ~p):~n~s",
                               [{E, T}, Output]),
                    erlang:raise(E, T, erlang:get_stacktrace())
            end;
        {no_solution, _} ->
            no_solution;
        {error, Output} ->
            ?log_error("Could not generate vbucket map: ~s", [Output]),
            exit({vbmap_error, iolist_to_binary(Output)})
    end.

map_tags(Nodes, RawTags) ->
    {_, NodeIxMap} =
        lists:foldl(
          fun (Node, {Ix, Acc}) ->
                  Acc1 = dict:store(Node, Ix, Acc),
                  {Ix + 1, Acc1}
          end, {0, dict:new()}, Nodes),

    {_, TagIxMap} =
        lists:foldl(
          fun (Tag, {Ix, Acc}) ->
                  case dict:find(Tag, Acc) of
                      {ok, _} ->
                          {Ix, Acc};
                      error ->
                          Acc1 = dict:store(Tag, Ix, Acc),
                          {Ix + 1, Acc1}
                  end
          end, {0, dict:new()}, [T || {_, T} <- RawTags]),

    [{dict:fetch(N, NodeIxMap), dict:fetch(T, TagIxMap)} || {N, T} <- RawTags].

vbmap_tags_args(Nodes, RawTags) ->
        case RawTags of
            undefined ->
                [];
            _ ->
                Tags = map_tags(Nodes, RawTags),
                TagsStrings = [?i2l(N) ++ ":" ++ ?i2l(T) || {N, T} <- Tags],
                TagsString = string:join(TagsStrings, ","),
                ["--tags", TagsString]
        end.

collect_vbmap_output(Port) ->
    do_collect_vbmap_output(Port, []).

do_collect_vbmap_output(Port, Output) ->
    receive
        {Port, {data, Data}} ->
            do_collect_vbmap_output(Port, [Output | Data]);
        {Port, {exit_status, Status}} ->
            {decode_vbmap_status(Status), Output};
        Msg ->
            ?log_error("Got unexpected message"),
            exit({unexpected_message, Msg})
    end.

decode_vbmap_status(0) -> ok;
decode_vbmap_status(1) -> no_solution;
decode_vbmap_status(_) -> error.

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

simple_movements(MapFrom, MapTo) ->
    lists:sum([length(lists:usort(ChainTo -- ChainFrom) -- [undefined])
               || {ChainFrom, ChainTo} <- lists:zip(MapFrom, MapTo)]).

rebalance_count_experiment(From, To) when From =:= To ->
    0;
rebalance_count_experiment(From, To) ->
    NodesBefore = testnodes(From),
    NodesAfter = testnodes(To),
    Initial = lists:duplicate(1024, lists:duplicate(2, undefined)),
    BeforeMap = generate_map(Initial, NodesBefore, [{max_slaves, 10}]),
    AfterMap = generate_map(BeforeMap, NodesAfter, [{max_slaves, 10}]),
    [MinTF, MaxTF] = lists:sort([To, From]),
    Minimal = 1024 * 2 / MaxTF * (MaxTF - MinTF),
    IsBalancedS = is_balanced_sort_of_strongly(AfterMap, NodesAfter, [{max_slaves, 10}]),
    IsBalanced = is_balanced(AfterMap, NodesAfter, [{max_slaves, 10}]),
    io:format("~p -> ~p: ~p, min: ~p ~p ~p~n", [From, To, simple_movements(BeforeMap, AfterMap), Minimal, IsBalancedS, IsBalanced]),
    ok.

%% That's entry point. Run like this:
%% erl `find . -name ebin -type d | sed 's/^/-pa /g'` -run mb_map run_rebalance_counts_experiment -noshell | cat
run_rebalance_counts_experiment() ->
    LogLevel = error,
    {ok, _Pid} = ale_sup:start_link(),

    ok = ale:start_sink(stderr, ale_stderr_sink, []),

    lists:foreach(
      fun (Logger) ->
              ok = ale:start_logger(Logger, LogLevel),
              ok = ale:add_sink(Logger, stderr)
      end,
      ?LOGGERS),
    ale:sync_changes(infinity),

    %% begin
    %%     From = 73,
    %%     To = 75,
    %%     NodesBefore = testnodes(From),
    %%     NodesAfter = testnodes(To),
    %%     Initial = lists:duplicate(1024, lists:duplicate(2, undefined)),
    %%     BeforeMap = generate_map(Initial, NodesBefore, [{max_slaves, 10}]),
    %%     AfterMap = generate_map(BeforeMap, NodesAfter, [{max_slaves, 10}]),
    %%     io:format("~p", [lists:zip3(lists:seq(0, 1023), BeforeMap, AfterMap)]),
    %%     erlang:halt(0)
    %% end,

    [rebalance_count_experiment(From, To)
     || From <- lists:seq(1, 100),
        To <- lists:seq(1, 100)],
    erlang:halt(0).

is_balanced_sort_of_strongly(Map, Nodes, Options) ->
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
                                       lists:min(ChainHist) =< 1
                           end, lists:sublist(Histograms, NumCopies)) of
                        false ->
                            ?log_debug("Histograms = ~w~n", [Histograms]),
                            ?log_debug("Counts = ~p~n", [dict:to_list(counts(Map))]),
                            false;
                        true ->
                            Counts = counts(Map),
                            SlaveCounts = count_slaves(Counts),
                            NumNodes = length(Nodes),
                            NumSlaves = erlang:min(
                                          proplists:get_value(
                                            max_slaves, Options, NumNodes-1),
                                          NumNodes-1),
                            ?log_debug("Counts = ~p~n", [dict:to_list(counts(Map))]),
                            dict:fold(
                              fun (_, {Min, Max, SlaveCount}, Acc) ->
                                      Acc andalso SlaveCount == NumSlaves
                                          andalso Min /= really_big
                                          andalso Max > 0
                                          andalso Max - Min =< 1
                              end, true, SlaveCounts)
                    end
            end
    end.

promote_replicas_for_graceful_failover_test() ->
    M = [[a, b, c],
         [a, b, undefined],
         [b, c, a],
         [c, a, b],
         [b, c, undefined]],
    M2 = promote_replicas_for_graceful_failover(M, a),
    ?assertEqual([[b, c, a],
                  [b, a, undefined],
                  [b, c, a],
                  [c, a, b],
                  [b, c, undefined]],
                 M2),

    ?assertEqual([[a]], promote_replicas_for_graceful_failover([[a]], a)),
    ?assertEqual([[a, undefined]], promote_replicas_for_graceful_failover([[a, undefined]], a)).
