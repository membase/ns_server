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

-module(ale_server).

-behavior(gen_server).

-include("ale.hrl").

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { logger_name          :: atom(),
                 server_name          :: atom(),
                 loglevel             :: loglevel(),
                 sinks = dict:new()   :: dict(),
                 compiler = undefined :: pid() | undefined}).

start_link(ServerName, LoggerName, LogLevel) ->
    gen_server:start_link({local, ServerName},
                          ?MODULE,
                          [ServerName, LoggerName, LogLevel], []).

init([ServerName, LoggerName, LogLevel]) ->
    process_flag(trap_exit, true),

    case valid_loglevel(LogLevel) of
        true ->
            State = #state{logger_name=LoggerName,
                           server_name=ServerName,
                           loglevel=LogLevel},
            compile(State),
            {ok, State};
        false ->
            {stop, badarg}
    end.

handle_call({log, Info, Format, Args}, _From, State) ->
    {reply, do_log(State, Info, Format, Args), State};

handle_call({set_loglevel, Level}, _From, State) ->
    case valid_loglevel(Level) of
        true ->
            NewState = State#state{loglevel=Level},
            {reply, ok, maybe_recompile(State, NewState)};
        false ->
            {reply, {error, badarg}, State}
    end;

handle_call(get_loglevel, _From, #state{loglevel=Level} = State) ->
    {reply, Level, State};

handle_call({add_sink, Name, undefined}, From, State) ->
    handle_call({add_sink, Name, debug}, From, State);

handle_call({add_sink, Name, LogLevel}, _From,
            #state{sinks=Sinks} = State) ->
    case valid_loglevel(LogLevel) of
        true ->
            case dict:find(Name, Sinks) of
                {ok, _} ->
                    {reply, ok, State};
                error ->
                    NewSinks = dict:store(Name, LogLevel, Sinks),
                    NewState = State#state{sinks=NewSinks},
                    {reply, ok, maybe_recompile(State, NewState)}
            end;
        false ->
            {reply, {error, badarg}, State}
    end;

handle_call({set_sink_loglevel, Name, NewLevel}, _From,
            #state{sinks=Sinks} = State) ->
    case valid_loglevel(NewLevel) of
        true ->
            case dict:find(Name, Sinks) of
                error ->
                    {reply, not_found, State};
                {ok, NewLevel} ->
                    {reply, ok, State};
                {ok, _OldLevel} ->
                    NewSinks = dict:store(Name, NewLevel, Sinks),
                    NewState = State#state{sinks=NewSinks},
                    {reply, ok, maybe_recompile(State, NewState)}
            end;
        false ->
            {reply, {error, badarg}, State}
    end;

handle_call({get_sink_loglevel, Name}, _From,
            #state{sinks=Sinks} = State) ->
    case dict:find(Name, Sinks) of
        error ->
            {reply, not_found, State};
        {ok, LogLevel} ->
            {reply, {ok, LogLevel}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, _Reason}, State) ->
    NewState = State#state{compiler=undefined},
    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Auxiliary functions.

effective_loglevel(#state{loglevel=LogLevel, sinks=Sinks} = _State) ->
    Snd = fun ({_, X}) -> X end,

    case dict:size(Sinks) of
        0 ->
            undefined;
        _Other ->
            SinkLevels = lists:map(Snd, dict:to_list(Sinks)),
            MaxSinkLevel = ale_utils:loglevel_max(SinkLevels),
            ale_utils:loglevel_min(LogLevel, MaxSinkLevel)
    end.

needs_recompilation(OldState, NewState) ->
    effective_loglevel(OldState) =/= effective_loglevel(NewState).

maybe_recompile(OldState, NewState) ->
    case needs_recompilation(OldState, NewState) of
        false ->
            NewState;
        true ->
            spawn_compiler(NewState)
    end.

compile(State) ->
    LoggerName = State#state.logger_name,
    ServerName = State#state.server_name,
    LogLevel   = effective_loglevel(State),

    ale_codegen:load_logger(LoggerName, ServerName, LogLevel).

spawn_compiler(#state{compiler=Compiler} = State) ->
    case Compiler of
        undefined ->
            ok;
        _ ->
            exit(Compiler, kill),
            receive
                {'EXIT', Compiler, _Reason} ->
                    ok
            end
    end,

    DoCompile   = fun () -> compile(State) end,
    NewCompiler = spawn_link(DoCompile),

    State#state{compiler=NewCompiler}.

-spec must_be_logged(loglevel(), loglevel()) -> boolean().
must_be_logged(LogLevel, ThresholdLogLevel) ->
    ale_utils:loglevel_min(LogLevel, ThresholdLogLevel) =:= LogLevel.

do_log(#state{sinks=Sinks} = _State,
       #log_info{loglevel=LogLevel} = Info, Format, Args) ->
    MaybeLog = fun (Sink, SinkLogLevel) ->
                       case must_be_logged(LogLevel, SinkLogLevel) of
                           true ->
                               catch gen_server:call(Sink,
                                                     {log, Info, Format, Args}),
                               ok;
                           false ->
                               ok
                       end
               end,
    dict:map(MaybeLog, Sinks),
    ok.

valid_loglevel(LogLevel) ->
    lists:member(LogLevel, ?LOGLEVELS).
