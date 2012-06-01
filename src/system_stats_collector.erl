%% @author Couchbase, Inc <info@couchbase.com>
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
%% @doc grabs system-level stats portsigar
%%
-module(system_stats_collector).

-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

-include("ns_common.hrl").

-include("ns_stats.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([increment_counter/2, get_ns_server_stats/0, set_counter/2]).

-record(state, {port, prev_sample}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
    ets:new(ns_server_system_stats, [public, named_table, set]),
    Path = path_config:component_path(bin, "sigar_port"),
    Port =
        try open_port({spawn_executable, Path},
                      [stream, use_stdio, exit_status,
                       binary, eof, {arg0, lists:flatten(io_lib:format("portsigar for ~s", [node()]))}]) of
            X ->
                ns_pubsub:subscribe_link(ns_tick_event),
                X
        catch error:enoent ->
                ale:error(?USER_LOGGER, "~s is missing. Will not collect system-level stats", [Path]),
                undefined
        end,
    {ok, #state{port = Port}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

flush_ticks(Acc) ->
    receive
        {tick, _} ->
            flush_ticks(Acc+1)
    after 0 ->
            Acc
    end.

recv_data(Port, Acc, WantedLength) ->
    receive
        {Port, {data, Data}} ->
            Size = size(Data),
            if
                Size < WantedLength ->
                    recv_data(Port, [Data | Acc], WantedLength - Size);
                Size =:= WantedLength ->
                    erlang:iolist_to_binary(lists:reverse([Data | Acc]));
                Size > WantedLength ->
                    erlang:error({too_big_recv, Size, WantedLength, Data, Acc})
            end
    end.

-define(STATS_BLOCK_SIZE, 88).

unpack_data(Bin, PrevSample) ->
    <<Version:32/native,
      StructSize:32/native,
      CPULocalMS:64/native,
      CPUIdleMS:64/native,
      SwapTotal:64/native,
      SwapUsed:64/native,
      _SwapPageIn:64/native,
      _SwapPageOut:64/native,
      MemTotal:64/native,
      MemUsed:64/native,
      MemActualUsed:64/native,
      MemActualFree:64/native>> = Bin,
    StructSize = erlang:size(Bin),
    Version = 0,
    RawStats = [{cpu_local_ms, CPULocalMS},
                {cpu_idle_ms, CPUIdleMS},
                {swap_total, SwapTotal},
                {swap_used, SwapUsed},
                %% {swap_page_in, SwapPageIn},
                %% {swap_page_out, SwapPageOut},
                {mem_total, MemTotal},
                {mem_used, MemUsed},
                {mem_actual_used, MemActualUsed},
                {mem_actual_free, MemActualFree}],
    NowSamples = case PrevSample of
                     undefined -> undefined;
                     _ -> {_, OldCPULocal} = lists:keyfind(cpu_local_ms, 1, PrevSample),
                          {_, OldCPUIdle} = lists:keyfind(cpu_idle_ms, 1, PrevSample),
                          LocalDiff = CPULocalMS - OldCPULocal,
                          IdleDiff = CPUIdleMS - OldCPUIdle,
                          RV1 = lists:keyreplace(cpu_local_ms, 1, RawStats, {cpu_local_ms, LocalDiff}),
                          RV2 = lists:keyreplace(cpu_idle_ms, 1, RV1, {cpu_idle_ms, IdleDiff}),
                          [{mem_free, MemTotal - MemUsed},
                           {cpu_utilization_rate, try 100 * (LocalDiff - IdleDiff) / LocalDiff
                                                  catch error:badarith -> 0 end}
                           | RV2]
                 end,
    {NowSamples, RawStats}.

handle_info({tick, TS}, #state{port = Port, prev_sample = PrevSample}) ->
    case flush_ticks(0) of
        0 -> ok;
        N -> ?stats_warning("lost ~p ticks", [N])
    end,
    port_command(Port, <<0:32/native>>),
    Binary = recv_data(Port, [], ?STATS_BLOCK_SIZE),
    {Stats0, NewPrevSample} = unpack_data(Binary, PrevSample),
    case Stats0 of
        undefined -> ok;
        _ ->
            Stats = lists:sort(Stats0),
            gen_event:notify(ns_stats_event,
                             {stats, "@system", #stat_entry{timestamp = TS,
                                                            values = Stats}})
    end,
    update_merger_rates(),
    sample_ns_memcached_queues(),
    {noreply, #state{port = Port, prev_sample = NewPrevSample}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

increment_counter(Name, By) ->
    (catch do_increment_counter(Name, By)).

do_increment_counter(Name, By) ->
    ets:insert_new(ns_server_system_stats, {Name, 0}),
    ets:update_counter(ns_server_system_stats, Name, By).

set_counter(Name, Value) ->
    (catch do_set_counter(Name, Value)).

do_set_counter(Name, Value) ->
    case ets:insert_new(ns_server_system_stats, {Name, Value}) of
        false ->
            ets:update_element(ns_server_system_stats, Name, {2, Value});
        true ->
            ok
    end.

get_ns_server_stats() ->
    ets:tab2list(ns_server_system_stats).

%% those constants are used to average config merger rates
%% exponentially. See
%% http://en.wikipedia.org/wiki/Moving_average#Exponential_moving_average
-define(TEN_SEC_ALPHA, 0.0951625819640405).
-define(MIN_ALPHA, 0.0165285461783825).
-define(FIVE_MIN_ALPHA, 0.0799555853706767).

combine_avg_key(Key, Prefix) ->
    case is_tuple(Key) of
        true ->
            list_to_tuple([Prefix | tuple_to_list(Key)]);
        false ->
            {Prefix, Key}
    end.

update_avgs(Key, Value) ->
    [update_avg(combine_avg_key(Key, Prefix), Value, Alpha)
     || {Prefix, Alpha} <- [{avg_10s, ?TEN_SEC_ALPHA},
                            {avg_1m, ?MIN_ALPHA},
                            {avg_5m, ?FIVE_MIN_ALPHA}]],
    ok.

update_avg(Key, Value, Alpha) ->
    OldValue = case ets:lookup(ns_server_system_stats, Key) of
                   [] ->
                       0;
                   [{_, V}] ->
                       V
               end,
    NewValue = OldValue + (Value - OldValue) * Alpha,
    set_counter(Key, NewValue).

read_counter(Key) ->
    ets:insert_new(ns_server_system_stats, {Key, 0}),
    [{_, V}] = ets:lookup(ns_server_system_stats, Key),
    V.

read_and_dec_counter(Key) ->
    V = read_counter(Key),
    increment_counter(Key, -V),
    V.

update_merger_rates() ->
    SleepTime = read_and_dec_counter(total_config_merger_sleep_time),
    update_avgs(config_merger_sleep_time, SleepTime),

    RunTime = read_and_dec_counter(total_config_merger_run_time),
    update_avgs(config_merger_run_time, RunTime),

    Runs = read_and_dec_counter(total_config_merger_runs),
    update_avgs(config_merger_runs_rate, Runs),

    QL = read_counter(config_merger_queue_len),
    update_avgs(config_merger_queue_len, QL).

just_avg_counter(RawKey, AvgKey) ->
    V = read_and_dec_counter(RawKey),
    update_avgs(AvgKey, V).

just_avg_counter(RawKey) ->
    just_avg_counter(RawKey, RawKey).

sample_ns_memcached_queues() ->
    KnownsServices = case ets:lookup(ns_server_system_stats, tracked_ns_memcacheds) of
                         [] -> [];
                         [{_, V}] -> V
                     end,
    ActualServices = [ServiceName || ("ns_memcached-" ++ _) = ServiceName <-
                                         [atom_to_list(Name) || Name <- registered()]],
    ets:insert(ns_server_system_stats, {tracked_ns_memcacheds, ActualServices}),
    [begin
         [ets:delete(ns_server_system_stats, {Prefix, S, Stat})
          || Prefix <- [avg_10s, avg_1m, avg_5m]],
         ets:delete(ns_server_system_stats, {S, Stat})
     end
     || S <- KnownsServices -- ActualServices,
        Stat <- [qlen, call_time, calls, calls_rate,
                 long_call_time, long_calls, long_calls_rate,
                 e2e_call_time, e2e_calls, e2e_calls_rate]],
    [begin
         case (catch erlang:process_info(whereis(list_to_atom(S)), message_queue_len)) of
             {message_queue_len, QL} ->
                 QLenKey = {S, qlen},
                 update_avgs(QLenKey, QL),
                 set_counter(QLenKey, QL);
             _ -> ok
         end,

         just_avg_counter({S, call_time}),
         just_avg_counter({S, q_call_time}),
         just_avg_counter({S, calls}, {S, calls_rate}),

         just_avg_counter({S, long_call_time}),
         just_avg_counter({S, long_calls}, {S, long_calls_rate}),

         just_avg_counter({S, e2e_call_time}),
         just_avg_counter({S, e2e_calls}, {S, e2e_calls_rate})
     end || S <- ["unknown" | ActualServices]],
    ok.
