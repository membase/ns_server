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

-record(state, {port, prev_sample}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
    Path = path_config:component_path(bin, "sigar_port"),
    Port =
        try open_port({spawn_executable, Path},
                      [stream, use_stdio, exit_status,
                       binary, eof, {arg0, lists:flatten(io_lib:format("portsigar for ~s", [node()]))}]) of
            X ->
                ns_pubsub:subscribe_link(ns_tick_event),
                X
        catch error:enoent ->
                ?stats_warning("~s is missing. Will not collect system-level stats", [Path]),
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
                                                            values = lists:sort(Stats)}})
    end,
    {noreply, #state{port = Port, prev_sample = NewPrevSample}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
