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
         start_sink/3, start_sink/4, stop_sink/1,
         start_logger/1, start_logger/2,
         stop_logger/1,
         add_sink/2, add_sink/3,
         set_loglevel/2, get_loglevel/1,
         set_sink_loglevel/3, get_sink_loglevel/2,
         sync_changes/1]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-compile({parse_transform, ale_transform}).

-include("ale.hrl").

-record(state, {sinks             :: dict(),
                mailbox_len_limit :: integer(),

                loggers   :: dict(),
                compilers :: dict(),
                compiler_sync_waiters = []}).

-record(logger, {name      :: atom(),
                 loglevel  :: loglevel(),
                 sinks     :: dict(),
                 compiler  :: undefined | pid(),
                 formatter :: module()}).

-record(sink, {name     :: atom(),
               loglevel :: loglevel()}).

-define(CHECK_MAILBOXES_INTERVAL, 3000).
-define(MAILBOX_LENGTH_LIMIT, 100000).

%% API

start_link() ->
    start_link(?MAILBOX_LENGTH_LIMIT).

start_link(MailboxLenLimit) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [MailboxLenLimit], []).

start_sink(Name, Module, Args) ->
    start_sink(Name, ?DEFAULT_SINK_TYPE, Module, Args).

start_sink(Name, Type, Module, Args) ->
    gen_server:call(?MODULE, {start_sink, Name, Type, Module, Args}).

stop_sink(Name) ->
    gen_server:call(?MODULE, {stop_sink, Name}).

start_logger(Name) ->
    start_logger(Name, ?DEFAULT_LOGLEVEL).

start_logger(Name, LogLevel) ->
    start_logger(Name, LogLevel, ?DEFAULT_FORMATTER).

start_logger(Name, LogLevel, Formatter) ->
    gen_server:call(?MODULE, {start_logger, Name, LogLevel, Formatter}).

stop_logger(Name) ->
    gen_server:call(?MODULE, {stop_logger, Name}).

add_sink(LoggerName, SinkName) ->
    add_sink(LoggerName, SinkName, debug).

add_sink(LoggerName, SinkName, LogLevel) ->
    gen_server:call(?MODULE, {add_sink, LoggerName, SinkName, LogLevel}).

set_loglevel(LoggerName, LogLevel) ->
    gen_server:call(?MODULE, {set_loglevel, LoggerName, LogLevel}).

get_loglevel(LoggerName) ->
    gen_server:call(?MODULE, {get_loglevel, LoggerName}).

set_sink_loglevel(LoggerName, SinkName, LogLevel) ->
    gen_server:call(?MODULE,
                    {set_sink_loglevel, LoggerName, SinkName, LogLevel}).

get_sink_loglevel(LoggerName, SinkName) ->
    gen_server:call(?MODULE, {get_sink_loglevel, LoggerName, SinkName}).

sync_changes(Timeout) ->
    gen_server:call(?MODULE, sync_compilers, Timeout).

%% Callbacks
init([MailboxLenLimit]) ->
    process_flag(trap_exit, true),

    State = #state{sinks=dict:new(),
                   mailbox_len_limit=MailboxLenLimit,
                   loggers=dict:new(),
                   compilers=dict:new()},

    {ok, State1} = do_start_logger(?ERROR_LOGGER,
                                   ?DEFAULT_LOGLEVEL, ?DEFAULT_FORMATTER, State),
    {ok, State2} = do_start_logger(?ALE_LOGGER,
                                   ?DEFAULT_LOGLEVEL, ?DEFAULT_FORMATTER, State1),

    set_error_logger_handler(),
    rearm_timer(),

    {ok, State2}.

handle_call(sync_compilers, From, #state{compilers = Compilers, compiler_sync_waiters = Waiters} = State) ->
    case dict:size(Compilers) =:= 0 of
        true ->
            [] = Waiters,
            {reply, ok, State};
        false ->
            {noreply, State#state{compiler_sync_waiters = [From | Waiters]}}
    end;
handle_call({start_sink, Name, Type, Module, Args}, _From, State) ->
    RV = do_start_sink(Name, Type, Module, Args, State),
    handle_result(RV, State);

handle_call({stop_sink, Name}, _From, State) ->
    RV = do_stop_sink(Name, State),
    handle_result(RV, State);

handle_call({start_logger, Name, LogLevel, Formatter}, _From, State) ->
    RV = do_start_logger(Name, LogLevel, Formatter, State),
    handle_result(RV, State);

handle_call({stop_logger, Name}, _From, State) ->
    RV = do_stop_logger(Name, State),
    handle_result(RV, State);

handle_call({add_sink, LoggerName, SinkName, LogLevel},
            _From, State) ->
    RV = do_add_sink(LoggerName, SinkName, LogLevel, State),
    handle_result(RV, State);

handle_call({set_loglevel, LoggerName, LogLevel}, _From, State) ->
    RV = do_set_loglevel(LoggerName, LogLevel, State),
    handle_result(RV, State);

handle_call({get_loglevel, LoggerName}, _From, State) ->
    RV = do_get_loglevel(LoggerName, State),
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
        fun (SinkName, _SinkType, Acc) ->
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
                end,

                Acc
        end,

    ok = dict:fold(Fn, ok, Sinks),

    rearm_timer(),
    {noreply, State};

handle_info({'EXIT', Pid, Reason},
            #state{compilers=Compilers, loggers=Loggers} = State) ->
    case dict:find(Pid, Compilers) of
        {ok, LoggerName} ->
                case Reason of
                    normal ->
                        NewCompilers = dict:erase(Pid, Compilers),
                        NewLoggers =
                            dict:update(
                              LoggerName,
                              fun (#logger{compiler=Compiler} = Logger)
                                  when Compiler =:= Pid ->
                                      Logger#logger{compiler=undefined}
                              end, Loggers),
                        NewState = State#state{compilers=NewCompilers,
                                               loggers=NewLoggers},
                        NewState2 = case dict:size(NewCompilers) =:= 0 of
                                        true ->
                                            [gen_server:reply(F, ok)
                                             || F <- NewState#state.compiler_sync_waiters],
                                            NewState#state{compiler_sync_waiters = []};
                                        false ->
                                            NewState
                                    end,
                        {noreply, NewState2};
                    _ ->
                        %% should not happen
                        ale:error(?ALE_LOGGER,
                                  "Compiler ~p for ~p terminated "
                                  "with non-normal reason ~p",
                                  [Pid, LoggerName, Reason]),
                        {stop, {compiler_died, Reason}}
                end;
        %% `compile' module spawn_link's processes; so we have to ignore them.
        error ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ensure_sink(SinkName, #state{sinks=Sinks} = _State, Fn) ->
    case dict:find(SinkName, Sinks) of
        {ok, _} ->
            Fn();
        error ->
            {error, unknown_sink}
    end.

ensure_logger(LoggerName, #state{loggers=Loggers} = _State, Fn) ->
    case dict:find(LoggerName, Loggers) of
        {ok, Logger} ->
            Fn(Logger);
        error ->
            {error, unknown_logger}
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

do_start_sink(Name, Type, Module, Args, #state{sinks=Sinks} = State) ->
    case dict:find(Name, Sinks) of
        {ok, _} ->
            {error, duplicate_sink};
        error ->
            SinkId = ale_utils:sink_id(Name),
            Args1 = [SinkId | Args],

            RV = ale_dynamic_sup:start_child(SinkId, Module, Args1),
            case RV of
                {ok, _} ->
                    NewSinks = dict:store(Name, Type, Sinks),
                    NewState = State#state{sinks=NewSinks},
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
              NewSinks = dict:erase(Name, Sinks),
              NewState = State#state{sinks=NewSinks},
              {ok, NewState}
      end).

do_start_logger(Name, LogLevel, Formatter, State) ->
    case is_valid_loglevel(LogLevel) of
        true ->
            do_start_logger_tail(Name, LogLevel, Formatter, State);
        false ->
            {error, badarg}
    end.

do_start_logger_tail(Name, LogLevel, Formatter,
                     #state{loggers=Loggers} = State) ->
    case dict:find(Name, Loggers) of
        {ok, _Logger} ->
            {error, duplicate_logger};
        error ->
            Logger = #logger{name=Name,
                             loglevel=LogLevel,
                             sinks=dict:new(),
                             formatter=Formatter,
                             compiler=undefined},
            {State1, Logger1} = compile(State, Logger),

            State2 = store_logger(Name, Logger1, State1),

            {ok, State2}
    end.

do_stop_logger(Name, #state{loggers=Loggers} = State) ->
    ensure_logger(
      Name, State,
      fun (Logger) ->
              {State1, _Logger1} = kill_compiler(State, Logger),
              NewLoggers = dict:erase(Name, Loggers),
              State2 = State1#state{loggers=NewLoggers},
              {ok, State2}
      end).

do_add_sink(LoggerName, SinkName, LogLevel, State) ->
    case is_valid_loglevel(LogLevel) of
        true ->
            do_add_sink_tail(LoggerName, SinkName, LogLevel, State);
        false ->
            {error, badarg}
    end.

do_add_sink_tail(LoggerName, SinkName, LogLevel, State) ->
    ensure_logger(
      LoggerName, State,
      fun (#logger{sinks=Sinks} = Logger) ->
              ensure_sink(
                SinkName, State,
                fun () ->
                        Sink = #sink{name=SinkName,
                                     loglevel=LogLevel},

                        NewSinks = dict:store(SinkName, Sink, Sinks),
                        NewLogger = Logger#logger{sinks=NewSinks},
                        NewState = spawn_compiler_and_store(State, NewLogger),

                        {ok, NewState}
                end)
      end).

do_set_loglevel(LoggerName, LogLevel, State) ->
    case is_valid_loglevel(LogLevel) of
        true ->
            do_set_loglevel_tail(LoggerName, LogLevel, State);
        false ->
            {error, badarg}
    end.

do_set_loglevel_tail(LoggerName, LogLevel, State) ->
    ensure_logger(
      LoggerName, State,
      fun (#logger{loglevel=CurrentLogLevel} = Logger) ->
              case LogLevel of
                  CurrentLogLevel ->
                      {ok, State};
                  _ ->
                      NewLogger = Logger#logger{loglevel=LogLevel},
                      NewState = spawn_compiler_and_store(State, NewLogger),

                      {ok, NewState}
              end
      end).

do_get_loglevel(LoggerName, State) ->
    ensure_logger(
      LoggerName, State,
      fun (#logger{loglevel=LogLevel}) ->
              LogLevel
      end).

do_set_sink_loglevel(LoggerName, SinkName, LogLevel, State) ->
    case is_valid_loglevel(LogLevel) of
        true ->
            do_set_sink_loglevel_tail(LoggerName, SinkName, LogLevel, State);
        false ->
            {error, badarg}
    end.

do_set_sink_loglevel_tail(LoggerName, SinkName, LogLevel, State) ->
    ensure_logger(
      LoggerName, State,
      fun (#logger{sinks=Sinks} = Logger) ->
              ensure_sink(
                SinkName, State,
                fun () ->
                        case dict:find(SinkName, Sinks) of
                            {ok, #sink{loglevel=LogLevel}} ->   % bound above
                                {ok, State};
                            {ok, Sink} ->
                                NewSink = Sink#sink{loglevel=LogLevel},

                                NewSinks = dict:store(SinkName, NewSink, Sinks),
                                NewLogger = Logger#logger{sinks=NewSinks},
                                NewState = spawn_compiler_and_store(State, NewLogger),
                                {ok, NewState};
                            error ->
                                {error, bad_sink}
                        end
                end)
      end).

do_get_sink_loglevel(LoggerName, SinkName, State) ->
    ensure_logger(
      LoggerName, State,
      fun (#logger{sinks=Sinks}) ->
              ensure_sink(
                SinkName, State,
                fun () ->
                        case dict:find(SinkName, Sinks) of
                            {ok, #sink{loglevel=LogLevel}} ->
                                LogLevel;
                            error ->
                                {error, bad_sink}
                        end
                end)
      end).

set_error_logger_handler() ->
    ok = gen_event:add_sup_handler(error_logger, ale_error_logger_handler,
                                   [?ERROR_LOGGER]).

rearm_timer() ->
    erlang:start_timer(?CHECK_MAILBOXES_INTERVAL, self(), check_mailboxes).

do_compile(#state{sinks=SinkTypes},
           #logger{name=LoggerName,
                   loglevel=LogLevel,
                   formatter=Formatter,
                   sinks=Sinks}) ->
    SinksList =
        dict:fold(
          fun (SinkName,
               #sink{name=SinkName, loglevel=SinkLogLevel},
               Acc) ->
                  SinkId = ale_utils:sink_id(SinkName),
                  {ok, SinkType} = dict:find(SinkName, SinkTypes),
                  [{SinkId, SinkLogLevel, SinkType} | Acc]
          end, [], Sinks),

    ale_codegen:load_logger(LoggerName, LogLevel, Formatter, SinksList).

kill_compiler(#state{compilers=Compilers} = State,
              #logger{compiler=CompilerPid} = Logger) ->
    case CompilerPid of
        undefined ->
            {State, Logger};
        _ ->
            exit(CompilerPid, kill),
            receive
                {'EXIT', CompilerPid, _Reason} ->
                    ok
            end,
            NewCompilers = dict:erase(CompilerPid, Compilers),
            NewState     = State#state{compilers=NewCompilers},
            NewLogger    = Logger#logger{compiler=undefined},
            {NewState, NewLogger}
    end.

compile(State, Logger) ->
    {State1, Logger1} = kill_compiler(State, Logger),
    do_compile(State1, Logger1),
    {State1, Logger1}.

spawn_compiler(State, #logger{name=LoggerName} = Logger) ->
    {State1, Logger1} = kill_compiler(State, Logger),

    NewCompiler = proc_lib:spawn_link(
                   fun () ->
                           do_compile(State1, Logger1)
                   end),
    NewCompilers = dict:store(NewCompiler, LoggerName, State1#state.compilers),

    Logger2 = Logger1#logger{compiler=NewCompiler},
    State2  = State1#state{compilers=NewCompilers},

    {State2, Logger2}.

spawn_compiler_and_store(State, #logger{name=LoggerName} = Logger) ->
    {State1, Logger1} = spawn_compiler(State, Logger),
    store_logger(LoggerName, Logger1, State1).

store_logger(LoggerName, #logger{name=LoggerName} = Logger,
             #state{loggers=Loggers} = State) ->
    NewLoggers = dict:store(LoggerName, Logger, Loggers),
    State#state{loggers=NewLoggers}.

is_valid_loglevel(LogLevel) ->
    lists:member(LogLevel, ?LOGLEVELS).
