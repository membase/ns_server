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

-define(MAIN_BEAM_NAME, <<"(main)beam.smp">>).

-define(ETS_LOG_INTVL, 180).

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
    increment_counter({request_leaves, rest}, 0),
    increment_counter({request_enters, hibernate}, 0),
    increment_counter({request_leaves, hibernate}, 0),
    increment_counter(prev_request_leaves_rest, 0),
    increment_counter(prev_request_leaves_hibernate, 0),
    increment_counter(log_counter, 0),
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

-define(STATS_V0_BLOCK_SIZE, 88).
-define(STATS_V1_BLOCK_SIZE, 112).
-define(STATS_V2_BLOCK_SIZE, 808).

recv_data(Port) ->
    recv_data_loop(Port, <<"">>).

recv_data_loop(Port, <<0:32/native, _/binary>> = Acc) ->
    Data = recv_data_with_length(Port, Acc, ?STATS_V0_BLOCK_SIZE - erlang:size(Acc)),
    {Data, fun unpack_data_v0/2};
recv_data_loop(Port, <<1:32/native, _/binary>> = Acc) ->
    Data = recv_data_with_length(Port, Acc, ?STATS_V1_BLOCK_SIZE - erlang:size(Acc)),
    {Data, fun unpack_data_v1/2};
recv_data_loop(Port, <<2:32/native, _/binary>> = Acc) ->
    Data = recv_data_with_length(Port, Acc, ?STATS_V2_BLOCK_SIZE - erlang:size(Acc)),
    {Data, fun unpack_data_v2/2};
recv_data_loop(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            recv_data_loop(Port, <<Data/binary, Acc/binary>>)
    end.

recv_data_with_length(_Port, Acc, _WantedLength = 0) ->
    erlang:iolist_to_binary(Acc);
recv_data_with_length(Port, Acc, WantedLength) ->
    receive
        {Port, {data, Data}} ->
            Size = size(Data),
            if
                Size =< WantedLength ->
                    recv_data_with_length(Port, [Acc | Data], WantedLength - Size);
                Size > WantedLength ->
                    erlang:error({too_big_recv, Size, WantedLength, Data, Acc})
            end
    end.

unpack_data_v0(Bin, PrevSample) ->
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
                {mem_used_sys, MemUsed},
                {mem_actual_used, MemActualUsed},
                {mem_actual_free, MemActualFree},
                {minor_faults, 0},
                {major_faults, 0},
                {page_faults, 0}],
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


unpack_data_v1(Bin, PrevSample) ->
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
      MemActualFree:64/native,
      MinorFaults:64/native,
      MajorFaults:64/native,
      PageFaults:64/native>> = Bin,
    StructSize = erlang:size(Bin),
    Version = 1,
    RawStats = [{cpu_local_ms, CPULocalMS},
                {cpu_idle_ms, CPUIdleMS},
                {swap_total, SwapTotal},
                {swap_used, SwapUsed},
                %% {swap_page_in, SwapPageIn},
                %% {swap_page_out, SwapPageOut},
                {mem_total, MemTotal},
                {mem_used_sys, MemUsed},
                {mem_actual_used, MemActualUsed},
                {mem_actual_free, MemActualFree},
                {minor_faults, MinorFaults},
                {major_faults, MajorFaults},
                {page_faults, PageFaults}],
    NowSamples = case PrevSample of
                     undefined -> undefined;
                     _ -> {_, OldCPULocal} = lists:keyfind(cpu_local_ms, 1, PrevSample),
                          {_, OldCPUIdle} = lists:keyfind(cpu_idle_ms, 1, PrevSample),
                          {_, OldMinorFaults} = lists:keyfind(minor_faults, 1, PrevSample),
                          {_, OldMajorFaults} = lists:keyfind(major_faults, 1, PrevSample),
                          {_, OldPageFaults} = lists:keyfind(page_faults, 1, PrevSample),
                          LocalDiff = CPULocalMS - OldCPULocal,
                          IdleDiff = CPUIdleMS - OldCPUIdle,
                          MinorFaultsDiff = MinorFaults - OldMinorFaults,
                          MajorFaultsDiff = MajorFaults - OldMajorFaults,
                          PageFaultsDiff = PageFaults - OldPageFaults,
                          RV1 = misc:update_proplist(RawStats,
                                                     [{cpu_local_ms, LocalDiff},
                                                      {cpu_idle_ms, IdleDiff},
                                                      {minor_faults, MinorFaultsDiff},
                                                      {major_faults, MajorFaultsDiff},
                                                      {page_faults, PageFaultsDiff}]),
                          [{mem_free, MemActualFree},
                           {cpu_utilization_rate, try 100 * (LocalDiff - IdleDiff) / LocalDiff
                                                  catch error:badarith -> 0 end}
                           | RV1]
                 end,
    {NowSamples, RawStats}.

unpack_data_v2(Bin, PrevSample) ->
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
      MemActualFree:64/native,
      Rest/binary>> = Bin,

    StructSize = erlang:size(Bin),
    Version = 2,

    {PrevSampleGlobal, PrevSampleProcs} =
        case PrevSample of
            undefined ->
                {undefined, []};
            _ ->
                PrevSample
        end,

    {NowSamplesProcs, PrevSampleProcs1} = unpack_processes_v2(Rest, PrevSampleProcs),

    RawStatsGlobal = [{cpu_local_ms, CPULocalMS},
                      {cpu_idle_ms, CPUIdleMS},
                      {swap_total, SwapTotal},
                      {swap_used, SwapUsed},
                      %% {swap_page_in, SwapPageIn},
                      %% {swap_page_out, SwapPageOut},
                      {mem_total, MemTotal},
                      {mem_used_sys, MemUsed},
                      {mem_actual_used, MemActualUsed},
                      {mem_actual_free, MemActualFree}],

    NowSamples = case PrevSampleGlobal of
                     undefined ->
                         undefined;
                     _ ->
                         {_, OldCPULocal} = lists:keyfind(cpu_local_ms, 1, PrevSampleGlobal),
                         {_, OldCPUIdle} = lists:keyfind(cpu_idle_ms, 1, PrevSampleGlobal),
                         LocalDiff = CPULocalMS - OldCPULocal,
                         IdleDiff = CPUIdleMS - OldCPUIdle,

                         MajorFaults = beam_stat(major_faults, NowSamplesProcs, 0),
                         MinorFaults = beam_stat(minor_faults, NowSamplesProcs, 0),
                         PageFaults = beam_stat(page_faults, NowSamplesProcs, 0),

                         RV1 = misc:update_proplist(RawStatsGlobal,
                                                    [{cpu_local_ms, LocalDiff},
                                                     {cpu_idle_ms, IdleDiff}]),

                         [{mem_free, MemActualFree},
                          {cpu_utilization_rate, try 100 * (LocalDiff - IdleDiff) / LocalDiff
                                                 catch error:badarith -> 0 end},
                          {major_faults, MajorFaults},
                          {minor_faults, MinorFaults},
                          {page_faults, PageFaults}
                          | RV1 ++ NowSamplesProcs]
                 end,

    {NowSamples, {RawStatsGlobal, PrevSampleProcs1}}.

unpack_processes_v2(Bin, PrevSamples) ->
    BeamPid = list_to_integer(os:getpid()),
    do_unpack_processes_v2(Bin, BeamPid, {[], PrevSamples}).

do_unpack_processes_v2(Bin, _, Acc) when size(Bin) =:= 0 ->
    Acc;
do_unpack_processes_v2(Bin, BeamPid, {NewSampleAcc, PrevSampleAcc} = Acc) ->
    <<Name0:12/binary,
      CpuUtilization:32/native,
      Pid:64/native,
      MemSize:64/native,
      MemResident:64/native,
      MemShare:64/native,
      MinorFaults:64/native,
      MajorFaults:64/native,
      PageFaults:64/native,
      Rest/binary>> = Bin,

    RawName = extract_string(Name0),
    case RawName of
        <<>> ->
            Acc;
        _ ->
            Name = case Pid =:= BeamPid of
                       true ->
                           ?MAIN_BEAM_NAME;
                       false ->
                           RawName
                   end,

            NewSample0 =
                [{proc_stat_name(Name, mem_size), MemSize},
                 {proc_stat_name(Name, mem_resident), MemResident},
                 {proc_stat_name(Name, mem_share), MemShare},
                 {proc_stat_name(Name, cpu_utilization), CpuUtilization},
                 {proc_stat_name(Name, minor_faults_raw), MinorFaults},
                 {proc_stat_name(Name, major_faults_raw), MajorFaults},
                 {proc_stat_name(Name, page_faults_raw), PageFaults}],

            OldPid = proc_stat(Name, pid, PrevSampleAcc),
            {MinorFaultsDiff, MajorFaultsDiff, PageFaultsDiff} =
                case OldPid =:= Pid of
                    true ->
                        OldMinorFaults = proc_stat(Name, minor_faults, PrevSampleAcc),
                        OldMajorFaults = proc_stat(Name, major_faults, PrevSampleAcc),
                        OldPageFaults = proc_stat(Name, page_faults, PrevSampleAcc),

                        true = (OldMinorFaults =/= undefined),
                        true = (OldMajorFaults =/= undefined),
                        true = (OldPageFaults =/= undefined),

                        {MinorFaults - OldMinorFaults,
                         MajorFaults - OldMajorFaults,
                         PageFaults - OldPageFaults};
                    false ->
                        {MinorFaults, MajorFaults, PageFaults}
                end,

            NewSample1 =
                [{proc_stat_name(Name, major_faults), MajorFaultsDiff},
                 {proc_stat_name(Name, minor_faults), MinorFaultsDiff},
                 {proc_stat_name(Name, page_faults), PageFaultsDiff} |
                 NewSample0],

            PrevSample1 = misc:update_proplist(PrevSampleAcc,
                                               [{proc_stat_name(Name, pid), Pid},
                                                {proc_stat_name(Name, major_faults), MajorFaults},
                                                {proc_stat_name(Name, minor_faults), MinorFaults},
                                                {proc_stat_name(Name, page_faults), PageFaults}]),

            Acc1 = {NewSample1 ++ NewSampleAcc, PrevSample1},
            do_unpack_processes_v2(Rest, BeamPid, Acc1)
    end.

extract_string(Bin) ->
    do_extract_string(Bin, size(Bin) - 1).

do_extract_string(_Bin, 0) ->
    <<>>;
do_extract_string(Bin, Pos) ->
    case binary:at(Bin, Pos) of
        0 ->
            do_extract_string(Bin, Pos - 1);
        _ ->
            binary:part(Bin, 0, Pos + 1)
    end.

beam_stat(Stat, Sample, Default) ->
    proc_stat(?MAIN_BEAM_NAME, Stat, Sample, Default).

proc_stat(Name, Stat, Sample) ->
    proc_stat(Name, Stat, Sample, undefined).

proc_stat(Name, Stat, Sample, Default) ->
    case lists:keyfind(proc_stat_name(Name, Stat), 1, Sample) of
        {_, V} ->
            V;
        _ ->
            Default
    end.

proc_stat_name(Name, Stat) ->
    <<"proc/", Name/binary, $/, (atom_to_binary(Stat, latin1))/binary>>.

add_ets_stats(Stats) ->
    [{_, NowRestLeaves}] = ets:lookup(ns_server_system_stats, {request_leaves, rest}),
    [{_, PrevRestLeaves}] = ets:lookup(ns_server_system_stats, prev_request_leaves_rest),
    ets:insert(ns_server_system_stats, {prev_request_leaves_rest, NowRestLeaves}),

    [{_, NowHibernateLeaves}] = ets:lookup(ns_server_system_stats, {request_leaves, hibernate}),
    [{_, PrevHibernateLeaves}] = ets:lookup(ns_server_system_stats, prev_request_leaves_hibernate),
    [{_, NowHibernateEnters}] = ets:lookup(ns_server_system_stats, {request_enters, hibernate}),
    ets:insert(ns_server_system_stats, {prev_request_leaves_hibernate, NowHibernateLeaves}),

    RestRate = NowRestLeaves - PrevRestLeaves,
    WakeupRate = NowHibernateLeaves - PrevHibernateLeaves,
    HibernatedCounter = NowHibernateEnters - NowHibernateLeaves,
    lists:umerge(Stats, lists:sort([{rest_requests, RestRate},
                                    {hibernated_requests, HibernatedCounter},
                                    {hibernated_waked, WakeupRate}])).

handle_info({tick, TS}, #state{port = Port, prev_sample = PrevSample}) ->
    case flush_ticks(0) of
        0 -> ok;
        N -> ?stats_warning("lost ~p ticks", [N])
    end,
    port_command(Port, <<0:32/native>>),
    {Binary, UnpackFn} = recv_data(Port),
    {Stats0, NewPrevSample} = UnpackFn(Binary, PrevSample),
    case Stats0 of
        undefined -> ok;
        _ ->
            Stats = lists:sort(Stats0),
            Stats2 = add_ets_stats(Stats),
            case ets:update_counter(ns_server_system_stats, log_counter, {2, 1, ?ETS_LOG_INTVL, 0}) of
                0 ->
                    stats_collector:log_stats(TS, "@system", ets:tab2list(ns_server_system_stats));
                _ ->
                    ok
            end,
            gen_event:notify(ns_stats_event,
                             {stats, "@system", #stat_entry{timestamp = TS,
                                                            values = Stats2}})
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
         just_avg_counter({S, calls}, {S, calls_rate}),

         just_avg_counter({S, long_call_time}),
         just_avg_counter({S, long_calls}, {S, long_calls_rate}),

         just_avg_counter({S, e2e_call_time}),
         just_avg_counter({S, e2e_calls}, {S, e2e_calls_rate})
     end || S <- ["unknown" | ActualServices]],
    ok.
