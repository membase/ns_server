%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
-module(query_stats_collector).

-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

-include("ns_common.hrl").

-include("ns_stats.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {prev_counters = [],
                prev_ts = 0}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
    ns_pubsub:subscribe_link(ns_tick_event),
    ets:new(query_stats_collector_names, [private, named_table]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

latest_tick(TS, NumDropped) ->
    receive
        {tick, TS1} ->
            latest_tick(TS1, NumDropped + 1)
    after 0 ->
            if NumDropped > 0 ->
                    ?stats_warning("Dropped ~b ticks", [NumDropped]);
               true ->
                    ok
            end,
            TS
    end.

%% [{<<"active_requests.count">>,0},
%%  {<<"deletes.count">>,0},
%%  {<<"errors.count">>,0},
%%  {<<"inserts.count">>,0},
%%  {<<"mutations.count">>,0},
%%  {<<"queued_requests.count">>,0},
%%  {<<"request_time.count">>,0},
%%  {<<"requests.count">>,0},
%%  {<<"requests_1000ms.count">>,0},
%%  {<<"requests_250ms.count">>,0},
%%  {<<"requests_5000ms.count">>,0},
%%  {<<"requests_500ms.count">>,0},
%%  {<<"result_count.count">>,0},
%%  {<<"result_size.count">>,0},
%%  {<<"selects.count">>,0},
%%  {<<"service_time.count">>,0},
%%  {<<"updates.count">>,0},
%%  {<<"warnings.count">>,0}]

%% Those are not part of any graphs yet, but otherwise dialyzer
%% doesn't like trying to deal with empty gauges below.
-define(Q_GAUGES, [active_requests, queued_requests]).
-define(Q_COUNTERS, [errors,
                     request_time,
                     requests,
                     requests_500ms,
                     requests_250ms,
                     requests_1000ms,
                     requests_5000ms,
                     result_count,
                     result_size,
                     selects,
                     service_time,
                     warnings]).

recognize_name(K) ->
    case ets:lookup(query_stats_collector_names, K) of
        [{K, Type, NewK}] ->
            {Type, NewK};
        [{K, undefined}] ->
            undefined;
        [] ->
            case do_recognize_name(K) of
                undefined ->
                    ets:insert(query_stats_collector_names, {K, undefined}),
                    undefined;
                {Type, NewK} ->
                    ets:insert(query_stats_collector_names, {K, Type, NewK}),
                    {Type, NewK}
            end
    end.

do_recognize_name(K) ->
    MaybeGauge = [NK || NK <- ?Q_GAUGES,
                        NKT <- [iolist_to_binary(io_lib:format("~s.count", [NK]))],
                        NKT =:= K],
    MaybeCounter = [NK || NK <- ?Q_COUNTERS,
                          NKT <- [iolist_to_binary(io_lib:format("~s.count", [NK]))],
                          NKT =:= K],
    case {MaybeGauge, MaybeCounter} of
        {[], []} -> undefined;
        {[NK], []} ->
            {gauge, list_to_atom("query_" ++ atom_to_list(NK))};
        {[], [NK]} ->
            {counter, list_to_atom("query_" ++ atom_to_list(NK))}
    end.

massage_stats([], AccGauges, AccCounters) ->
    {AccGauges, AccCounters};
massage_stats([{K, V} | Rest], AccGauges, AccCounters) ->
    case recognize_name(K) of
        undefined ->
            massage_stats(Rest, AccGauges, AccCounters);
        {counter, NewK} ->
            massage_stats(Rest, AccGauges, [{NewK, V} | AccCounters]);
        {gauge, NewK} ->
            massage_stats(Rest, [{NewK, V} | AccGauges], AccCounters)
    end.

diff_counters(_InvTSDiff, [], _PrevCounters, Acc) ->
    lists:reverse(Acc);
diff_counters(InvTSDiff, [{K, V} | RestCounters] = Counters, PrevCounters, Acc) ->
    case PrevCounters of
        %% NOTE: K is bound
        [{K, OldV} | RestPrev] ->
            D = (V - OldV) * InvTSDiff,
            diff_counters(InvTSDiff, RestCounters, RestPrev, [{K, D} | Acc]);
        [{PrevK, _} | RestPrev] when PrevK < K->
            diff_counters(InvTSDiff, Counters, RestPrev, Acc);
        _ ->
            diff_counters(InvTSDiff, RestCounters, PrevCounters, [{K, 0} | Acc])
    end.

grab_stats(PrevCounters, TSDiff) ->
    {StatsGauges, StatsCounters0} = massage_stats(query_rest:get_stats(), [], []),
    StatsCounters = lists:sort(StatsCounters0),
    Stats0 = diff_counters(1000.0 / TSDiff, StatsCounters, PrevCounters, []),
    Stats = lists:merge(Stats0, lists:sort(StatsGauges)),
    {Stats, StatsCounters}.

handle_info({tick, TS0}, #state{prev_counters = PrevCounters,
                                prev_ts = PrevTS}) ->
    TS = latest_tick(TS0, 0),
    {Stats, NewCounters} = grab_stats(PrevCounters, TS - PrevTS),
    gen_event:notify(ns_stats_event,
                     {stats, "@query", #stat_entry{timestamp = TS,
                                                   values = Stats}}),
    {noreply, #state{prev_counters = NewCounters,
                     prev_ts = TS}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
