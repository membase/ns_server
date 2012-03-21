%% @author Couchbase <info@couchbase.com>
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

-module(ale).

-behaviour(gen_server).

-export([start_link/0, start_link/1,
         start_sink/3, stop_sink/1,
         start_logger/1, start_logger/2, start_logger/3,
         stop_logger/1,
         add_sink/2, add_sink/3,
         set_loglevel/2, get_loglevel/1,
         set_sync_loglevel/2, get_sync_loglevel/1,
         set_sink_loglevel/3, get_sink_loglevel/2]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-compile({parse_transform, ale_transform}).

-include("ale.hrl").

-record(state, {sinks   = ordsets:new() :: [atom()],
                loggers = ordsets:new() :: [atom()],

                mailbox_len_limit :: integer()}).

-define(CHECK_MAILBOXES_INTERVAL, 3000).
-define(MAILBOX_LENGTH_LIMIT, 100000).

%% API

start_link() ->
    start_link(?MAILBOX_LENGTH_LIMIT).

start_link(MailboxLenLimit) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [MailboxLenLimit], []).

start_sink(Name, Module, Args) ->
    gen_server:call(?MODULE, {start_sink, Name, Module, Args}).

stop_sink(Name) ->
    gen_server:call(?MODULE, {stop_sink, Name}).

start_logger(Name) ->
    start_logger(Name, ?DEFAULT_LOGLEVEL, ?DEFAULT_SYNC_LOGLEVEL).

start_logger(Name, LogLevel) ->
    start_logger(Name, LogLevel, ?DEFAULT_SYNC_LOGLEVEL).

start_logger(Name, LogLevel, SyncLogLevel) ->
    gen_server:call(?MODULE, {start_logger, Name, LogLevel, SyncLogLevel}).

stop_logger(Name) ->
    gen_server:call(?MODULE, {stop_logger, Name}).

add_sink(LoggerName, SinkName) ->
    add_sink(LoggerName, SinkName, undefined).

add_sink(LoggerName, SinkName, LogLevel) ->
    gen_server:call(?MODULE,
                    {add_sink, LoggerName, SinkName, LogLevel}).

set_loglevel(LoggerName, LogLevel) ->
    gen_server:call(?MODULE, {set_loglevel, LoggerName, LogLevel}).

get_loglevel(LoggerName) ->
    gen_server:call(?MODULE, {get_loglevel, LoggerName}).

set_sync_loglevel(LoggerName, LogLevel) ->
    gen_server:call(?MODULE, {set_sync_loglevel, LoggerName, LogLevel}).

get_sync_loglevel(LoggerName) ->
    gen_server:call(?MODULE, {get_sync_loglevel, LoggerName}).

set_sink_loglevel(LoggerName, SinkName, LogLevel) ->
    gen_server:call(?MODULE,
                    {set_sink_loglevel, LoggerName, SinkName, LogLevel}).

get_sink_loglevel(LoggerName, SinkName) ->
    gen_server:call(?MODULE, {get_sink_loglevel, LoggerName, SinkName}).

%% Callbacks
init([MailboxLenLimit]) ->
    State = #state{mailbox_len_limit=MailboxLenLimit},

    {ok, State1} = do_start_logger(?ERROR_LOGGER,
                                   ?DEFAULT_LOGLEVEL, ?DEFAULT_SYNC_LOGLEVEL,
                                   State),
    {ok, State2} = do_start_logger(?ALE_LOGGER,
                                   ?DEFAULT_LOGLEVEL, ?DEFAULT_SYNC_LOGLEVEL,
                                   State1),
    set_error_logger_handler(),
    rearm_timer(),

    {ok, State2}.

handle_call({start_sink, Name, Module, Args}, _From, State) ->
    RV = do_start_sink(Name, Module, Args, State),
    handle_result(RV, State);

handle_call({stop_sink, Name}, _From, State) ->
    RV = do_stop_sink(Name, State),
    handle_result(RV, State);

handle_call({start_logger, Name, LogLevel, SyncLogLevel}, _From, State) ->
    RV = do_start_logger(Name, LogLevel, SyncLogLevel, State),
    handle_result(RV, State);

handle_call({stop_logger, Name}, _From, State) ->
    RV = do_stop_logger(Name, State),
    handle_result(RV, State);

handle_call({add_sink, LoggerName, SinkName, LogLevel}, _From, State) ->
    RV = do_add_sink(LoggerName, SinkName, LogLevel, State),
    handle_result(RV, State);

handle_call({set_loglevel, LoggerName, LogLevel}, _From, State) ->
    RV = do_set_loglevel(LoggerName, LogLevel, State),
    handle_result(RV, State);

handle_call({get_loglevel, LoggerName}, _From, State) ->
    RV = do_get_loglevel(LoggerName, State),
    handle_result(RV, State);

handle_call({set_sync_loglevel, LoggerName, LogLevel}, _From, State) ->
    RV = do_set_sync_loglevel(LoggerName, LogLevel, State),
    handle_result(RV, State);

handle_call({get_sync_loglevel, LoggerName}, _From, State) ->
    RV = do_get_sync_loglevel(LoggerName, State),
    handle_result(RV, State);

handle_call({set_sink_loglevel, LoggerName, SinkName, LogLevel},
            _From, State) ->
    RV = do_set_sink_loglevel(LoggerName, SinkName, LogLevel, State),
    handle_result(RV, State);

handle_call({get_sink_loglevel, LoggerName, SinkName}, _From, State) ->
    RV = do_get_sink_loglevel(LoggerName, SinkName, State),
    handle_result(RV, State);

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'gen_event_EXIT', ale_error_logger_handler, Reason}, State)
  when Reason =/= normal,
       Reason =/= shutdown ->
    ale:error(?ALE_LOGGER,
              "ale_reports_handler terminated with reason ~p; restarting",
              [Reason]),

    set_error_logger_handler(),
    {noreply, State};

handle_info({timeout, _TRef, check_mailboxes},
            #state{sinks=Sinks, mailbox_len_limit=Limit} = State) ->
    ale:info(?ALE_LOGGER, "Checking mailboxes"),

    Fn =
        fun (SinkName) ->
                SinkId = ale_utils:sink_id(SinkName),
                case whereis(SinkId) of
                    undefined ->
                        ale:warn(?ALE_LOGGER,
                                 "Unable to find pid for ~p sink",
                                 [SinkName]);
                    Pid ->
                        {message_queue_len, QueueLen} =
                            erlang:process_info(Pid, message_queue_len),
                        case QueueLen > Limit of
                            true ->
                                ale:warn(?ALE_LOGGER,
                                         "Sink's (~p) mailbox is too big. "
                                         "Restarting the sink.",
                                         [SinkName]),
                                ale_dynamic_sup:restart_child(SinkId);
                            false ->
                                ok
                        end
                end
        end,

    lists:foreach(Fn, Sinks),

    rearm_timer(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ensure_sink(SinkName, #state{sinks=Sinks} = _State, Fn) ->
    case ordsets:is_element(SinkName, Sinks) of
        false ->
            {error, unknown_sink};
        true ->
            Fn()
    end.

ensure_logger(LoggerName, #state{loggers=Loggers} = _State, Fn) ->
    case ordsets:is_element(LoggerName, Loggers) of
        false ->
            {error, unknown_logger};
        true ->
            Fn()
    end.

handle_result(Result, OldState) ->
    case Result of
        {ok, NewState} ->
            {reply, ok, NewState};
        {{ok, RV}, NewState} ->
            {reply, {ok, RV}, NewState};
        _Other ->
            {reply, Result, OldState}
    end.

do_start_sink(Name, Module, Args, #state{sinks=Sinks} = State) ->
    case ordsets:is_element(Name, Sinks) of
        true ->
            {error, duplicate_sink};
        false ->
            SinkId = ale_utils:sink_id(Name),
            Args1 = [SinkId | Args],

            RV = ale_dynamic_sup:start_child(SinkId, Module, Args1),
            case RV of
                {ok, _} ->
                    NewState =
                        State#state{sinks=ordsets:add_element(Name, Sinks)},
                    {ok, NewState};
                _Other ->
                    RV
            end
    end.

do_stop_sink(Name, #state{sinks=Sinks} = State) ->
    ensure_sink(
      Name, State,
      fun () ->
              SinkId = ale_utils:sink_id(Name),
              ok = ale_dynamic_sup:stop_child(SinkId),
              NewState = State#state{sinks=ordsets:del_element(Name, Sinks)},
              {ok, NewState}
      end).

do_start_logger(Name, LogLevel, SyncLogLevel,
                #state{loggers=Loggers} = State) ->
    case ordsets:is_element(Name, Loggers) of
        true ->
            {error, duplicate_logger};
        false ->
            LoggerId = ale_utils:logger_id(Name),

            RV = ale_dynamic_sup:start_child(LoggerId, ale_server,
                                             [LoggerId, Name,
                                              LogLevel, SyncLogLevel]),
            case RV of
                {ok, _} ->
                    NewState =
                        State#state{loggers=ordsets:add_element(Name, Loggers)},
                    {ok, NewState};
                _Other ->
                    RV
            end
    end.

do_stop_logger(Name, #state{loggers=Loggers} = State) ->
    ensure_logger(
      Name, State,
      fun () ->
            LoggerId = ale_utils:logger_id(Name),
            ok = ale_dynamic_sup:stop_child(LoggerId),
            NewState = State#state{loggers=ordsets:del_element(Name, Loggers)},
            {ok, NewState}
      end).

do_add_sink(LoggerName, SinkName, LogLevel, State) ->
    ensure_logger(
      LoggerName, State,
      fun () ->
              ensure_sink(
                SinkName, State,
                fun () ->
                        LoggerId = ale_utils:logger_id(LoggerName),
                        SinkId = ale_utils:sink_id(SinkName),
                        gen_server:call(LoggerId, {add_sink, SinkId, LogLevel})
                end)
      end).

do_set_loglevel(LoggerName, LogLevel, State) ->
    ensure_logger(
      LoggerName, State,
      fun () ->
              LoggerId = ale_utils:logger_id(LoggerName),
              gen_server:call(LoggerId, {set_loglevel, LogLevel})
      end).

do_get_loglevel(LoggerName, State) ->
    ensure_logger(
      LoggerName, State,
      fun () ->
              LoggerId = ale_utils:logger_id(LoggerName),
              gen_server:call(LoggerId, get_loglevel)
      end).

do_set_sync_loglevel(LoggerName, LogLevel, State) ->
    ensure_logger(
      LoggerName, State,
      fun () ->
              LoggerId = ale_utils:logger_id(LoggerName),
              gen_server:call(LoggerId, {set_sync_loglevel, LogLevel})
      end).

do_get_sync_loglevel(LoggerName, State) ->
    ensure_logger(
      LoggerName, State,
      fun () ->
              LoggerId = ale_utils:logger_id(LoggerName),
              gen_server:call(LoggerId, get_sync_loglevel)
      end).

do_set_sink_loglevel(LoggerName, SinkName, LogLevel, State) ->
    ensure_logger(
      LoggerName, State,
      fun () ->
              ensure_sink(
                SinkName, State,
                fun () ->
                        LoggerId = ale_utils:logger_id(LoggerName),
                        SinkId = ale_utils:sink_id(SinkName),
                        gen_server:call(LoggerId,
                                        {set_sink_loglevel, SinkId, LogLevel})
                end)
      end).

do_get_sink_loglevel(LoggerName, SinkName, State) ->
    ensure_logger(
      LoggerName, State,
      fun () ->
              ensure_sink(
                SinkName, State,
                fun () ->
                        LoggerId = ale_utils:logger_id(LoggerName),
                        SinkId = ale_utils:sink_id(SinkName),
                        gen_server:call(LoggerId,
                                        {get_sink_loglevel, SinkId})
                end)
      end).

set_error_logger_handler() ->
    ok = gen_event:add_sup_handler(error_logger, ale_error_logger_handler,
                                   [?ERROR_LOGGER]).

rearm_timer() ->
    erlang:start_timer(?CHECK_MAILBOXES_INTERVAL, self(), check_mailboxes).
