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
-export([start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { logger_name          :: atom(),
                 loglevel             :: loglevel(),
                 sinks = dict:new()   :: dict(),
                 formatter            :: module(),
                 compiler = undefined :: pid() | undefined}).

start_link(ServerName, LoggerName, LogLevel, Formatter) ->
    gen_server:start_link({local, ServerName},
                          ?MODULE,
                          [LoggerName, LogLevel, Formatter], []).

init([LoggerName, LogLevel, Formatter]) ->
    process_flag(trap_exit, true),

    case valid_loglevel(LogLevel) of
        true ->
            State = #state{logger_name=LoggerName,
                           loglevel=LogLevel,
                           formatter=Formatter},
            compile(State),
            {ok, State};
        false ->
            {stop, badarg}
    end.

handle_call({set_loglevel, Level}, _From, State) ->
    case valid_loglevel(Level) of
        true ->
            case State#state.loglevel of
                Level ->
                    {reply, ok, State};
                _ ->
                    NewState = State#state{loglevel=Level},
                    {reply, ok, spawn_compiler(NewState)}
            end;
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
                    {reply, ok, spawn_compiler(NewState)}
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
                    {reply, ok, spawn_compiler(NewState)}
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

do_compile(#state{logger_name=LoggerName,
                  loglevel=LogLevel,
                  formatter=Formatter,
                  sinks=Sinks}) ->
    SinksList = dict:to_list(Sinks),

    ale_codegen:load_logger(LoggerName, LogLevel, Formatter, SinksList).

kill_compiler(#state{compiler=Compiler}) ->
    case Compiler of
        undefined ->
            ok;
        _ ->
            exit(Compiler, kill),
            receive
                {'EXIT', Compiler, _Reason} ->
                    ok
            end
    end.

compile(State) ->
    kill_compiler(State),
    do_compile(State),
    State.

spawn_compiler(State) ->
    kill_compiler(State),

    NewCompiler = spawn_link(
                   fun () ->
                           do_compile(State)
                   end),

    State#state{compiler=NewCompiler}.

valid_loglevel(LogLevel) ->
    lists:member(LogLevel, ?LOGLEVELS).
