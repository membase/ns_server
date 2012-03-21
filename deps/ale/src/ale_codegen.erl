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

load_logger(LoggerName, LogLevel, Sinks) ->
    SourceCode = logger(LoggerName, LogLevel, Sinks),
    dynamic_compile:load_from_string(SourceCode).

logger(LoggerName, LogLevel, Sinks) ->
    LoggerNameStr = atom_to_list(LoggerName),
    lists:flatten([header(LoggerNameStr),
                   "\n",
                   exports(),
                   "\n",
                   definitions(LoggerNameStr, LogLevel, Sinks)]).

header(LoggerName) ->
    io_lib:format("-module('~s').~n", [atom_to_list(logger_impl(LoggerName))]).

exports() ->
    [io_lib:format("-export([~p/4, ~p/5, x~p/5, x~p/6]).~n",
                   [LogLevel, LogLevel, LogLevel, LogLevel]) ||
        LogLevel <- ?LOGLEVELS].

definitions(LoggerName, LoggerLogLevel, Sinks) ->
    lists:map(
      fun (LogLevel) ->
              loglevel_definitions(LoggerName, LoggerLogLevel, LogLevel, Sinks)
      end, ?LOGLEVELS).

loglevel_definitions(LoggerName, LoggerLogLevel, LogLevel, Sinks) ->
    EnabledSinks =
        case ale_utils:loglevel_enabled(LogLevel, LoggerLogLevel) of
            false ->
                [];
            true ->
                lists:foldl(
                  fun ({Sink, SinkLogLevel}, Acc) ->
                          case ale_utils:loglevel_enabled(LogLevel, SinkLogLevel) of
                              true ->
                                  [Sink | Acc];
                              false ->
                                  Acc
                          end
                  end, [], Sinks)
        end,

    [generic_loglevel(LoggerName, LogLevel, EnabledSinks),
     "\n",
     loglevel_1(LogLevel),
     loglevel_2(LogLevel),
     "\n",
     xloglevel_1(LogLevel),
     xloglevel_2(LogLevel),
     "\n"].

generic_loglevel(LoggerName, LogLevel, EnabledSinks) ->
    %% inline generated function
    [io_lib:format("-compile({inline, [generic_~p/6]}).~n", [LogLevel]),

     io_lib:format("generic_~p(M, F, L, Data, Fmt, Args) -> ", [LogLevel]),

     case EnabledSinks of
         [] ->
             "";
         _ ->
             io_lib:format(
               "ForcedArgs = ale_utils:force_args(Args),"
               "Info = ale_utils:assemble_info(~s, ~p, M, F, L, Data),",
               [LoggerName, LogLevel])
     end,

     lists:map(
       fun (Sink) ->
               io_lib:format(
                 "ok = gen_server:call('~s', {log, Info, Fmt, ForcedArgs}, infinity),",
                 [Sink])
       end, EnabledSinks),

     "ok.\n"].

loglevel_1(LogLevel) ->
    io_lib:format(
      "~p(M, F, L, Msg) -> "
      "generic_~p(M, F, L, undefined, Msg, []).~n",
      [LogLevel, LogLevel]).

xloglevel_1(LogLevel) ->
    io_lib:format(
      "x~p(M, F, L, Data, Msg) -> "
      "generic_~p(M, F, L, Data, Msg, []).~n",
      [LogLevel, LogLevel]).

loglevel_2(LogLevel) ->
    io_lib:format(
      "~p(M, F, L, Fmt, Args) -> "
      "generic_~p(M, F, L, undefined, Fmt, Args).~n",
      [LogLevel, LogLevel]).

xloglevel_2(LogLevel) ->
    io_lib:format(
      "x~p(M, F, L, Data, Fmt, Args) -> "
      "generic_~p(M, F, L, Data, Fmt, Args).~n",
      [LogLevel, LogLevel]).
