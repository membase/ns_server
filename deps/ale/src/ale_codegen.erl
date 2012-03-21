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

-module(ale_codegen).

-export([load_logger/3, logger_impl/1, extended_impl/1, logger/3]).

-include("ale.hrl").

logger_impl(Logger) when is_atom(Logger) ->
    logger_impl(atom_to_list(Logger));
logger_impl(Logger) ->
    list_to_atom("ale_logger-" ++ Logger).

extended_impl(LogLevel) ->
    list_to_atom([$x | atom_to_list(LogLevel)]).

load_logger(LoggerName, ServerName, LogLevel) ->
    SourceCode = logger(LoggerName, ServerName, LogLevel),
    dynamic_compile:load_from_string(SourceCode).

logger(LoggerName, ServerName, LogLevel) ->
    LoggerNameStr = atom_to_list(LoggerName),
    ServerNameStr = atom_to_list(ServerName),
    lists:flatten([header(LoggerNameStr),
                   "\n",
                   exports(),
                   "\n",
                   definitions(LoggerNameStr, ServerNameStr, LogLevel)]).

header(LoggerName) ->
    io_lib:format("-module('~s').~n", [atom_to_list(logger_impl(LoggerName))]).

exports() ->
    [io_lib:format("-export([~p/4, ~p/5, x~p/5, x~p/6]).~n",
                   [LogLevel, LogLevel, LogLevel, LogLevel]) ||
        LogLevel <- ?LOGLEVELS].

definitions(LoggerName, ServerName, LogLevel) ->
    {Stubs, Enabled} =
        lists:splitwith(fun (X) ->
                                X =/= LogLevel
                        end, ?LOGLEVELS),

    [stubs(Stubs),
     "\n",
     enabled(LoggerName, ServerName, Enabled)].

stubs(Stubs) ->
    [stubs_1(Stubs),
     xstubs_1(Stubs),
     "\n",
     stubs_2(Stubs),
     xstubs_2(Stubs)].

stubs_1(Stubs) ->
    [io_lib:format("~p(_, _, _, _) -> ok.~n", [LogLevel]) ||
        LogLevel <- Stubs].

xstubs_1(Stubs) ->
    [io_lib:format("x~p(_, _, _, _, _) -> ok.~n", [LogLevel]) ||
        LogLevel <- Stubs].

stubs_2(Stubs) ->
    [io_lib:format("~p(_, _, _, _, _) -> ok.~n", [LogLevel]) ||
        LogLevel <- Stubs].

xstubs_2(Stubs) ->
    [io_lib:format("x~p(_, _, _, _, _, _) -> ok.~n", [LogLevel]) ||
        LogLevel <- Stubs].

enabled(LoggerName, ServerName, Enabled) ->
    [enabled_1(LoggerName, ServerName, Enabled),
     xenabled_1(LoggerName, ServerName, Enabled),
     "\n",
     enabled_2(LoggerName, ServerName, Enabled),
     xenabled_2(LoggerName, ServerName, Enabled)].

enabled_1(LoggerName, ServerName, Enabled) ->
    MkEnabled1 =
        fun (LogLevel) ->
                io_lib:format(
                  "~p(M, F, L, Msg) -> "
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L),"
                  "gen_server:call('~s', {log, Info, Msg, []}, infinity).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:map(MkEnabled1, Enabled).

xenabled_1(LoggerName, ServerName, Enabled) ->
    MkXEnabled1 =
        fun (LogLevel) ->
                io_lib:format(
                  "x~p(M, F, L, Data, Msg) -> "
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L, Data),"
                  "gen_server:call('~s', {log, Info, Msg, []}, infinity).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:map(MkXEnabled1, Enabled).

enabled_2(LoggerName, ServerName, Enabled) ->
    MkEnabled2 =
        fun (LogLevel) ->
                io_lib:format(
                  "~p(M, F, L, Fmt, Args) -> "
                  "ForcedArgs = ale_utils:force_args(Args),"
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L),"
                  "gen_server:call('~s', {log, Info, Fmt, ForcedArgs}, infinity).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:map(MkEnabled2, Enabled).

xenabled_2(LoggerName, ServerName, Enabled) ->
    MkXEnabled2 =
        fun (LogLevel) ->
                io_lib:format(
                  "x~p(M, F, L, Data, Fmt, Args) -> "
                  "ForcedArgs = ale_utils:force_args(Args),"
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L, Data),"
                  "gen_server:call('~s', {log, Info, Fmt, ForcedArgs}, infinity).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:map(MkXEnabled2, Enabled).
