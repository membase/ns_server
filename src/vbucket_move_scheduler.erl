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
%% @doc this module implements state machine that decides which
%% vbucket moves can be started when and when necessary view
%% compactions can be performed.
%%
%% Overall idea is we want to move as many vbuckets as possible in
%% parallel but there are certain limits that we still need to
%% enforce. More below.
%%
%% Input is old and new vbucket map, from which it computes moves as
%% well as 2 parameters that describe concurrency limits.
%%
%% First limit is number of concurrent tap backfills into/out-of any
%% node. The idea is moving vbucket involves reading entire vbucket
%% from disk and sending it to destination node where entire vbucket
%% needs to be persisted. While this phase of vbucket move occurs
%% between this two nodes it's undesirable to do backfill phase
%% affecting any of those two nodes concurrently. We support limit
%% higher than 1, but in actual product it's 1.
%%
%% Second limit is how many vbucket we move into/out-of any node
%% before pausing moves and forcing views compaction.
%%
%% Current model of actions required as part of vbucket move are:
%%
%% a) build complete replica of vbucket on future master (backfill
%% phase). For this phase as pointed out above we have first limit
%% that affects both old master and future master. Note: we
%% consciously ignore the fact that we can also have incoming
%% backfills into future replicas in this phase. Those backfills
%% currently are currently not affected by or affect any limits.
%%
%% b) ensure that indexes are built for new vbucket on new master and
%% rest of vbucket takeover. That phase notably can happen
%% concurrently for many vbuckets on any node for both incoming and
%% outgoing vbucket moves. We actually try to pack as many of them as
%% possible so that indexer which is currently slowest part of
%% rebalance is always busy.
%%
%% c) (involves multiple vbucket moves at once) do view
%% compaction. This phase _cannot_ happen concurrently with any
%% vbucket moves. I.e. we want views to be as quiescent as possible
%% (i.e. no massive indexing of incoming vbucket moves at least). As
%% noted above we try to do several vbucket moves before pausing for
%% views compactions. Because compacting after every single vbucket
%% move is expensive.
%%
%% See image below (drawn by Aaron Miller. Many thanks):
%%
%%           VBucket Move Scheduling
%% Time
%%
%%   |   /------------\
%%   |   | Backfill 0 |                       Backfills cannot happen
%%   |   \------------/                       concurrently.
%%   |         |             /------------\
%%   |   +------------+      | Backfill 1 |
%%   |   | Index File |      \------------/
%%   |   |     0      |            |
%%   |   |            |      +------------+   However, indexing _can_ happen
%%   |   |            |      | Index File |   concurrently with backfills and
%%   |   |            |      |     1      |   other indexing.
%%   |   |            |      |            |
%%   |   +------------+      |            |
%%   |         |             |            |
%%   |         |             +------------+
%%   |         |                   |
%%   |         \---------+---------/
%%   |                   |
%%   |   /--------------------------------\   Compaction for a set of vbucket moves
%%   |   |  Compact both source and dest. |   cannot happen concurrently with other
%%   v   \--------------------------------/   vbucket moves.
%%
%%
%% In that image you can see that backfills of 2 vbuckets between same
%% pair of nodes cannot happen concurrently, but next phase is
%% concurrent, after which there's view compaction on both nodes that
%% logically affect both moves (and prevent other concurrent moves)
%%
%% vbucket moves are picked w.r.t. this 2 constrains and we also have
%% heuristics to decide which moves to proceed based on the following
%% understanding of goodness:
%%
%% a) we want to start moving active vbuckets sooner. I.e. prioritize
%% moves that change master node and not just replicas. So that
%% balance w.r.t. node's load on GETs and SETs is more quickly
%% equalized.
%%
%% b) given that indexer is our bottleneck we want as much as possible
%% nodes to do some indexing work all or most of the time

-module(vbucket_move_scheduler).

-include("ns_common.hrl").

-export([prepare/5,
         is_done/1,
         choose_action/1,
         extract_progress/1,
         note_backfill_done/2,
         note_move_completed/2,
         note_compaction_done/2]).

-type move() :: {VBucket :: vbucket_id(),
                 ChainBefore :: [node() | undefined],
                 ChainAfter :: [node() | undefined]}.

%% all possible types of actions are moves and compactions
-type action() :: {move, move()} |
                  {compact, node()}.


-record(state, {
          backfills_limit :: non_neg_integer(),
          moves_before_compaction :: non_neg_integer(),
          total_in_flight = 0 :: non_neg_integer(),
          moves_left_count_per_node :: dict(), % node() -> non_neg_integer()
          moves_left :: [move()],

          %% pending moves when current master is undefined For them
          %% we don't have any limits and compaction is not needed.
          %% And that's first moves that we ever consider doing
          moves_from_undefineds :: [move()],

          compaction_countdown_per_node :: dict(), % node() -> non_neg_integer()
          in_flight_backfills_per_node :: dict(),  % node() -> non_neg_integer() (I.e. counts current moves)
          in_flight_per_node :: dict(),            % node() -> non_neg_integer() (I.e. counts current moves)
          in_flight_compactions :: set(),          % set of nodes

          initial_move_counts :: dict(),
          left_move_counts :: dict()
         }).

letrec(Args, F) ->
    erlang:apply(F, [F | Args]).

%% @doc prepares state (list of moves etc) based on current and target map
prepare(CurrentMap, TargetMap, BackfillsLimit, MovesBeforeCompaction, InfoLogger) ->
    %% Dictionary mapping old node to vbucket and new node
    MapTriples = lists:zip3(lists:seq(0, length(CurrentMap) - 1),
                            CurrentMap,
                            TargetMap),
    {Moves, UndefinedMoves, TrivialMoves} =
        letrec(
          [MapTriples, [], [], 0],
          fun (Rec, MapTriples0, MovesAcc, UndefinedMoves0, TrivialMoves0) ->
                  case MapTriples0 of
                      [] ->
                          {MovesAcc, UndefinedMoves0, TrivialMoves0};
                      [{_V, C1, C2} = Move | RestMapTriples] ->
                          if
                              hd(C1) =:= undefined ->
                                  Rec(Rec, RestMapTriples, MovesAcc, [Move | UndefinedMoves0], TrivialMoves0);
                              C1 =:= C2 ->
                                  Rec(Rec, RestMapTriples, MovesAcc, UndefinedMoves0, TrivialMoves0 + 1);
                              true ->
                                  Rec(Rec, RestMapTriples, [Move | MovesAcc], UndefinedMoves0, TrivialMoves0)
                          end
                  end
          end),

    NewDict = dict:new(),

    MovesPerNode =
        letrec([Moves, NewDict],
               fun (_Rec, [] = _Moves, MovesPerNode0) ->
                       MovesPerNode0;
                   (Rec, [{_V, [Src|_], [Dst|_]} | RestMoves], MovesPerNode0) ->
                       MovesPerNode1 = case Src =:= Dst of
                                           true ->
                                               %% no index changes will be done here
                                               MovesPerNode0;
                                           _ ->
                                               D = dict:update_counter(Src, 1, MovesPerNode0),
                                               dict:update_counter(Dst, 1, D)
                                       end,
                       Rec(Rec, RestMoves, MovesPerNode1)
               end),

    InitialMoveCounts =
        letrec([Moves, NewDict],
               fun (Rec, Moves0, InitialMoveCounts0) ->
                       case Moves0 of
                           [] ->
                               InitialMoveCounts0;
                           [Move | RestMoves] ->
                               {_V, [Src|_], [Dst|_]} = Move,
                               D = dict:update_counter(Src, 1, InitialMoveCounts0),
                               InitialMoveCounts1 = dict:update_counter(Dst, 1, D),
                               Rec(Rec, RestMoves, InitialMoveCounts1)
                       end
               end),

    CompactionCountdownPerNode = dict:map(fun (_K, _V) ->
                                                  MovesBeforeCompaction
                                          end, InitialMoveCounts),

    InFlight = dict:map(fun (_K, _V) -> 0 end, InitialMoveCounts),


    State = #state{backfills_limit = BackfillsLimit,
                   moves_before_compaction = MovesBeforeCompaction,
                   total_in_flight = 0,
                   moves_left_count_per_node = MovesPerNode,
                   moves_left = Moves,
                   moves_from_undefineds = UndefinedMoves,
                   compaction_countdown_per_node = CompactionCountdownPerNode,
                   in_flight_backfills_per_node = InFlight,
                   in_flight_per_node = InFlight,
                   in_flight_compactions = sets:new(),
                   initial_move_counts = InitialMoveCounts,
                   left_move_counts = InitialMoveCounts},

    InfoLogger("The following count of vbuckets do not need to be moved at all: ~p", [TrivialMoves]),
    InfoLogger("The following moves are planned:~n~p", [UndefinedMoves ++ Moves]),
    %% InfoLogger("State:~n~p", [State]),

    State.

%% @doc true iff we're done. NOTE: is_done is only valid if
%% choose_action returned empty actions list
is_done(#state{moves_left = MovesLeft,
               total_in_flight = TotalInFlight,
               in_flight_compactions = InFlightCompactions} = _State) ->
    MovesLeft =:= []
        andalso TotalInFlight =:= 0 andalso sets:new() =:= InFlightCompactions.

updatef(Record, Field, Body) ->
    V = erlang:element(Field, Record),
    NewV = Body(V),
    erlang:setelement(Field, Record, NewV).


consider_starting_compaction(State) ->
    dict:fold(
      fun (Node, Counter, Acc0) ->
              CanDo0 = dict:fetch(Node, State#state.in_flight_per_node) =:= 0,
              CanDo1 = CanDo0 andalso not sets:is_element(Node, State#state.in_flight_compactions),
              CanDo2 = CanDo1 andalso (Counter =:= 0 orelse (Counter < State#state.moves_before_compaction
                                                             andalso dict:fetch(Node, State#state.moves_left_count_per_node) =:= 0)),
              case CanDo2 of
                  true ->
                      [Node | Acc0];
                  _ ->
                      Acc0
              end
      end, [], State#state.compaction_countdown_per_node).

%% builds list of actions to do now (in passed state) and returns it
%% with new state (assuming actions are started)
-spec choose_action(#state{}) -> {[action()], #state{}}.
choose_action(#state{moves_from_undefineds = [_|_] = Moves} = State) ->
    NewState = State#state{moves_from_undefineds = []},
    {OtherActions, NewState2} = choose_action(NewState),
    {OtherActions ++ [{move, M} || M <- Moves], NewState2};
choose_action(State) ->
    Nodes = consider_starting_compaction(State),
    NewState = updatef(State, #state.in_flight_compactions,
                       fun (InFlightCompactions) ->
                               lists:foldl(fun sets:add_element/2, InFlightCompactions, Nodes)
                       end),
    NewState1 = updatef(NewState, #state.compaction_countdown_per_node,
                        fun (CompactionCountdownPerNode) ->
                                lists:foldl(
                                  fun (N, D0) ->
                                          dict:store(N, State#state.moves_before_compaction, D0)
                                  end, CompactionCountdownPerNode, Nodes)
                        end),
    {OtherActions, NewState2} = choose_action_not_compaction(NewState1),
    Actions = letrec([Nodes],
                     fun (_Rec, []) ->
                             OtherActions;
                         (Rec, [N | RestNodes]) ->
                             [{compact, N} | Rec(Rec, RestNodes)]
                     end),
    {Actions, NewState2}.

sortby(List, KeyFn, LessEqFn) ->
    KeyedList = [{KeyFn(E), E} || E <- List],
    KeyedSorted = lists:sort(fun ({KA, _}, {KB, _}) ->
                                     LessEqFn(KA, KB)
                             end, KeyedList),
    [E || {_, E} <- KeyedSorted].

move_is_possible(Src, Dst, BackfillsLimit, NowBackfills, CompactionCountdown) ->
    dict:fetch(Src, NowBackfills) < BackfillsLimit
        andalso dict:fetch(Dst, NowBackfills) < BackfillsLimit
        andalso dict:fetch(Src, CompactionCountdown) > 0
        andalso dict:fetch(Dst, CompactionCountdown) > 0.


choose_action_not_compaction(#state{
                                backfills_limit = BackfillsLimit,
                                in_flight_backfills_per_node = NowBackfills,
                                in_flight_per_node = NowInFlight,
                                in_flight_compactions = NowCompactions,
                                moves_left_count_per_node = LeftCount,
                                moves_left = MovesLeft,
                                compaction_countdown_per_node = CompactionCountdown} = State) ->
    PossibleMoves =
        lists:flatmap(fun ({_V, [Src|_], [Dst|_]} = Move) ->
                              Can1 = move_is_possible(Src, Dst, BackfillsLimit, NowBackfills, CompactionCountdown),
                              Can2 = Can1 andalso not sets:is_element(Src, NowCompactions),
                              Can3 = Can2 andalso not sets:is_element(Dst, NowCompactions),
                              case Can3 of
                                  true ->
                                      %% consider computing goodness here
                                      [Move];
                                  false ->
                                      []
                              end
                      end, MovesLeft),

    GoodnessFn =
        fun ({Vb, [Src | _], [Dst | _]}) ->
                case Src =:= Dst of
                    true ->
                        %% we under-prioritize moves that
                        %% don't actually move active
                        %% position. Because a) they don't
                        %% affect indexes and we want indexes
                        %% to be build as early and as in
                        %% parallel as possible and b)
                        %% because we want to encourage
                        %% earlier improvement of balance
                        %% w.r.t active vbuckets to equalize
                        %% GET/SET load earlier
                        Vb;
                    _ ->
                        %% our goal is to keep indexer on all nodes
                        %% busy as much as possible at all times. Thus
                        %% we prefer nodes with least current
                        %% moves. And destination is more important
                        %% because on source is it's just cleanup and
                        %% thus much less work
                        NoCompactionsG = 10000 - 10 * dict:fetch(Dst, NowInFlight) - dict:fetch(Src, NowInFlight),
                        %% all else equals we don't want to delay
                        %% index compactions
                        G2 = NoCompactionsG * 100 - dict:fetch(Dst, CompactionCountdown) - dict:fetch(Src, CompactionCountdown),
                        G3 = G2 * 10000 + dict:fetch(Dst, LeftCount) + dict:fetch(Src, LeftCount),
                        G3 * 10000 + Vb
                end
        end,

    LessEqFn = fun (GoodnessA, GoodnessB) -> GoodnessA >= GoodnessB end,
    SortedMoves = sortby(PossibleMoves, GoodnessFn, LessEqFn),

    %% case PossibleMoves =/= [] of
    %%     true ->
    %%         ?log_debug("PossibleMovesKeyed:~n~p", [begin
    %%                                                    KeyedList = [{GoodnessFn(E), E} || E <- PossibleMoves],
    %%                                                    KS = lists:sort(fun ({KA, _}, {KB, _}) ->
    %%                                                                            LessEqFn(KA, KB)
    %%                                                                    end, KeyedList),
    %%                                                    lists:sublist(KS, 20)
    %%                                                end]);
    %%     _ ->
    %%         ok
    %% end,

    %% NOTE: we know that first move is always allowed
    {SelectedMoves, NewNowBackfills, NewCompactionCountdown} =
        letrec([SortedMoves, NowBackfills, CompactionCountdown, []],
               fun (Rec, [{_V, [Src|_], [Dst|_]} = Move | RestMoves], NowBackfills0, CompactionCountdown0, Acc) ->
                       case move_is_possible(Src, Dst, BackfillsLimit, NowBackfills0, CompactionCountdown0) of
                           true ->
                               NowBackfills1 = dict:update_counter(Src, 1, NowBackfills0),
                               NowBackfills2 = case Src =:= Dst of
                                                   true ->
                                                       NowBackfills1;
                                                   _ ->
                                                       dict:update_counter(Dst, 1, NowBackfills1)
                                               end,
                               CompactionCountdown1 = case Src =:= Dst of
                                                          true ->
                                                              CompactionCountdown0;
                                                            _ ->
                                                              D = dict:update_counter(Src, -1, CompactionCountdown0),
                                                              dict:update_counter(Dst, -1, D)
                                                        end,
                               NewAcc = [Move | Acc],
                               Rec(Rec, RestMoves, NowBackfills2, CompactionCountdown1, NewAcc);
                           _ ->
                               Rec(Rec, RestMoves, NowBackfills0, CompactionCountdown0, Acc)
                       end;
                   (_Rec, [], NowBackfills0, MovesBeforeCompaction0, Acc) ->
                       {Acc, NowBackfills0, MovesBeforeCompaction0}
               end),

    NewMovesLeft = MovesLeft -- SelectedMoves,
    {NewLeftCount, NewNowInFlight} =
        letrec([SelectedMoves, LeftCount, NowInFlight],
               fun (Rec, SelectedMoves0, LeftCount0, NowInFlight0) ->
                       case SelectedMoves0 of
                           [] ->
                               {LeftCount0, NowInFlight0};
                           [{_V, [Src|_], [Dst|_]} | RestMoves] ->
                               LeftCount1 = case Src =:= Dst of
                                                true ->
                                                    LeftCount0;
                                                false ->
                                                    D = dict:update_counter(Src, -1, LeftCount0),
                                                    dict:update_counter(Dst, -1, D)
                                            end,
                               NowInFlight1 = dict:update_counter(Src, 1, NowInFlight0),
                               NowInFlight2 = case Src =:= Dst of
                                                  true ->
                                                      NowInFlight1;
                                                  _ ->
                                                      dict:update_counter(Dst, 1, NowInFlight1)
                                              end,
                               Rec(Rec, RestMoves, LeftCount1, NowInFlight2)
                       end
               end),

    NewState = State#state{in_flight_backfills_per_node = NewNowBackfills,
                           in_flight_per_node = NewNowInFlight,
                           total_in_flight = State#state.total_in_flight + length(SelectedMoves),
                           moves_left_count_per_node = NewLeftCount,
                           moves_left = NewMovesLeft,
                           compaction_countdown_per_node = NewCompactionCountdown},

    case SelectedMoves of
        [] ->
            {newstate, true} = {newstate, State =:= NewState},
            {[], State};
        _ ->
            {MoreMoves, NewState2} = choose_action_not_compaction(NewState),
            {MoreMoves ++ [{move, M} || M <- SelectedMoves], NewState2}
    end.

extract_progress(#state{initial_move_counts = InitialCounts,
                        left_move_counts = LeftCounts} = _State) ->
    dict:map(fun (Node, ThisInitialCount) ->
                     ThisLeftCount = dict:fetch(Node, LeftCounts),
                     1.0 - ThisLeftCount / ThisInitialCount
             end, InitialCounts).

%% @doc marks backfill phase of previously started move as done. Users
%% of this code will call it when backfill is done to update state so
%% that next moves can be started.
note_backfill_done(State, {move, {_V, [undefined|_], [_Dst|_]}}) ->
    State;
note_backfill_done(State, {move, {_V, [Src|_], [Dst|_]}}) ->
    updatef(State, #state.in_flight_backfills_per_node,
            fun (NowBackfills) ->
                    NowBackfills1 = dict:update_counter(Src, -1, NowBackfills),
                    case Src =:= Dst of
                        true ->
                            NowBackfills1;
                        _ ->
                            dict:update_counter(Dst, -1, NowBackfills1)
                    end
            end).

%% @doc marks entire move that was previously started done. NOTE: this
%% assumes that backfill phase of this move was previously marked as
%% done. Users of this code will call it when move is done to update
%% state so that next moves and/or compactions can be started.
note_move_completed(State, {move, {_V, [undefined|_], [_Dst|_]}}) ->
    State;
note_move_completed(State, {move, {_V, [Src|_], [Dst|_]}}) ->
    State1 =
        updatef(State, #state.in_flight_per_node,
                fun (NowInFlight) ->
                        NowInFlight1 = dict:update_counter(Src, -1, NowInFlight),
                        case Src =:= Dst of
                            true ->
                                NowInFlight1;
                            _ ->
                                dict:update_counter(Dst, -1, NowInFlight1)
                        end
                end),
    State2 =
        updatef(State1, #state.left_move_counts,
                fun (LeftMoveCounts) ->
                        D = dict:update_counter(Src, -1, LeftMoveCounts),
                        dict:update_counter(Dst, -1, D)
                end),
    updatef(State2, #state.total_in_flight, fun (V) -> V - 1 end).

%% @doc marks previously started compaction as done. Users of this
%% code will call it when compaction is done to update state so that
%% next moves and/or compactions can be started.
note_compaction_done(State, {compact, Node}) ->
    updatef(State, #state.in_flight_compactions,
            fun (InFlightCompactions) ->
                    sets:del_element(Node, InFlightCompactions)
            end).
