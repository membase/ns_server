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

-export([load_logger/4, logger_impl/1, extended_impl/1, logger/4]).

-include("ale.hrl").

logger_impl(Logger) when is_atom(Logger) ->
    logger_impl(atom_to_list(Logger));
logger_impl(Logger) ->
    list_to_atom("ale_logger-" ++ Logger).

extended_impl(LogLevel) ->
    list_to_atom([$x | atom_to_list(LogLevel)]).

load_logger(LoggerName, ServerName, LogLevel, SyncLevel) ->
    SourceCode = logger(LoggerName, ServerName, LogLevel, SyncLevel),
    dynamic_compile:load_from_string(SourceCode).

logger(LoggerName, ServerName, LogLevel, SyncLevel) ->
    LoggerNameStr = atom_to_list(LoggerName),
    ServerNameStr = atom_to_list(ServerName),
    lists:flatten([header(LoggerNameStr),
                   "\n",
                   exports(),
                   "\n",
                   definitions(LoggerNameStr, ServerNameStr,
                               LogLevel, SyncLevel)]).

header(LoggerName) ->
    io_lib:format("-module('~s').~n", [atom_to_list(logger_impl(LoggerName))]).

exports() ->
    lists:flatten(
      [io_lib:format("-export([~p/4, ~p/5, x~p/5, x~p/6]).~n",
                     [LogLevel, LogLevel, LogLevel, LogLevel]) ||
          LogLevel <- ?LOGLEVELS]).

definitions(LoggerName, ServerName, LogLevel, SyncLogLevel) ->
    {Stubs, Enabled} = lists:splitwith(fun (X) -> X =/= LogLevel end,
                                       ?LOGLEVELS),

    SyncLogLevel1 = ale_utils:loglevel_min(LogLevel, SyncLogLevel),
    {Async, Sync} = lists:splitwith(fun (X) -> X =/= SyncLogLevel1 end,
                                    Enabled),

    lists:flatten([stubs(Stubs),
                   "\n",
                   async(LoggerName, ServerName, Async),
                   "\n",
                   sync(LoggerName, ServerName, Sync)]).

stubs(Stubs) ->
    lists:flatten([stubs_1(Stubs),
                   xstubs_1(Stubs),
                   "\n",
                   stubs_2(Stubs),
                   xstubs_2(Stubs)]).

stubs_1(Stubs) ->
    lists:flatten(
      [io_lib:format("~p(_, _, _, _) -> ok.~n", [LogLevel]) ||
          LogLevel <- Stubs]).

xstubs_1(Stubs) ->
    lists:flatten(
      [io_lib:format("x~p(_, _, _, _, _) -> ok.~n", [LogLevel]) ||
          LogLevel <- Stubs]).

stubs_2(Stubs) ->
    lists:flatten(
      [io_lib:format("~p(_, _, _, _, _) -> ok.~n", [LogLevel]) ||
          LogLevel <- Stubs]).

xstubs_2(Stubs) ->
    lists:flatten(
      [io_lib:format("x~p(_, _, _, _, _, _) -> ok.~n", [LogLevel]) ||
          LogLevel <- Stubs]).

async(LoggerName, ServerName, Async) ->
    lists:flatten([async_1(LoggerName, ServerName, Async),
                   xasync_1(LoggerName, ServerName, Async),
                   "\n",
                   async_2(LoggerName, ServerName, Async),
                   xasync_2(LoggerName, ServerName, Async)]).

async_1(LoggerName, ServerName, Async) ->
    MkAsync1 =
        fun (LogLevel) ->
                io_lib:format(
                  "~p(M, F, L, Msg) -> "
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L),"
                  "gen_server:cast('~s', {log, Info, Msg, []}).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:flatten(lists:map(MkAsync1, Async)).

xasync_1(LoggerName, ServerName, Async) ->
    MkXAsync1 =
        fun (LogLevel) ->
                io_lib:format(
                  "x~p(M, F, L, Data, Msg) -> "
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L, Data),"
                  "gen_server:cast('~s', {log, Info, Msg, []}).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:flatten(lists:map(MkXAsync1, Async)).

async_2(LoggerName, ServerName, Async) ->
    MkAsync2 =
        fun (LogLevel) ->
                io_lib:format(
                  "~p(M, F, L, Fmt, Args) -> "
                  "ForcedArgs = ale_utils:force_args(Args),"
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L),"
                  "gen_server:cast('~s', {log, Info, Fmt, ForcedArgs}).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:flatten(lists:map(MkAsync2, Async)).

xasync_2(LoggerName, ServerName, Async) ->
    MkXAsync2 =
        fun (LogLevel) ->
                io_lib:format(
                  "x~p(M, F, L, Data, Fmt, Args) -> "
                  "ForcedArgs = ale_utils:force_args(Args),"
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L, Data),"
                  "gen_server:cast('~s', {log, Info, Fmt, ForcedArgs}).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:flatten(lists:map(MkXAsync2, Async)).

sync(LoggerName, ServerName, Sync) ->
    lists:flatten([sync_1(LoggerName, ServerName, Sync),
                   xsync_1(LoggerName, ServerName, Sync),
                   "\n",
                   sync_2(LoggerName, ServerName, Sync),
                   xsync_2(LoggerName, ServerName, Sync)]).

sync_1(LoggerName, ServerName, Sync) ->
    MkSync1 =
        fun (LogLevel) ->
                io_lib:format(
                  "~p(M, F, L, Msg) -> "
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L),"
                  "gen_server:call('~s', {log, Info, Msg, []}).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:flatten(lists:map(MkSync1, Sync)).

xsync_1(LoggerName, ServerName, Sync) ->
    MkXSync1 =
        fun (LogLevel) ->
                io_lib:format(
                  "x~p(M, F, L, Data, Msg) -> "
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L, Data),"
                  "gen_server:call('~s', {log, Info, Msg, []}).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:flatten(lists:map(MkXSync1, Sync)).

sync_2(LoggerName, ServerName, Sync) ->
    MkSync2 =
        fun (LogLevel) ->
                io_lib:format(
                  "~p(M, F, L, Fmt, Args) -> "
                  "ForcedArgs = ale_utils:force_args(Args),"
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L),"
                  "gen_server:call('~s', {log, Info, Fmt, ForcedArgs}).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:flatten(lists:map(MkSync2, Sync)).

xsync_2(LoggerName, ServerName, Sync) ->
    MkXSync2 =
        fun (LogLevel) ->
                io_lib:format(
                  "x~p(M, F, L, Data, Fmt, Args) -> "
                  "ForcedArgs = ale_utils:force_args(Args),"
                  "Info = ale_utils:assemble_info(~s, ~p, M, F, L, Data),"
                  "gen_server:call('~s', {log, Info, Fmt, ForcedArgs}).~n",
                  [LogLevel, LoggerName, LogLevel, ServerName])
        end,
    lists:flatten(lists:map(MkXSync2, Sync)).
