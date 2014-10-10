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
-module(ns_heart).

-behaviour(gen_server).

-include("ns_stats.hrl").
-include("ns_common.hrl").
-include("ns_heart.hrl").

-export([start_link/0, start_link_slow_updater/0, status_all/0,
         force_beat/0, grab_fresh_failover_safeness_infos/1,
         effective_cluster_compat_version/0,
         effective_cluster_compat_version_for/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% for hibernate
-export([slow_updater_loop/0]).

-record(state, {
          forced_beat_timer :: reference() | undefined,
          event_handler :: pid(),
          slow_status = [] :: term(),
          slow_status_ts = {0, 0, 0} :: erlang:timestamp()
         }).


%% gen_server handlers

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_link_slow_updater() ->
    proc_lib:start_link(
      erlang, apply,
      [fun () ->
               erlang:register(ns_heart_slow_status_updater, self()),
               proc_lib:init_ack({ok, self()}),
               slow_updater_loop()
       end, []]).

is_interesting_buckets_event({started, _}) -> true;
is_interesting_buckets_event({loaded, _}) -> true;
is_interesting_buckets_event({stopped, _, _, _}) -> true;
is_interesting_buckets_event(_Event) -> false.

init([]) ->
    process_flag(trap_exit, true),

    timer2:send_interval(?HEART_BEAT_PERIOD, beat),
    self() ! beat,
    Self = self(),
    EventHandler =
        ns_pubsub:subscribe_link(
          buckets_events,
          fun (Event, _) ->
                  case is_interesting_buckets_event(Event) of
                      true ->
                          Self ! force_beat;
                      _ -> ok
                  end
          end, []),

    {ok, #state{event_handler=EventHandler}}.

force_beat() ->
    ?MODULE ! force_beat.

arm_forced_beat_timer(#state{forced_beat_timer = TRef} = State) when TRef =/= undefined ->
    State;
arm_forced_beat_timer(State) ->
    TRef = erlang:send_after(200, self(), beat),
    State#state{forced_beat_timer = TRef}.

disarm_forced_beat_timer(#state{forced_beat_timer = undefined} = State) ->
    State;
disarm_forced_beat_timer(#state{forced_beat_timer = TRef} = State) ->
    erlang:cancel_timer(TRef),
    State#state{forced_beat_timer = undefined}.


handle_call(status, _From, State) ->
    {Status, NewState} = update_current_status(State),
    {reply, Status, NewState};
handle_call(Request, _From, State) ->
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'EXIT', EventHandler, _} = ExitMsg,
            #state{event_handler=EventHandler} = State) ->
    ?log_debug("Dying because our event subscription was cancelled~n~p~n",
               [ExitMsg]),
    {stop, normal, State};
handle_info({slow_update, NewStatus, ReqTS}, State) ->
    {noreply, State#state{slow_status = NewStatus, slow_status_ts = ReqTS}};
handle_info(beat, State) ->
    NewState = disarm_forced_beat_timer(State),
    Dropped = misc:flush(beat),
    case Dropped of
        0 ->
            ok;
        _ ->
            ?log_warning("Dropped ~p hearbeats", [Dropped])
    end,
    {Status, NewState2} = update_current_status(NewState),
    heartbeat(Status),
    {noreply, NewState2};
handle_info(force_beat, State) ->
    {noreply, arm_forced_beat_timer(State)};
handle_info(_, State) ->
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API
heartbeat(Status) ->
    catch misc:parallel_map(
            fun (N) ->
                    gen_server:cast({ns_doctor, N}, {heartbeat, node(), Status})
            end, [node() | nodes()], ?HEART_BEAT_PERIOD - 1000).

status_all() ->
    {Replies, _} = gen_server:multi_call([node() | nodes()], ?MODULE, status, 5000),
    Replies.

erlang_stats() ->
    try
        Stats = [wall_clock, context_switches, garbage_collection, io, reductions,
                 run_queue, runtime, run_queues],
        [{Stat, statistics(Stat)} || Stat <- Stats]
    catch _:_ ->
            %% NOTE: dialyzer doesn't like run_queues stat
            %% above. Given that this is useful but not a must, it
            %% makes sense to simply cover any exception
            []
    end.

%% Internal fuctions

is_interesting_stat({curr_items, _}) -> true;
is_interesting_stat({curr_items_tot, _}) -> true;
is_interesting_stat({vb_replica_curr_items, _}) -> true;
is_interesting_stat({mem_used, _}) -> true;
is_interesting_stat({couch_docs_actual_disk_size, _}) -> true;
is_interesting_stat({couch_views_actual_disk_size, _}) -> true;
is_interesting_stat({couch_docs_data_size, _}) -> true;
is_interesting_stat({couch_views_data_size, _}) -> true;
is_interesting_stat({cmd_get, _}) -> true;
is_interesting_stat({get_hits, _}) -> true;
is_interesting_stat({ep_bg_fetched, _}) -> true;
is_interesting_stat({ops, _}) -> true;
is_interesting_stat(_) -> false.


eat_earlier_slow_updates(TS) ->
    receive
        {slow_update, _, ResTS} when ResTS < TS ->
            eat_earlier_slow_updates(TS)
    after 0 ->
            ok
    end.

update_current_status(#state{slow_status = []} = State) ->
    %% we don't have slow status at all; so compute it synchronously
    TS = erlang:now(),
    QuickStatus = current_status_quick(TS),
    SlowStatus = current_status_slow(TS),
    NewState = State#state{slow_status = SlowStatus,
                           slow_status_ts = TS},
    {QuickStatus ++ SlowStatus, NewState};
update_current_status(State) ->
    TS = erlang:now(),
    ns_heart_slow_status_updater ! {req, TS, self()},
    QuickStatus = current_status_quick(TS),

    receive
        %% NOTE: TS is bound already
        {slow_update, _, TS} = Msg ->
            eat_earlier_slow_updates(TS),
            {noreply, NewState} = handle_info(Msg, State),
            update_current_status_tail(NewState, QuickStatus)
    after ?HEART_BEAT_PERIOD ->
            update_current_status_no_reply(State, QuickStatus)
    end.

update_current_status_no_reply(State, QuickStatus) ->
    receive
        %% if we haven't see our reply yet, refresh status at
        %% least as much as there are replies seen
        {slow_update, _, _} = Msg ->
            {noreply, NewState} = handle_info(Msg, State),
            update_current_status_no_reply(NewState, QuickStatus)
    after 0 ->
            QuickStatus2 = [{stale_slow_status, State#state.slow_status_ts} | QuickStatus],
            update_current_status_tail(State, QuickStatus2)
    end.

update_current_status_tail(State, QuickStatus) ->
    Status = QuickStatus ++ State#state.slow_status,
    {Status, State}.

current_status_quick(TS) ->
    [{now, TS},
     {active_buckets, ns_memcached:active_buckets()},
     {ready_buckets, ns_memcached:warmed_buckets()}].

eat_all_reqs(TS, Count) ->
    receive
        {req, AnotherTS} ->
            true = (AnotherTS > TS),
            eat_all_reqs(AnotherTS, Count + 1)
    after 0 ->
            {TS, Count}
    end.

slow_updater_loop() ->
    receive
        {req, TS0, From} ->
            {TS, Eaten} = eat_all_reqs(TS0, 0),
            case Eaten > 0 of
                true -> ?log_warning("Dropped ~B heartbeat requests", [Eaten]);
                _ -> ok
            end,
            Status = current_status_slow(TS),
            From ! {slow_update, Status, TS},
            erlang:hibernate(?MODULE, slow_updater_loop, [])
    end.

current_status_slow(TS) ->
    Status0 = current_status_slow_inner(),
    Diff = timer:now_diff(erlang:now(), TS),
    system_stats_collector:add_histo(status_latency, Diff),
    [{status_latency, Diff} | Status0].

current_status_slow_inner() ->
    SystemStats =
        case catch stats_reader:latest("minute", node(), "@system") of
            {ok, StatsRec} -> StatsRec#stat_entry.values;
            CrapSys ->
                ?log_debug("Ignoring failure to grab system stats:~n~p~n", [CrapSys]),
                []
        end,

    BucketNames = ns_bucket:node_bucket_names(node()),

    PerBucketInterestingStats =
        lists:foldl(fun (BucketName, Acc) ->
                            case catch stats_reader:latest(minute, node(), BucketName) of
                                {ok, #stat_entry{values = Values}} ->
                                    InterestingValues = lists:filter(fun is_interesting_stat/1, Values),
                                    [{BucketName, InterestingValues} | Acc];
                                Crap ->
                                    ?log_debug("Ignoring failure to get stats for bucket: ~p:~n~p~n", [BucketName, Crap]),
                                    Acc
                            end
                    end, [], BucketNames),

    InterestingStats =
        lists:foldl(fun ({BucketName, InterestingValues}, Acc) ->
                            orddict:merge(fun (K, V1, V2) ->
                                                  try
                                                      V1 + V2
                                                  catch error:badarith ->
                                                          ?log_debug("Ignoring badarith when agregating interesting stats:~n~p~n",
                                                                     [{BucketName, K, V1, V2}]),
                                                          V1
                                                  end
                                          end, Acc, InterestingValues)
                    end, [], PerBucketInterestingStats),

    Tasks = lists:filter(
        fun (Task) ->
                is_view_task(Task) orelse is_bucket_compaction_task(Task)
        end, couch_task_status:all() ++ local_tasks:all())
        ++ grab_local_xdcr_replications()
        ++ grab_samples_loading_tasks()
        ++ grab_warmup_tasks()
        ++ cluster_logs_collection_task:maybe_build_cluster_logs_task(),

    MaybeMeminfo =
        case misc:raw_read_file("/proc/meminfo") of
            {ok, Contents} ->
                [{meminfo, Contents}];
            _ -> []
        end,

    ClusterCompatVersion = effective_cluster_compat_version(),

    StorageConf0 = cb_config_couch_sync:get_db_and_ix_paths(),
    StorageConf =
        lists:map(
          fun ({Key, Path}) ->
                  %% db_path and index_path are guaranteed to be absolute
                  {ok, RealPath} = misc:realpath(Path, "/"),
                  {Key, RealPath}
          end, StorageConf0),

    ProcessesStats =
        lists:filter(
          fun ({<<"proc/", _/binary>>, _}) ->
                  true;
              (_) ->
                  false
          end, SystemStats),

    failover_safeness_level:build_local_safeness_info(BucketNames) ++
        [{local_tasks, Tasks},
         {memory, misc:memory()},
         {system_memory_data, memsup:get_system_memory_data()},
         {node_storage_conf, StorageConf},
         {statistics, erlang_stats()},
         {system_stats, [{N, proplists:get_value(N, SystemStats, 0)}
                         || N <- [cpu_utilization_rate, swap_total, swap_used,
                                  mem_total, mem_free]]},
         {interesting_stats, InterestingStats},
         {per_bucket_interesting_stats, PerBucketInterestingStats},
         {processes_stats, ProcessesStats},
         {cluster_compatibility_version, ClusterCompatVersion}
         | element(2, ns_info:basic_info())] ++ MaybeMeminfo.

%% undefined is "used" shortly after node is initialized and when
%% there's no compat mode yet
effective_cluster_compat_version_for(undefined) ->
    1;
effective_cluster_compat_version_for([VersionMaj, VersionMin] = _CompatVersion) ->
    VersionMaj * 16#10000 + VersionMin.

effective_cluster_compat_version() ->
    effective_cluster_compat_version_for(cluster_compat_mode:get_compat_version()).


%% returns dict as if returned by ns_doctor:get_nodes/0 but containing only
%% failover safeness fields (or down bool property). Instead of going
%% to doctor it actually contacts all nodes and tries to grab fresh
%% information. See failover_safeness_level:build_local_safeness_info
grab_fresh_failover_safeness_infos(BucketsAll) ->
    do_grab_fresh_failover_safeness_infos(BucketsAll, 2000).

do_grab_fresh_failover_safeness_infos(BucketsAll, Timeout) ->
    Nodes = ns_node_disco:nodes_actual_proper(),
    BucketNames = proplists:get_keys(BucketsAll),
    {NodeResp, NewErrors} =
        misc:multicall_result_to_plist(
          Nodes,
          rpc:multicall(Nodes,
                        failover_safeness_level, build_local_safeness_info,
                        [BucketNames], Timeout)),

    case NewErrors of
        [] -> ok;
        _ ->
            ?log_warning("Some nodes didn't return their failover "
                         "safeness infos: ~n~p", [NewErrors])
    end,

    dict:from_list(NodeResp).

is_view_task(Task) ->
    lists:keyfind(set, 1, Task) =/= false andalso
        begin
            {type, Type} = lists:keyfind(type, 1, Task),
            Type =:= indexer orelse
                Type =:= view_compaction
        end.

is_bucket_compaction_task(Task) ->
    {type, Type} = lists:keyfind(type, 1, Task),
    Type =:= bucket_compaction.

-define(STALE_XDCR_ERROR_SECONDS, ns_config:get_timeout_fast(xdcr_stale_error_seconds, 7200)).

%% NOTE: also removes datetime component
-spec filter_out_stale_xdcr_errors([{erlang:timestamp(), binary()}], integer()) -> [binary()].
filter_out_stale_xdcr_errors(Errors, NowGregorian) ->
    [Msg
     || {DateTime, Msg} <- Errors,
        NowGregorian - calendar:datetime_to_gregorian_seconds(DateTime) < ?STALE_XDCR_ERROR_SECONDS].

convert_non_ascii_chars(Msg) ->
    do_convert_non_ascii_chars(Msg, <<"">>).

do_convert_non_ascii_chars(<<"">>, Acc) ->
    Acc;
do_convert_non_ascii_chars(<<C, Rest/binary>>, Acc) ->
    C1 = C band 16#7f,
    do_convert_non_ascii_chars(Rest, <<Acc/binary, C1>>).

grab_local_xdcr_replications() ->
    NowGregorian = calendar:datetime_to_gregorian_seconds(erlang:localtime()),
    try xdc_replication_sup:all_local_replication_infos() of
        Infos ->
            [begin
                 RecentErrors = filter_out_stale_xdcr_errors(LastErrors, NowGregorian),

                 %% When mochijson encodes strings, it expects them to be already utf8-encoded.
                 %% And if it's not true, it fails with some bad_utf8_character_code error.
                 %% In some cases errors that we get from xdc_replictaion_sup might contain
                 %% non-ASCII characters that are not properly encoded. For example if
                 %% it's just a pretty-printed stacktrace referring to some document body.
                 %% We'll just keep 7 least signi significant bits of every character to make it
                 %% look like proper ASCII. We don't really care that we'll get some garbage
                 %% because the messages are already very far from being human-readable.
                 AsciiErrors = lists:map(fun convert_non_ascii_chars/1, RecentErrors),

                 [{type, xdcr},
                  {id, Id},
                  {errors, AsciiErrors}
                  | Props]
             end || {Id, Props, LastErrors} <- Infos]
    catch T:E ->
            ?log_debug("Ignoring exception getting xdcr replication infos~n~p", [{T,E,erlang:get_stacktrace()}]),
            []
    end.

grab_samples_loading_tasks() ->
    try samples_loader_tasks:get_tasks(2000) of
        RawTasks ->
            [[{type, loadingSampleBucket},
              {bucket, list_to_binary(Name)},
              {pid, list_to_binary(pid_to_list(Pid))}]
             || {Name, Pid} <- RawTasks]
    catch T:E ->
            ?log_error("Failed to grab samples loader tasks: ~p", [{T,E,erlang:get_stacktrace()}]),
            []
    end.

grab_warmup_task(Bucket) ->
    Stats = try ns_memcached:warmup_stats(Bucket)
            catch exit:{noproc, _} ->
                    % it is possible that heartbeat happens before ns_memcached is started
                    [{<<"ep_warmup_state">>,
                      <<"starting ep-engine">>}]
            end,

    case Stats of
        [] ->
            [];
        _ ->
            [[{type, warming_up},
              {bucket, list_to_binary(Bucket)},
              {node, node()},
              {recommendedRefreshPeriod, 2.0},
              {stats, {struct, Stats}}]]
    end.

grab_warmup_tasks() ->
    BucketNames = ns_bucket:node_bucket_names(node()),
    lists:foldl(fun (Bucket, Acc) ->
                        Acc ++ grab_warmup_task(Bucket)
                end, [], BucketNames).
