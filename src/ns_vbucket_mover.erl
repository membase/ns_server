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
-define(MOVES_BEFORE_COMPACTION, ns_config_ets_dup:unreliable_read_key(rebalance_moves_before_compaction, 64)).

-define(TAP_STATS_LOGGING_INTERVAL, 10*60*1000).

%% API
-export([start_link/4]).

%% gen_server callbacks
-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-type progress_callback() :: fun((dict()) -> any()).

-record(state, {bucket::nonempty_string(),
                disco_events_subscription::pid(),
                map::array(),
                moves_scheduler_state,
                progress_callback::progress_callback(),
                all_nodes_set::set()}).

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

assert_dict_mapping(Dict, E1, E2) ->
    case dict:find(E1, Dict) of
        error ->
            dict:store(E1, E2, Dict);
        {ok, E2} -> % note: E2 is bound
            Dict;
        {ok, _SomethingElse} ->
            false
    end.

is_swap_rebalance(MapTriples, OldMap, NewMap) ->
    OldNodes = lists:usort(lists:append(OldMap)) -- [undefined],
    NewNodes = lists:usort(lists:append(NewMap)) -- [undefined],
    AddedNodes = ordsets:subtract(NewNodes, OldNodes),
    RemovedNodes = ordsets:subtract(OldNodes, NewNodes),

    try
        lists:foldl(
          fun ({_VB, OldChain, NewChain}, Dict0) ->
                  Changed = [Pair || {From, To} = Pair <- lists:zip(OldChain, NewChain),
                                     From =/= To,
                                     From =/= undefined,
                                     To =/= undefined],
                  lists:foldl(
                    fun ({From, To}, Dict) ->
                            ordsets:is_element(From, RemovedNodes) orelse erlang:throw(not_swap),
                            ordsets:is_element(To, AddedNodes) orelse erlang:throw(not_swap),
                            Dict2 = assert_dict_mapping(Dict, From, To),
                            Dict2 =/= false orelse erlang:throw(not_swap),
                            Dict3 = assert_dict_mapping(Dict2, To, From),
                            Dict3 =/= false orelse erlang:throw(not_swap),
                            Dict3
                    end, Dict0, Changed)
          end, dict:new(), MapTriples),
        true
    catch throw:not_swap ->
            false
    end.

init({Bucket, OldMap, NewMap, ProgressCallback}) ->
    erlang:put(i_am_master_mover, true),
    erlang:put(bucket_name, Bucket),
    erlang:put(child_processes, []),

    MapTriples = lists:zip3(lists:seq(0, length(OldMap) - 1),
                            OldMap,
                            NewMap),
    AllNodesSet0 =
        lists:foldl(fun (Chain, Acc) ->
                            sets:union(Acc, sets:from_list(Chain))
                    end, sets:new(), OldMap ++ NewMap),
    case is_swap_rebalance(MapTriples, OldMap, NewMap) of
        true ->
            ale:info(?USER_LOGGER, "Bucket ~p rebalance appears to be swap rebalance", [Bucket]);
        false ->
            ale:info(?USER_LOGGER, "Bucket ~p rebalance does not seem to be swap rebalance", [Bucket])
    end,
    self() ! spawn_initial,
    process_flag(trap_exit, true),
    Self = self(),
    Subscription = ns_pubsub:subscribe_link(ns_node_disco_events,
                                            fun ({ns_node_disco_events, _, _} = Event) ->
                                                    Self ! Event;
                                                (_) ->
                                                    ok
                                            end),

    timer2:send_interval(?TAP_STATS_LOGGING_INTERVAL, log_tap_stats),

    AllNodesSet = sets:del_element(undefined, AllNodesSet0),
    ok = janitor_agent:prepare_nodes_for_rebalance(Bucket, sets:to_list(AllNodesSet), self()),

    ets:new(compaction_inhibitions, [named_table, private, set]),

    {ok, #state{bucket=Bucket,
                disco_events_subscription=Subscription,
                map = map_to_array(OldMap),
                moves_scheduler_state = vbucket_move_scheduler:prepare(OldMap, NewMap,
                                                                       ?MAX_MOVES_PER_NODE, ?MOVES_BEFORE_COMPACTION,
                                                                       fun (Msg, Args) -> ?log_debug(Msg, Args) end),
                progress_callback=ProgressCallback,
                all_nodes_set=AllNodesSet}}.


handle_call(_, _From, _State) ->
    exit(not_supported).


handle_cast(unhandled, unhandled) ->
    exit(unhandled).


handle_info(log_tap_stats, State) ->
    rpc:eval_everywhere(diag_handler, log_all_tap_and_checkpoint_stats, []),
    misc:flush(log_tap_stats),
    {noreply, State};
handle_info(spawn_initial, State) ->
    report_progress(State),
    spawn_workers(State);
handle_info({inhibited_view_compaction, N, MRef}, State) ->
    true = ets:insert_new(compaction_inhibitions, {N, MRef}),
    {noreply, State};
handle_info({compaction_done, N}, #state{moves_scheduler_state = SubState} = State) ->
    A = {compact, N},
    ?log_debug("noted compaction done: ~p", [A]),
    SubState2 = vbucket_move_scheduler:note_compaction_done(SubState, A),
    spawn_workers(State#state{moves_scheduler_state = SubState2});
handle_info({move_done, {_VBucket, _OldChain, _NewChain} = Tuple}, State) ->
    {noreply, State1} = on_backfill_done(Tuple, State),
    on_move_done(Tuple, State1);
handle_info({move_done_new_style, {_VBucket, _OldChain, _NewChain} = Tuple}, State) ->
    on_move_done(Tuple, State);
handle_info({backfill_done, {_VBucket, _OldChain, _NewChain} = Tuple}, State) ->
    on_backfill_done(Tuple, State);
handle_info({ns_node_disco_events, OldNodes, NewNodes} = Event,
            #state{all_nodes_set=AllNodesSet} = State) ->
    WentDownNodes = sets:from_list(ordsets:subtract(OldNodes, NewNodes)),

    case sets:is_disjoint(AllNodesSet, WentDownNodes) of
        true ->
            {noreply, State};
        false ->
            {stop, {important_nodes_went_down, Event}, State}
    end;
%% We intentionally don't handle other exits so we'll die if one of
%% the movers fails.
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
%% @doc Convert a map, which is normally a list, into an array so that
%% we can randomly access the replication chains.
-spec map_to_array(map()) ->
                          array().
map_to_array(Map) ->
    array:fix(array:from_list(Map)).


%% @private
%% @doc Report progress using the supplied progress callback.
-spec report_progress(#state{}) -> any().
report_progress(#state{moves_scheduler_state = SubState,
                       progress_callback = Callback}) ->
    Progress = vbucket_move_scheduler:extract_progress(SubState),
    Callback(Progress).

on_backfill_done({VBucket, OldChain, NewChain}, #state{moves_scheduler_state = SubState} = State) ->
    Move = {move, {VBucket, OldChain, NewChain}},
    NextState = State#state{moves_scheduler_state = vbucket_move_scheduler:note_backfill_done(SubState, Move)},
    ?log_debug("noted backfill done: ~p", [Move]),
    {noreply, _} = spawn_workers(NextState).

on_move_done({VBucket, OldChain, NewChain}, #state{bucket = Bucket,
                                                   map = Map,
                                                   moves_scheduler_state = SubState} = State) ->
    update_replication_post_move(VBucket, OldChain, NewChain),

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

    Move = {move, {VBucket, OldChain, NewChain}},
    NextState = State#state{moves_scheduler_state = vbucket_move_scheduler:note_move_completed(SubState, Move),
                            map = Map1},

    report_progress(NextState),

    master_activity_events:note_move_done(Bucket, VBucket),

    spawn_workers(NextState).

spawn_compaction_uninhibitor(Bucket, Node, MRef) ->
    Parent = self(),
    erlang:spawn_link(
      fun () ->
              case cluster_compat_mode:is_index_aware_rebalance_on() of
                  true ->
                      case compaction_daemon:uninhibit_view_compaction(Bucket, Node, MRef) of
                          ok ->
                              master_activity_events:note_compaction_uninhibited(Bucket, Node),
                              ok;
                          nack ->
                              erlang:exit({failed_to_initiate_compaction, Bucket, Node, MRef})
                      end;
                  _ ->
                      ok
              end,
              Parent ! {compaction_done, Node}
      end).

%% @doc Spawn workers up to the per-node maximum.
-spec spawn_workers(#state{}) -> {noreply, #state{}} | {stop, normal, #state{}}.
spawn_workers(#state{bucket=Bucket, moves_scheduler_state = SubState} = State) ->
    {Actions, NewSubState} = vbucket_move_scheduler:choose_action(SubState),
    ?log_debug("Got actions: ~p", [Actions]),
    [case A of
         {move, {V, OldChain, NewChain}} ->
             Pid = ns_single_vbucket_mover:spawn_mover(Bucket,
                                                       V,
                                                       OldChain,
                                                       NewChain),
             register_child_process(Pid);
         {compact, N} ->
             case (cluster_compat_mode:is_index_aware_rebalance_on()
                   andalso not cluster_compat_mode:rebalance_ignore_view_compactions()) of
                 true ->
                     case ets:lookup(compaction_inhibitions, N) of
                         [] ->
                             self() ! {compaction_done, N};
                         [{N, MRef}] ->
                             ets:delete(compaction_inhibitions, N),
                             Pid = spawn_compaction_uninhibitor(Bucket, N, MRef),
                             register_child_process(Pid)
                     end;
                 _ ->
                     self() ! {compaction_done, N}
             end
     end || A <- Actions],
    NextState = State#state{moves_scheduler_state = NewSubState},
    Done = Actions =:= [] andalso begin
                                      true = (NewSubState =:= SubState),
                                      vbucket_move_scheduler:is_done(NewSubState)
                                  end,
    case Done of
        true ->
            {stop, normal, NextState};
        _ ->
            {noreply, NextState}
    end.

%% @private
%% @doc {Src, Dst} pairs from a chain with unmapped nodes filtered out.
pairs(Chain) ->
    case cluster_compat_mode:get_replication_topology() of
        star ->
            pairs_star(Chain);
        chain ->
            pairs_chain(Chain)
    end.

pairs_chain(Chain) ->
    [Pair || {Src, Dst} = Pair <- misc:pairs(Chain), Src /= undefined,
             Dst /= undefined].

pairs_star([undefined | _]) ->
    [];
pairs_star([Master | Replicas]) ->
    [{Master, R} || R <- Replicas, R =/= undefined].

%% @private
%% @doc Perform post-move replication fixup.
update_replication_post_move(VBucket, OldChain, NewChain) ->
    BucketName = assert_master_mover(),
    ChangeReplica = fun (Dst, Src) ->
                            {Dst, replica, undefined, Src}
                    end,
    %% destroy remnants of old replication chain
    DelChanges = [ChangeReplica(D, undefined) || {_, D} <- pairs(OldChain),
                                                 not lists:member(D, NewChain)],
    %% just start new chain of replications. Old chain is dead now
    AddChanges = [ChangeReplica(D, S) || {S, D} <- pairs(NewChain)],
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
