%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
-module(ns_vbucket_mover).

-behavior(gen_server).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(MAX_MOVES_PER_NODE, 1).

%% API
-export([start_link/4, stop/1]).

%% gen_server callbacks
-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-type progress_callback() :: fun((dict()) -> any()).

-record(state, {bucket::nonempty_string(),
                previous_changes,
                initial_counts::dict(),
                max_per_node::pos_integer(),
                map::array(),
                moves::dict(), movers::dict(),
                progress_callback::progress_callback()}).

%%
%% API
%%

%% @doc Start the mover.
-spec start_link(string(), map(), map(), progress_callback()) ->
                        {ok, pid()} | {error, any()}.
start_link(Bucket, OldMap, NewMap, ProgressCallback) ->
    gen_server:start_link(?MODULE, {Bucket, OldMap, NewMap, ProgressCallback},
                          []).


%% @doc Stop the in-progress moves.
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:call(Pid, stop).





%%
%% gen_server callbacks
%%

code_change(_OldVsn, _Extra, State) ->
    {ok, State}.


init({Bucket, OldMap, NewMap, ProgressCallback}) ->
    erlang:put(i_am_master_mover, true),
    erlang:put(replicas_changes, []),
    erlang:put(bucket_name, Bucket),
    erlang:put(total_changes, 0),
    erlang:put(actual_changes, 0),

    ?rebalance_info("Starting movers with new map =~n~p", [NewMap]),
    %% Dictionary mapping old node to vbucket and new node
    {MoveDict, TrivialMoves} =
        lists:foldl(fun ({V, [M1|_] = C1, C2}, {D, TrivialMoves}) ->
                            if C1 =:= C2 ->
                                    {D, TrivialMoves + 1};
                               true ->
                                    {dict:append(M1, {V, C1, C2}, D), TrivialMoves}
                            end
                    end, {dict:new(), 0},
                    lists:zip3(lists:seq(0, length(OldMap) - 1), OldMap,
                               NewMap)),
    ?rebalance_info("The following count of vbuckets do not need to be moved at all: ~p", [TrivialMoves]),
    Movers = dict:map(fun (_, _) -> 0 end, MoveDict),
    self() ! spawn_initial,
    process_flag(trap_exit, true),
    erlang:start_timer(3000, self(), maybe_sync_changes),
    {ok, #state{bucket=Bucket,
                previous_changes = [],
                initial_counts=count_moves(MoveDict),
                max_per_node=?MAX_MOVES_PER_NODE,
                map = map_to_array(OldMap),
                moves=MoveDict, movers=Movers,
                progress_callback=ProgressCallback}}.


handle_call(stop, _From, State) ->
    %% All the linked processes should exit when we do.
    {stop, normal, ok, State}.


handle_cast(unhandled, unhandled) ->
    unhandled.


%% We intentionally don't handle other exits so we'll die if one of
%% the movers fails.
handle_info({_, _, maybe_sync_changes}, #state{previous_changes = PrevChanges} = State) ->
    Changes = erlang:get('replicas_changes'),
    case Changes =:= [] orelse Changes =/= PrevChanges of
        true -> {noreply, State#state{previous_changes = Changes}};
        _ ->
            sync_replicas(),
            {noreply, State#state{previous_changes = []}}
    end;
handle_info(spawn_initial, State) ->
    spawn_workers(State);
handle_info({move_done, {Node, VBucket, OldChain, NewChain}},
            #state{movers=Movers, map=Map, bucket=Bucket} = State) ->
    %% Update replication
    update_replication_post_move(VBucket, OldChain, NewChain),
    %% Free up a mover for this node
    Movers1 = dict:update(Node, fun (N) -> N - 1 end, Movers),
    %% Pull the new chain from the target map
    %% Update the current map
    Map1 = array:set(VBucket, NewChain, Map),
    ns_bucket:set_map(Bucket, array_to_map(Map1)),
    spawn_workers(State#state{movers=Movers1, map=Map1});
handle_info({'EXIT', _, normal}, State) ->
    {noreply, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    ?rebalance_error("~p exited with ~p", [Pid, Reason]),
    {stop, Reason, State};
handle_info(Info, State) ->
    ?rebalance_info("Unhandled message ~p", [Info]),
    {noreply, State}.


terminate(_Reason, #state{map=MapArray}) ->
    sync_replicas(),
    TotalChanges = erlang:get(total_changes),
    ActualChanges = erlang:get(actual_changes),
    ?rebalance_info("Savings: ~p (from ~p)~n",
                    [TotalChanges - ActualChanges, TotalChanges]),

    %% By this time map is already updated (see move_done handler)
    ?rebalance_info("Final map is ~p", [array_to_map(MapArray)]),
    ok.


%%
%% Internal functions
%%

%% @private
%% @doc Convert a map array back to a map list.
-spec array_to_map(array()) ->
                          map().
array_to_map(Array) ->
    array:to_list(Array).


%% @private
%% @doc Count of remaining moves per node.
-spec count_moves(dict()) -> dict().
count_moves(Moves) ->
    %% Number of moves FROM a given node.
    FromCount = dict:map(fun (_, M) -> length(M) end, Moves),
    %% Add moves TO each node.
    dict:fold(fun (_, M, D) ->
                      lists:foldl(
                        fun ({_, _, [N|_]}, E) ->
                                dict:update_counter(N, 1, E)
                        end, D, M)
              end, FromCount, Moves).


%% @private
%% @doc Convert a map, which is normally a list, into an array so that
%% we can randomly access the replication chains.
-spec map_to_array(map()) ->
                          array().
map_to_array(Map) ->
    array:fix(array:from_list(Map)).


%% @private
%% @doc {Src, Dst} pairs from a chain with unmapped nodes filtered out.
pairs(Chain) ->
    [Pair || {Src, Dst} = Pair <- misc:pairs(Chain), Src /= undefined,
             Dst /= undefined].


%% @private
%% @doc Report progress using the supplied progress callback.
-spec report_progress(#state{}) -> any().
report_progress(#state{initial_counts=Counts, moves=Moves,
                       progress_callback=Callback}) ->
    Remaining = count_moves(Moves),
    Progress = dict:map(fun (Node, R) ->
                                Total = dict:fetch(Node, Counts),
                                1.0 - R / Total
                        end, Remaining),
    Callback(Progress).


%% @private
%% @doc Spawn workers up to the per-node maximum.
-spec spawn_workers(#state{}) -> {noreply, #state{}} | {stop, normal, #state{}}.
spawn_workers(#state{bucket=Bucket, moves=Moves, movers=Movers,
                     max_per_node=MaxPerNode} = State) ->
    report_progress(State),
    {Movers1, Remaining} =
        dict:fold(
          fun (Node, RemainingMoves, {M, R}) ->
                  NumWorkers = dict:fetch(Node, Movers),
                  if NumWorkers < MaxPerNode ->
                          NewMovers = lists:sublist(RemainingMoves,
                                                    MaxPerNode - NumWorkers),
                          lists:foreach(
                            fun ({V, OldChain, NewChain}) ->
                                    update_replication_pre_move(
                                      V, OldChain, NewChain),
                                    ns_single_vbucket_mover:spawn_mover(Node,
                                                                        Bucket,
                                                                        V,
                                                                        OldChain,
                                                                        NewChain)
                            end, NewMovers),
                          M1 = dict:store(Node, length(NewMovers) + NumWorkers,
                                          M),
                          R1 = dict:store(Node, lists:nthtail(length(NewMovers),
                                                              RemainingMoves), R),
                          {M1, R1};
                     true ->
                          {M, R}
                  end
          end, {Movers, Moves}, Moves),
    State1 = State#state{movers=Movers1, moves=Remaining},
    Values = dict:fold(fun (_, V, L) -> [V|L] end, [], Movers1),
    case Values /= [] andalso lists:any(fun (V) -> V /= 0 end, Values) of
        true ->
            {noreply, State1};
        false ->
            {stop, normal, State1}
    end.


%% @private
%% @doc Perform pre-move replication fixup.
update_replication_pre_move(VBucket, OldChain, NewChain) ->
    [NewMaster|_] = NewChain,
    OldPairs = pairs(OldChain),
    NewPairs = pairs(NewChain),
    %% Stop replication to the new master
    case lists:keyfind(NewMaster, 2, OldPairs) of
        {SrcNode, _} ->
            kill_replica(SrcNode, NewMaster, VBucket),
            sync_replicas();
        false ->
            ok
    end,
    %% Start replication to any new replicas that aren't already being
    %% replicated to
    lists:foreach(
      fun ({SrcNode, DstNode}) ->
              case lists:member(DstNode, OldChain) of
                  false ->
                      %% Not the old master or already being replicated to
                      add_replica(SrcNode, DstNode, VBucket);
                  true ->
                      %% Already being replicated to; swing it over after
                      ok
              end
      end, NewPairs -- OldPairs).


%% @private
%% @doc Perform post-move replication fixup.
update_replication_post_move(VBucket, OldChain, NewChain) ->
    OldPairs = pairs(OldChain),
    NewPairs = pairs(NewChain),
    %% Stop replication for any old pair that isn't needed any more.
    lists:foreach(
      fun ({SrcNode, DstNode}) when SrcNode =/= undefined ->
              kill_replica(SrcNode, DstNode, VBucket)
      end, OldPairs -- NewPairs),
    %% Start replication for any new pair that wouldn't have already
    %% been started.
    lists:foreach(
      fun ({SrcNode, DstNode}) ->
              case lists:member(DstNode, OldChain) of
                  false ->
                      %% Would have already been started
                      ok;
                  true ->
                      %% Old one was stopped by the previous loop
                      add_replica(SrcNode, DstNode, VBucket)
              end
      end, NewPairs -- OldPairs),
    %% TODO: wait for backfill to complete and remove obsolete
    %% copies before continuing. Otherwise rebalance could use a lot
    %% of space.
    ok.

assert_master_mover() ->
    true = erlang:get('i_am_master_mover'),
    BucketName = erlang:get('bucket_name'),
    true = (BucketName =/= undefined),
    BucketName.

batch_replicas_change(Tuple) ->
    assert_master_mover(),
    Old = erlang:get('replicas_changes'),
    true = (undefined =/= Old),
    New = [Tuple | Old],
    erlang:put(replicas_changes, New).

kill_replica(SrcNode, DstNode, VBucket) ->
    assert_master_mover(),
    batch_replicas_change({kill_replica, SrcNode, DstNode, VBucket}).

add_replica(SrcNode, DstNode, VBucket) ->
    assert_master_mover(),
    batch_replicas_change({add_replica, SrcNode, DstNode, VBucket}).

inc_counter(Name, By) ->
    Old = erlang:get(Name),
    true = (undefined =/= Old),
    erlang:put(Name, Old + By).

sync_replicas() ->
    BucketName = assert_master_mover(),
    case erlang:put(replicas_changes, []) of
        undefined -> ok;
        [] -> ok;
        Changes ->
            ActualCount = ns_vbm_sup:apply_changes(BucketName, lists:reverse(Changes)),
            inc_counter(total_changes, length(Changes)),
            inc_counter(actual_changes, ActualCount)
    end.
