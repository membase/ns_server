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

-export([start_link/0, status_all/0,
         force_beat/0, grab_fresh_failover_safeness_infos/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {
          forced_beat_timer :: reference() | undefined,
          event_handler :: pid()
         }).


%% gen_server handlers

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

is_interesting_buckets_event({started, _}) -> true;
is_interesting_buckets_event({loaded, _}) -> true;
is_interesting_buckets_event({stopped, _, _, _}) -> true;
is_interesting_buckets_event(_Event) -> false.

init([]) ->
    process_flag(trap_exit, true),

    timer:send_interval(?HEART_BEAT_PERIOD, beat),
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
    {reply, current_status(), State};
handle_call(Request, _From, State) ->
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'EXIT', EventHandler, _} = ExitMsg,
            #state{event_handler=EventHandler} = State) ->
    ?log_debug("Dying because our event subscription was cancelled~n~p~n",
               [ExitMsg]),
    {stop, normal, State};
handle_info(beat, State) ->
    NewState = disarm_forced_beat_timer(State),
    misc:flush(beat),
    heartbeat(current_status()),
    {noreply, NewState};
handle_info(force_beat, State) ->
    {noreply, arm_forced_beat_timer(State)};
handle_info(_, State) ->
    {noreply, State}.


terminate(_Reason, _State) -> ok.

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
    Stats = [wall_clock, context_switches, garbage_collection, io, reductions,
             run_queue, runtime],
    [{Stat, statistics(Stat)} || Stat <- Stats].

%% Internal fuctions

is_interesting_stat({curr_items, _}) -> true;
is_interesting_stat({curr_items_tot, _}) -> true;
is_interesting_stat({vb_replica_curr_items, _}) -> true;
is_interesting_stat({mem_used, _}) -> true;
is_interesting_stat({couch_docs_actual_disk_size, _}) -> true;
is_interesting_stat({couch_views_actual_disk_size, _}) -> true;
is_interesting_stat(_) -> false.

current_status() ->
    SystemStats =
        case catch stats_reader:latest("minute", node(), "@system") of
            {ok, StatsRec} -> StatsRec#stat_entry.values;
            CrapSys ->
                ?log_debug("Ignoring failure to grab system stats:~n~p~n", [CrapSys]),
                []
        end,

    BucketNames = ns_bucket:node_bucket_names(node()),

    InterestingStats =
        lists:foldl(fun (BucketName, Acc) ->
                            case catch stats_reader:latest(minute, node(), BucketName) of
                                {ok, #stat_entry{values = Values}} ->
                                    InterestingValues = lists:filter(fun is_interesting_stat/1, Values),
                                    orddict:merge(fun (K, V1, V2) ->
                                                          try
                                                              V1 + V2
                                                          catch error:badarith ->
                                                                  ?log_debug("Ignoring badarith when agregating interesting stats:~n~p~n",
                                                                             [{BucketName, K, V1, V2}]),
                                                                  V1
                                                          end
                                                  end, Acc, InterestingValues);
                                Crap ->
                                    ?log_debug("Ignoring failure to get stats for bucket: ~p:~n~p~n", [BucketName, Crap]),
                                    Acc
                            end
                    end, [], BucketNames),

    Tasks = lists:filter(
        fun (Task) ->
                is_view_task(Task) orelse is_bucket_compaction_task(Task)
        end , couch_task_status:all())
        ++ grab_local_xdcr_replications()
        ++ grab_samples_loading_tasks(),

    MaybeMeminfo =
        case misc:raw_read_file("/proc/meminfo") of
            {ok, Contents} ->
                [{meminfo, Contents}];
            _ -> []
        end,

    ClusterCompatVersion = case cluster_compat_mode:get_compat_version() of
                               undefined -> 1;
                               [VersionMaj, VersionMin] -> VersionMaj * 16#10000 + VersionMin
                           end,

    failover_safeness_level:build_local_safeness_info(BucketNames) ++
        [{active_buckets, ns_memcached:active_buckets()},
         {ready_buckets, ns_memcached:warmed_buckets()},
         {local_tasks, Tasks},
         {memory, erlang:memory()},
         {system_memory_data, memsup:get_system_memory_data()},
         {node_storage_conf, cb_config_couch_sync:get_db_and_ix_paths()},
         {statistics, erlang_stats()},
         {system_stats, [{N, proplists:get_value(N, SystemStats, 0)}
                         || N <- [cpu_utilization_rate, swap_total, swap_used]]},
         {interesting_stats, InterestingStats},
         {cluster_compatibility_version, ClusterCompatVersion}
         | element(2, ns_info:basic_info())] ++ MaybeMeminfo.


%% returns dict as if returned by ns_doctor:get_nodes/0 but containing only
%% failover safeness fields (or down bool property). Instead of going
%% to doctor it actually contacts all nodes and tries to grab fresh
%% information. See failover_safeness_level:build_local_safeness_info
grab_fresh_failover_safeness_infos(BucketsAll) ->
    do_grab_fresh_failover_safeness_infos(BucketsAll, 2000).

do_grab_fresh_failover_safeness_infos(BucketsAll, Timeout) ->
    Nodes = ns_node_disco:nodes_actual_proper(),
    BucketNames = proplists:get_keys(BucketsAll),
    {NewNodeResp, NewErrors} =
        misc:multicall_result_to_plist(
          Nodes,
          rpc:multicall(Nodes,
                        failover_safeness_level, build_local_safeness_info,
                        [BucketNames], Timeout)),

    NodeResp =
        case NewErrors of
            [] ->
                NewNodeResp;
            _ ->
                FailedNodes = proplists:get_keys(NewErrors),

                {RawCompatNodeResp, CompatErrors} =
                    misc:multicall_result_to_plist(
                      FailedNodes,
                      rpc:multicall(FailedNodes,
                                    ns_rebalancer, buckets_replication_statuses,
                                    [], Timeout)),

                case CompatErrors of
                    [] ->
                        ok;
                    _ ->
                        ?log_warning("Some nodes didn't return their failover "
                                     "safeness infos: ~n~p", [CompatErrors])
                end,

                CompatNodeResp =
                    lists:keymap(
                      fun (Status) ->
                              [{replication, Status}]
                      end, 2, RawCompatNodeResp),

                NewNodeResp ++ CompatNodeResp
        end,

    dict:from_list(NodeResp).

is_view_task(Task) ->
    lists:keyfind(set, 1, Task) =/= false andalso
        begin
            {type, Type} = lists:keyfind(type, 1, Task),
            Type =:= indexer orelse
                Type =:= view_compaction
        end andalso
        lists:keyfind(indexer_type, 1, Task) =:= {indexer_type, main}.

is_bucket_compaction_task(Task) ->
    {type, Type} = lists:keyfind(type, 1, Task),
    Type =:= bucket_compaction.

grab_local_xdcr_replications() ->
    try xdc_replication_sup:all_local_replication_infos() of
        Infos ->
            [begin
                 Props = lists:keydelete(vbs_replicating, 1, Props0),
                 [{type, xdcr}, {id, Id} | Props]
             end || {Id, Props0} <- Infos]
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
