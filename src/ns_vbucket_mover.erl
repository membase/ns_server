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
-export([start_link/4]).

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
    erlang:put(child_processes, []),

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
    ?rebalance_info("The following moves are planned:~n~p", [dict:to_list(MoveDict)]),
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


handle_call(_, _From, _State) ->
    exit(not_supported).


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
    RepSyncRV = (catch begin
                           ns_config:sync_announcements(),
                           ns_config_rep:synchronize()
                       end),
    case RepSyncRV of
        ok -> ok;
        _ ->
            ?log_error("Config replication sync failed: ~p", [RepSyncRV])
    end,
    sync_replicas(),
    OldCopies = OldChain -- NewChain,
    DeleteRVs = misc:parallel_map(
                  fun (CopyNode) ->
                          {CopyNode, (catch ns_memcached:delete_vbucket(CopyNode, Bucket, VBucket))}
                  end, OldCopies, infinity),
    BadDeletes = [P || {_, RV} = P <- DeleteRVs, RV =/= ok],
    case BadDeletes of
        [] -> ok;
        _ ->
            ?log_error("Deleting some old copies of vbucket failed: ~p", [BadDeletes])
    end,
    spawn_workers(State#state{movers=Movers1, map=Map1});
handle_info({'EXIT', _, normal}, State) ->
    {noreply, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    ?rebalance_error("~p exited with ~p", [Pid, Reason]),
    {stop, Reason, State};
handle_info(Info, State) ->
    ?rebalance_warning("Unhandled message ~p", [Info]),
    {noreply, State}.


terminate(Reason, _State) ->
    sync_replicas(),
    TotalChanges = erlang:get(total_changes),
    ActualChanges = erlang:get(actual_changes),
    ?rebalance_debug("Savings: ~p (from ~p)~n",
                     [TotalChanges - ActualChanges, TotalChanges]),

    AllChildsEver = erlang:get(child_processes),
    [(catch erlang:exit(P, Reason)) || P <- AllChildsEver],
    [misc:wait_for_process(P, infinity) || P <- AllChildsEver],
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
                                    Pid = ns_single_vbucket_mover:spawn_mover(Node,
                                                                              Bucket,
                                                                              V,
                                                                              OldChain,
                                                                              NewChain),
                                    register_child_process(Pid)
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
    %% vbucket mover will take care of new replicas, so just stop
    %% replication for them
    PairsToStop = [T || {S, D} = T <- pairs(OldChain),
                        true = if S =:= undefined -> D =:= undefined;
                                  true -> true
                               end,
                        S =/= undefined,
                        D =/= undefined,
                        lists:member(D, NewChain)],
    %% we kind of create holes in old replication chain, but note that
    %% if some destination replication is stopped, it means we'll soon
    %% replicate to it in single vbucket mover, so chain is not really
    %% broken.
    [kill_replica(S, D, VBucket) || {S, D} <- PairsToStop],
    sync_replicas().


%% @private
%% @doc Perform post-move replication fixup.
update_replication_post_move(VBucket, OldChain, NewChain) ->
    %% destroy remainings of old replication chain
    [kill_replica(S, D, VBucket) || {S, D} <- pairs(OldChain),
                                    S =/= undefined,
                                    D =/= undefined,
                                    not lists:member(D, NewChain)],
    %% just start new chain of replications. Old chain is dead now
    [add_replica(S, D, VBucket) || {S, D} <- pairs(NewChain),
                                   true = if S =:= undefined -> D =:= undefined;
                                             true -> true
                                          end,
                                   S =/= undefined,
                                   D =/= undefined],
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
            ActualCount = cb_replication:apply_changes(BucketName,
                                                       lists:reverse(Changes)),
            inc_counter(total_changes, length(Changes)),
            inc_counter(actual_changes, ActualCount)
    end.

register_child_process(Pid) ->
    List = erlang:get(child_processes),
    true = is_list(List),
    erlang:put(child_processes, [Pid | List]).
