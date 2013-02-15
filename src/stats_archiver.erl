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
%% @doc Store and aggregate statistics collected from stats_collector into a
%% collection of ETS tables, emitting 'sample_archived' events when aggregates
%% are created. The contents of ETS table is periodically dumped to files that
%% then used to restore ETS tables after restart.
%%

-module(stats_archiver).

-include("ns_common.hrl").
-include("ns_stats.hrl").

-behaviour(gen_server).

-record(state, {bucket}).

-export([ start_link/1,
          archives/0,
          table/2,
          avg/2,
          latest_sample/2,
          wipe/0 ]).

-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-define(BACKUP_INTERVAL,
        ns_config_ets_dup:get_timeout(stats_archiver_backup_interval, 120000)).


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


%% @doc Generate a suitable name for the ETS stats table.
table(Bucket, Period) ->
    list_to_atom(fmt("~s-~s-~s", [?MODULE_STRING, Bucket, Period])).

logger_file(Bucket, Period) ->
    Name = io_lib:format("~s-~s.~s", [?MODULE_STRING, Bucket, Period]),
    filename:join(stats_dir(), Name).

%% Ensure directory for stats archiver ETS table backup files
ensure_stats_storage() ->
    StatsDir = stats_dir(),
    R = case filelib:ensure_dir(StatsDir) of
            ok ->
                case file:make_dir(StatsDir) of
                    ok ->
                        ok;
                    {error, eexist} ->
                        ok;
                    Error ->
                        Error
                end;
            Error ->
                Error
        end,

    case R of
        ok ->
            ok;
        _ ->
            ?log_error("Failed to create ETS stats directory with error: ~p~n", [R])
    end,

    R.

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

%% @doc Fetch the latest stats sample
latest_sample(Bucket, Period) ->
    Tab = table(Bucket, Period),
    case ets:last(Tab) of
        '$end_of_table' ->
            {error, no_samples};
        Key ->
            {_, Sample} = hd(ets:lookup(Tab, Key)),
            {ok, Sample}
    end.

%% This function is called when ns_server_sup is shut down. So we don't race
%% with 'backup' handler here.
wipe() ->
    R = misc:rm_rf(stats_dir()),
    case R of
        ok ->
            ?log_info("Deleted stats directory.");
        _ ->
            ?log_error("Failed to delete stats directory: ~p", [R])
    end,
    R.

%%
%% gen_server callbacks
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init(Bucket) ->
    ok = ensure_stats_storage(),
    start_timers(),
    ns_pubsub:subscribe_link(ns_stats_event),
    process_flag(trap_exit, true),
    self() ! init,
    {ok, #state{bucket=Bucket}}.


handle_call(Request, _From, State) ->
    {reply, {unhandled, Request}, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(init, State) ->
    create_tables(State#state.bucket),
    {noreply, State};
handle_info({stats, Bucket, Sample}, State = #state{bucket=Bucket}) ->
    Tab = table(Bucket, minute),
    #stat_entry{timestamp=TS} = Sample,
    ets:insert(Tab, {TS, Sample}),
    gen_event:notify(ns_stats_event, {sample_archived, Bucket, Sample}),
    {noreply, State};
handle_info({sample_archived, _, _}, State) ->
    {noreply, State};
handle_info({truncate, Period, N}, #state{bucket=Bucket} = State) ->
    Tab = table(Bucket, Period),
    truncate_logger(Tab, N),
    {noreply, State};
handle_info({cascade, Prev, Period, Step}, #state{bucket=Bucket} = State) ->
    cascade_logger(Bucket, Prev, Period, Step),
    {noreply, State};
handle_info(backup, #state{bucket=Bucket} = State) ->
    misc:flush(backup),
    proc_lib:spawn_link(
      fun () ->
              backup_loggers(Bucket)
      end),
    {noreply, State};
handle_info({'EXIT', _Pid, Reason} = Exit, State) ->
    case Reason of
        normal ->
            ok;
        _Other ->
            ?log_warning("Process exited unexpectedly: ~p", [Exit])
    end,
    {noreply, State};
handle_info(_Msg, State) -> % Don't crash on delayed responses from calls
    {noreply, State}.


terminate(_Reason, #state{bucket=Bucket} = _State) ->
    backup_loggers(Bucket),
    ok.


%%
%% Internal functions
%%

create_tables(Bucket) ->
    %% create stats logger tables
    [ check_logger(Bucket, Period) || {Period, _, _} <- archives() ].

read_table(Path, TableName) ->
    ets:new(TableName, [ordered_set, protected, named_table]),
    RV = case file:read_file(Path) of
             {ok, <<>>} -> ok;
             {ok, B} ->
                 try zlib:uncompress(B) of
                     B2 ->
                         ets:insert(TableName, binary_to_term(B2)),
                         ok
                 catch error:data_error ->
                         {error, data_error}
                 end;
             {error, enoent} ->
                 ok;
             Err ->
                 Err
         end,
    case RV of
        ok ->
            ok;
        _ ->
            ?log_error("Failed to restore stats table from "
                       "file ~p with error ~p~n", [Path, RV])
    end,
    ok.

check_logger(Bucket, Period) ->
    File = logger_file(Bucket, Period),
    read_table(File, table(Bucket, Period)).

backup_logger(Bucket, Period) ->
    Tab = table(Bucket, Period),
    File = logger_file(Bucket, Period),
    Data = zlib:compress(erlang:term_to_binary(ets:tab2list(Tab))),
    case misc:atomic_write_file(File, Data) of
        {error, Reason} = Error ->
            ?log_error("Failed to backup stats table ~p with error ~p~n", [Tab, Reason]),
            Error;
        OK ->
            OK
    end.

backup_loggers(Bucket) ->
    lists:foreach(
      fun ({Period, _, _}) ->
              backup_logger(Bucket, Period)
      end, archives()).

%% keep the last N stats samples and delete the rest
truncate_logger(Tab, NumToKeep) ->
    ets:foldr(fun ({Key, _}, I) ->
                      case I >= NumToKeep of
                          true ->
                              ets:delete(Tab, Key);
                          false ->
                              ok
                      end,
                      I + 1
              end, 0, Tab).

cascade_logger(Bucket, Prev, Period, Step) ->
    true = (Period =/= minute),

    PrevTab = table(Bucket, Prev),
    NextTab = table(Bucket, Period),
    case coalesce_stats(PrevTab, Step) of
        false ->
            ok;
        Avg ->
            #stat_entry{timestamp=TS} = Avg,
            ets:insert(NextTab, {TS, Avg})
    end.

coalesce_stats(Tab, Step) ->
    case ets:last(Tab) of
        '$end_of_table' -> false;
        LastTS -> coalesce_stats(Tab, LastTS, Step, [])
    end.

coalesce_stats(Tab, TS, Step, Samples) ->
    [{_, OneSample}] = ets:lookup(Tab, TS),
    Samples1 = [OneSample|Samples],
    PrevTS = ets:prev(Tab, TS),
    T = misc:trunc_ts(TS, Step),
    case PrevTS == '$end_of_table' orelse misc:trunc_ts(PrevTS, Step) /= T of
        false ->
            coalesce_stats(Tab, PrevTS, Step, Samples1);
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
    start_cascade_timers(Archives),
    timer:send_interval(?BACKUP_INTERVAL, backup).

-spec fmt(string(), list()) -> list().
fmt(Str, Args)  ->
    lists:flatten(io_lib:format(Str, Args)).

stats_dir() ->
    path_config:component_path(data, "stats").
