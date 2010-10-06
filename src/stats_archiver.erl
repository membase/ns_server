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
%% @doc Store statistics collected from memcached.
%%

-module(stats_archiver).

-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-include("ns_common.hrl").
-include("ns_stats.hrl").

-behaviour(gen_server).

-define(TRUNC_FREQ, 10).
-define(RETRIES, 10).

-record(state, {bucket}).

-export([archives/0,
         start_link/1,
         table/2]).

-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).


%%
%% API
%%

start_link(Bucket) ->
    gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, []).


%%
%% gen_server callbacks
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init(Bucket) ->
    create_tables(Bucket),
    start_timers(),
    ns_pubsub:subscribe(ns_stats_event),
    {ok, #state{bucket=Bucket}}.


handle_call(Request, _From, State) ->
    {reply, {unhandled, Request}, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info({stats, Bucket, Sample}, State = #state{bucket=Bucket}) ->
    Tab = table(Bucket, minute),
    {atomic, ok} = mnesia:transaction(fun () ->
                                              mnesia:write(Tab, Sample, write)
                                      end, ?RETRIES),
    gen_event:notify(ns_stats_event, {sample_archived, Bucket, Sample}),
    {noreply, State};
handle_info({sample_archived, _, _}, State) ->
    {noreply, State};
handle_info({truncate, Period, N}, #state{bucket=Bucket} = State) ->
    Tab = table(Bucket, Period),
    ns_mnesia:truncate(Tab, N),
    {noreply, State};
handle_info({cascade, Prev, Period, Step}, #state{bucket=Bucket} = State) ->
    cascade(Bucket, Prev, Period, Step),
    {noreply, State};
handle_info(_Msg, State) -> % Don't crash on delayed responses from calls
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

%% {Period, Seconds, Samples}
archives() ->
    [{minute, 1, 60},
     {hour, 4, 900},
     {day, 60, 1440}, % 24 hours
     {week, 600, 1152}, % eight days (computer weeks)
     {month, 1800, 1488}, % 31 days
     {year, 21600, 1464}]. % 366 days


%% @doc Compute the average of a list of entries.
avg(TS, Samples) ->
    [First|Rest] = Samples,
    {_, FirstList} = stat_to_list(First),
    Sums = lists:foldl(fun (E, Acc) ->
                               {_, L} = stat_to_list(E),
                               lists:zipwith(fun (A, B) -> A + B end, L, Acc)
                       end, FirstList, Rest),
    Count = length(Samples),
    Avgs = [X / Count || X <- Sums],
    list_to_stat(TS, Avgs).


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
    lists:foreach(
      fun ({Period, _, _}) ->
              ns_mnesia:ensure_table(table(Bucket, Period),
                                     [{record_name, stat_entry},
                                      {type, ordered_set},
                                      {local_content, true},
                                      {attributes,
                                       record_info(fields, stat_entry)}])
      end, archives()).


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


%% @doc Convert a list of values from stat_to_list back to a stat entry.
list_to_stat(TS, List) ->
    list_to_tuple([stat_entry, TS | List]).


%% @doc Generate a suitable name for the per-bucket gen_server.
server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).


%% @doc Convert a stat entry to a list of values.
stat_to_list(Entry) ->
    [stat_entry, TS | L] = tuple_to_list(Entry),
    {TS, L}.


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


%% @doc Generate a suitable name for the Mnesia table.
table(Bucket, Period) ->
    list_to_atom(lists:flatten(io_lib:format("~s-~s-~s",
                                             [?MODULE_STRING,
                                              Bucket, Period]))).
