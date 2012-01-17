%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% @doc Store and aggregate statistics collected from stats_collector into
%% mnesia, emitting 'sample_archived' events when aggregates are created.
%%

-module(stats_archiver).

-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-include("ns_common.hrl").
-include("ns_stats.hrl").

-behaviour(gen_server).

-define(RETRIES, 10).

-record(state, {bucket}).

-export([ start_link/1,
          archives/0,
          table/2,
          avg/2 ]).

-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).


%%
%% API
%%

start_link(Bucket) ->
    gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, []).


%% @doc the type of statistics collected
%% {Period, Seconds, Samples}
archives() ->
    [{minute, 1,     60},
     {hour,   4,     900},
     {day,    60,    1440}, % 24 hours
     {week,   600,   1152}, % eight days (computer weeks)
     {month,  1800,  1488}, % 31 days
     {year,   21600, 1464}]. % 366 days


%% @doc Generate a suitable name for the Mnesia table.
table(Bucket, Period) ->
    list_to_atom(fmt("~s-~s-~s", [?MODULE_STRING, Bucket, Period])).


%% @doc Compute the average of a list of entries.
-spec avg(atom() | integer(), list()) -> #stat_entry{}.
avg(TS, [First|Rest]) ->
    Sum = fun(_K, null, B) -> B;
             (_K, A, null) -> A;
             (_K, A, B)    -> A + B
          end,
    Merge = fun(E, Acc) -> orddict:merge(Sum, Acc, E#stat_entry.values) end,
    Sums = lists:foldl(Merge, First#stat_entry.values, Rest),
    Count = 1 + length(Rest),
    #stat_entry{timestamp = TS,
                values = orddict:map(fun (_Key, null) -> null;
                                         (_Key, Value) -> Value / Count
                                     end, Sums)}.


%%
%% gen_server callbacks
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init(Bucket) ->
    start_timers(),
    ns_pubsub:subscribe_link(ns_stats_event),
    self() ! init,
    {ok, #state{bucket=Bucket}}.


handle_call(Request, _From, State) ->
    {reply, {unhandled, Request}, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(Msg, State) ->
    {ok, TRef} = timer:kill_after(60000),
    try
        do_handle_info(Msg, State)
    after
        timer:cancel(TRef)
    end.

do_handle_info(init, State) ->
    create_tables(State#state.bucket),
    {noreply, State};
do_handle_info({stats, Bucket, Sample}, State = #state{bucket=Bucket}) ->
    Tab = table(Bucket, minute),
    {atomic, ok} = mnesia:transaction(fun () ->
                                              mnesia:write(Tab, Sample, write)
                                      end, ?RETRIES),
    gen_event:notify(ns_stats_event, {sample_archived, Bucket, Sample}),
    {noreply, State};
do_handle_info({sample_archived, _, _}, State) ->
    {noreply, State};
do_handle_info({truncate, Period, N}, #state{bucket=Bucket} = State) ->
    Tab = table(Bucket, Period),
    mb_mnesia:truncate(Tab, N),
    {noreply, State};
do_handle_info({cascade, Prev, Period, Step}, #state{bucket=Bucket} = State) ->
    cascade(Bucket, Prev, Period, Step),
    {noreply, State};
do_handle_info(_Msg, State) -> % Don't crash on delayed responses from calls
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

cascade(Bucket, Prev, Period, Step) ->
    PrevTab = table(Bucket, Prev),
    NextTab = table(Bucket, Period),
    {atomic, ok} = mnesia:transaction(
                     fun () ->
                             case last_chunk(PrevTab, Step) of
                                 false -> ok;
                                 Avg ->
                                     mnesia:write(NextTab, Avg, write)
                             end
                     end, ?RETRIES).

create_tables(Bucket) ->
    Table = [{record_name, stat_entry},
             {type, ordered_set},
             {local_content, true},
             {attributes, record_info(fields, stat_entry)}],
    [ mb_mnesia:ensure_table(table(Bucket, Period), Table)
      || {Period, _, _} <- archives() ].


last_chunk(Tab, Step) ->
    case mnesia:last(Tab) of
        '$end_of_table' ->
            false;
        TS ->
            last_chunk(Tab, TS, Step, [])
    end.

last_chunk(Tab, TS, Step, Samples) ->
    Samples1 = [hd(mnesia:read(Tab, TS))|Samples],
    TS1 = mnesia:prev(Tab, TS),
    T = misc:trunc_ts(TS, Step),
    case TS1 == '$end_of_table' orelse misc:trunc_ts(TS1, Step) /= T of
        false ->
            last_chunk(Tab, TS1, Step, Samples1);
        true ->
            avg(T, Samples1)
    end.


%% @doc Generate a suitable name for the per-bucket gen_server.
server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).


%% @doc Start the timers to cascade samples to the next resolution.
start_cascade_timers([{Prev, _, _} | [{Next, Step, _} | _] = Rest]) ->
    timer:send_interval(200 * Step, {cascade, Prev, Next, Step}),
    start_cascade_timers(Rest);

start_cascade_timers([_]) ->
    ok.


%% @doc Start timers for various housekeeping tasks.
start_timers() ->
    Archives = archives(),
    lists:foreach(
      fun ({Period, Step, Samples}) ->
              Interval = 100 * Step * Samples,  % Allow to go over by 10% of the
                                                % total samples
              timer:send_interval(Interval, {truncate, Period, Samples})
      end, Archives),
    start_cascade_timers(Archives).

-spec fmt(string(), list()) -> list().
fmt(Str, Args)  ->
    lists:flatten(io_lib:format(Str, Args)).
