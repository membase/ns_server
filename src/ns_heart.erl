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

-define(EXPENSIVE_CHECK_INTERVAL, 15000). % In ms

-export([start_link/0, status_all/0, expensive_checks/0,
         force_beat/0, grab_fresh_failover_safeness_infos/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {
          forced_beat_timer :: reference() | undefined,
          expensive_checks_result,
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
    timer:send_interval(?EXPENSIVE_CHECK_INTERVAL, do_expensive_checks),
    self() ! do_expensive_checks,
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
    {reply, current_status(State#state.expensive_checks_result), State};
handle_call(Request, _From, State) ->
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'EXIT', EventHandler, _} = ExitMsg,
            #state{event_handler=EventHandler} = State) ->
    ?log_info("Dying because our event subscription was cancelled~n~p~n", [ExitMsg]),
    {stop, normal, State};
handle_info(beat, State) ->
    NewState = disarm_forced_beat_timer(State),
    misc:flush(beat),
    heartbeat(current_status(NewState#state.expensive_checks_result)),
    {noreply, NewState};
handle_info(do_expensive_checks, State) ->
    {noreply, State#state{expensive_checks_result = expensive_checks()}};
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

stats() ->
    Stats = [wall_clock, context_switches, garbage_collection, io, reductions,
             run_queue, runtime],
    [{Stat, statistics(Stat)} || Stat <- Stats].

%% Internal fuctions

is_interesting_stat({curr_items, _}) -> true;
is_interesting_stat({curr_items_tot, _}) -> true;
is_interesting_stat({vb_replica_curr_items, _}) -> true;
is_interesting_stat(_) -> false.

current_status(Expensive) ->
    ClusterCompatVersion = case (catch list_to_integer(os:getenv("MEMBASE_CLUSTER_COMPAT_VERSION"))) of
                               X when is_integer(X) -> X;
                               _ -> 1
                           end,

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
                lists:keyfind(set, 1, Task) =/= false andalso
                    begin
                        {type, Type} = lists:keyfind(type, 1, Task),
                        Type =:= indexer orelse Type =:= view_compaction
                    end andalso
                    lists:keyfind(indexer_type, 1, Task) =:= {indexer_type, main}
        end , couch_task_status:all()),

    failover_safeness_level:build_local_safeness_info(BucketNames) ++
    [{active_buckets, ns_memcached:active_buckets()},
     {ready_buckets, ns_memcached:connected_buckets()},
     {local_tasks, Tasks},
     {memory, erlang:memory()},
     {system_stats, [{N, proplists:get_value(N, SystemStats, 0)} || N <- [cpu_utilization_rate, swap_total, swap_used]]},
     {interesting_stats, InterestingStats},
     {cluster_compatibility_version, ClusterCompatVersion}
     | element(2, ns_info:basic_info())] ++ Expensive.


expensive_checks() ->
    BasicData = [{system_memory_data, memsup:get_system_memory_data()},
                 {node_storage_conf, cb_config_couch_sync:get_db_and_ix_paths()},
                 {statistics, stats()}],
    case misc:raw_read_file("/proc/meminfo") of
        {ok, Contents} ->
            [{meminfo, Contents} | BasicData];
        _ -> BasicData
    end.

%% returns dict as if returned by ns_doctor:get_nodes/0 but containing only
%% failover safeness fields (or down bool property). Instead of going
%% to doctor it actually contacts all nodes and tries to grab fresh
%% information. See failover_safeness_level:build_local_safeness_info
grab_fresh_failover_safeness_infos(BucketsAll) ->
    grab_fresh_failover_safeness_infos(BucketsAll, 2000).

grab_fresh_failover_safeness_infos(BucketsAll, Timeout) ->
    Nodes = ns_node_disco:nodes_actual_proper(),
    BucketNames = proplists:get_keys(BucketsAll),
    NodeResp = misc:multicall_result_to_plist(
                 Nodes,
                 rpc:multicall(Nodes, failover_safeness_level, build_local_safeness_info, [BucketNames], Timeout)),
    dict:from_list(NodeResp).
