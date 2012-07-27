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

-define(MAX_MOVES_PER_NODE, ns_config_ets_dup:unreliable_read_key(rebalance_moves_per_node, 1)).

%% API
-export([start_link/4, run_code/2]).

%% gen_server callbacks
-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-type progress_callback() :: fun((dict()) -> any()).

-record(state, {bucket::nonempty_string(),
                disco_events_subscription::pid(),
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

run_code(MainMoverPid, Fun) ->
    true = (node() =:= node(MainMoverPid)),
    case MainMoverPid =:= self() of
        true ->
            Fun();
        false ->
            %% You might be wondering why this trickery is employed
            %% here. The reason is this code is called by childs of
            %% main mover, which may send them shutdown request. Thus
            %% simple direct gen_server:call would cause deadlock. And
            %% in fact it was easily happening in initial version of
            %% this code.
            DoneRef = erlang:make_ref(),
            {_, MRef} = erlang:spawn_monitor(
                          fun () ->
                                  RV = gen_server:call(MainMoverPid, {run_code, Fun}, infinity),
                                  exit({DoneRef, RV})
                          end),
            receive
                {'EXIT', MainMoverPid, Reason} ->
                    ?log_debug("Got parent exit:~p", [Reason]),
                    erlang:demonitor(MRef, [flush]),
                    exit(Reason);
                {'DOWN', MRef, _, _, Reason} ->
                    case Reason of
                        {DoneRef, RV} ->
                            RV;
                        _ ->
                            ?log_debug("Worker process crashed: ~p", [Reason]),
                            error({run_code_worker_crashed, Reason})
                    end
            end
    end.

%%
%% gen_server callbacks
%%

code_change(_OldVsn, _Extra, State) ->
    {ok, State}.

init({Bucket, OldMap, NewMap, ProgressCallback}) ->
    erlang:put(i_am_master_mover, true),
    erlang:put(bucket_name, Bucket),
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
    Self = self(),
    Subscription = ns_pubsub:subscribe_link(ns_node_disco_events,
                                            fun ({ns_node_disco_events, _, _} = Event) ->
                                                    Self ! Event;
                                                (_) ->
                                                    ok
                                            end),
    erlang:start_timer(30000, self(), log_tap_stats),

    AllNodesSet0 =
        lists:foldl(fun (Chain, Acc) ->
                            sets:union(Acc, sets:from_list(Chain))
                    end, sets:new(), OldMap ++ NewMap),
    AllNodesSet = sets:del_element(undefined, AllNodesSet0),
    ok = janitor_agent:prepare_nodes_for_rebalance(Bucket, sets:to_list(AllNodesSet), self()),

    {ok, #state{bucket=Bucket,
                disco_events_subscription=Subscription,
                initial_counts=count_moves(MoveDict),
                max_per_node=?MAX_MOVES_PER_NODE,
                map = map_to_array(OldMap),
                moves=MoveDict, movers=Movers,
                progress_callback=ProgressCallback}}.


handle_call({run_code, Fun}, _From, State) ->
    {reply, Fun(), State};
handle_call(_, _From, _State) ->
    exit(not_supported).


handle_cast(unhandled, unhandled) ->
    unhandled.


%% We intentionally don't handle other exits so we'll die if one of
%% the movers fails.
handle_info({timeout, _, log_tap_stats}, State) ->
    rpc:eval_everywhere(diag_handler, log_all_tap_and_checkpoint_stats, []),
    misc:flush(log_tap_stats),
    {noreply, State};
handle_info(spawn_initial, State) ->
    spawn_workers(State);
handle_info({move_done, {Node, VBucket, OldChain, NewChain}},
            #state{movers=Movers,
                   map=Map,
                   bucket=Bucket} = State) ->
    master_activity_events:note_move_done(Bucket, VBucket),
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
                           ns_config_rep:synchronize_remote()
                       end),
    case RepSyncRV of
        ok -> ok;
        _ ->
            ?log_error("Config replication sync failed: ~p", [RepSyncRV])
    end,
    OldCopies0 = OldChain -- NewChain,
    OldCopies = [OldCopyNode || OldCopyNode <- OldCopies0,
                                OldCopyNode =/= undefined],
    ?rebalance_info("Moving vbucket ~p done. Will delete it on: ~p", [VBucket, OldCopies]),
    case janitor_agent:delete_vbucket_copies(Bucket, self(), OldCopies, VBucket) of
        ok ->
            ok;
        {errors, BadDeletes} ->
            ?log_error("Deleting some old copies of vbucket failed: ~p", [BadDeletes])
    end,

    spawn_workers(State#state{movers=Movers1, map=Map1});
handle_info({ns_node_disco_events, _, _} = Event, State) ->
    {stop, {detected_nodes_change, Event}, State};
handle_info({'EXIT', Pid, _} = Msg, #state{disco_events_subscription=Pid}=State) ->
    ?rebalance_error("Got exit from node disco events subscription"),
    {stop, {ns_node_disco_events_exited, Msg}, State};
handle_info({'EXIT', _, normal}, State) ->
    {noreply, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    ?rebalance_error("~p exited with ~p", [Pid, Reason]),
    {stop, Reason, State};
handle_info(Info, State) ->
    ?rebalance_warning("Unhandled message ~p", [Info]),
    {noreply, State}.


terminate(Reason, _State) ->
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
%% @doc Perform post-move replication fixup.
update_replication_post_move(VBucket, OldChain, NewChain) ->
    BucketName = assert_master_mover(),
    ChangeReplica = fun (Dst, Src) ->
                            {Dst, replica, undefined, Src}
                    end,
    %% destroy remnants of old replication chain
    AddChanges = [ChangeReplica(D, undefined)
                  || {S, D} <- pairs(OldChain),
                     S =/= undefined,
                     D =/= undefined,
                     not lists:member(D, NewChain)],
    %% just start new chain of replications. Old chain is dead now
    DelChanges = [ChangeReplica(D, S)
                  || {S, D} <- pairs(NewChain),
                     true = if S =:= undefined -> D =:= undefined;
                               true -> true
                            end,
                     S =/= undefined,
                     D =/= undefined],
    ok = janitor_agent:bulk_set_vbucket_state(BucketName, self(), VBucket, AddChanges ++ DelChanges).

assert_master_mover() ->
    true = erlang:get('i_am_master_mover'),
    BucketName = erlang:get('bucket_name'),
    true = (BucketName =/= undefined),
    BucketName.

register_child_process(Pid) ->
    List = erlang:get(child_processes),
    true = is_list(List),
    erlang:put(child_processes, [Pid | List]).
