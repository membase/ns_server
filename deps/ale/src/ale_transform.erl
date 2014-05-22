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

%% This module partially stolen from lager.

-module(ale_transform).

-include("ale.hrl").

-export([parse_transform/2]).

parse_transform(AST, _Options) ->
    walk_ast([], AST).

walk_ast(Acc, []) ->
    lists:reverse(Acc);
walk_ast(Acc, [{attribute, _, module, {Module, _PmodArgs}}=H|T]) ->
    put(module, Module),
    walk_ast([H|Acc], T);
walk_ast(Acc, [{attribute, _, module, Module}=H|T]) ->
    put(module, Module),
    walk_ast([H|Acc], T);
walk_ast(Acc, [{function, Line, Name, Arity, Clauses}|T]) ->
    put(function, Name),
    walk_ast([{function, Line, Name, Arity,
               walk_clauses([], Clauses)}|Acc], T);
walk_ast(Acc, [H|T]) ->
    walk_ast([H|Acc], T).

walk_clauses(Acc, []) ->
    lists:reverse(Acc);
walk_clauses(Acc, [{clause, Line, Arguments, Guards, Body}|T]) ->
    walk_clauses([{clause, Line, Arguments, Guards,
                   walk_body([], Body)}|Acc], T).

walk_body(Acc, []) ->
    lists:reverse(Acc);
walk_body(Acc, [H|T]) ->
    walk_body([transform(H) | Acc], T).

transform({call, Line, {remote, _Line1,
                        {atom, _Line2, ale},
                        {atom, _Line3, Fn}},
           [LoggerExpr]})
  when Fn =:= sync;
       Fn =:= get_effective_loglevel ->
    {call, Line,
     {remote, Line,
      logger_impl_expr(LoggerExpr), {atom, Line, Fn}}, []};
transform({call, Line, {remote, _Line1,
                        {atom, _Line2, ale},
                        {atom, _Line3, Fn}},
           [LoggerExpr, LogLevelExpr]} = Stmt)
  when Fn =:= is_loglevel_enabled ->
    case valid_loglevel_expr(LogLevelExpr) of
        true ->
            {call, Line,
             {remote, Line,
              logger_impl_expr(LoggerExpr), {atom, Line, Fn}}, [LogLevelExpr]};
        false ->
            Stmt
    end;
transform({call, Line, {remote, Line1,
                        {atom, Line2, ale},
                        {atom, Line3, LogFn}},
           [LoggerExpr, LogLevelExpr | Args]} = Stmt)
  when LogFn =:= log; LogFn =:= xlog ->
    Extended = LogFn =:= xlog,

    case valid_loglevel_expr(LogLevelExpr) andalso
        valid_args(Extended, Args) of
        true ->
            Line4 = get_line(LoggerExpr),
            LogLevelExpr1 =
                case Extended of
                    false ->
                        LogLevelExpr;
                    true ->
                        extended_loglevel_expr(LogLevelExpr)
                end,

            emit_dynamic_logger_call(LoggerExpr, LogLevelExpr1, Args,
                                     Line, Line1, Line2, Line3, Line4);
        false ->
            Stmt
    end;
transform({call, Line, {remote, Line1,
                        {atom, Line2, ale},
                        {atom, Line3, LogLevel}},
           [Arg | Args]} = Stmt) ->
    case valid_loglevel(LogLevel) andalso
        valid_args(extended_loglevel(LogLevel), Args) of
        true ->
            case Arg of
                {atom, Line4, LoggerName} ->
                    emit_logger_call(LoggerName, LogLevel, Args,
                                     Line, Line1, Line2, Line3, Line4);
                _Other ->
                    Stmt
            end;
        false ->
            Stmt
    end;
transform(Stmt) when is_tuple(Stmt) ->
    list_to_tuple(transform(tuple_to_list(Stmt)));
transform(Stmt) when is_list(Stmt) ->
    [transform(S) || S <- Stmt];
transform(Stmt) ->
    Stmt.

do_emit_logger_call(LoggerName, LogLevelExpr, Args,
                    CallLine, RemoteLine, ModLine, ArgLine) ->
    {call, CallLine,
     {remote, RemoteLine,
      {atom, ModLine, ale_codegen:logger_impl(LoggerName)},
      LogLevelExpr},
     [{atom, ArgLine, get(module)},
      {atom, ArgLine, get(function)},
      {integer, ArgLine, CallLine} |
      Args]}.

emit_logger_call(LoggerName, LogLevel, Args,
                 CallLine, RemoteLine, ModLine, FnLine, ArgLine) ->
    do_emit_logger_call(LoggerName, {atom, FnLine, LogLevel}, Args,
                        CallLine, RemoteLine, ModLine, ArgLine).

emit_dynamic_logger_call(LoggerNameExpr, LogLevelExpr, Args,
                         CallLine, RemoteLine, ModLine, FnLine, ArgLine) ->
    {call, CallLine,
     {remote, RemoteLine,
      {atom, ModLine, erlang},
      {atom, FnLine, apply}},
     [logger_impl_expr(LoggerNameExpr),
      LogLevelExpr,
      {cons, ArgLine,
       {atom, ArgLine, get(module)},
       {cons, ArgLine,
        {atom, ArgLine, get(function)},
        {cons, ArgLine,
         {integer, ArgLine, CallLine},
         list_to_ast_list(ArgLine, Args)}}}]}.

list_to_ast_list(Line, []) ->
    {nil, Line};
list_to_ast_list(Line, [H | T]) ->
    {cons, Line, H, list_to_ast_list(Line, T)}.

extended_loglevel_expr_rt(Line, Expr) ->
    {call, Line,
     {remote, Line,
      {atom, Line, ale_codegen},
      {atom, Line, extended_impl}},
     [Expr]}.

extended_loglevel_expr({atom, Line, LogLevel}) ->
    {atom, Line, ale_codegen:extended_impl(LogLevel)};
extended_loglevel_expr({var, Line, _} = Expr) ->
    extended_loglevel_expr_rt(Line, Expr);
extended_loglevel_expr({call, Line, _, _} = Expr) ->
    extended_loglevel_expr_rt(Line, Expr).

extended_loglevel(LogLevel) ->
    ExtendedLogLevels = [list_to_atom([$x | atom_to_list(LL)])
                         || LL <- ?LOGLEVELS],
    lists:member(LogLevel, ExtendedLogLevels).

normalize_loglevel(LogLevel) ->
    case extended_loglevel(LogLevel) of
        false ->
            LogLevel;
        true ->
            LogLevelStr = atom_to_list(LogLevel),
            [$x | LogLevelStr1] = LogLevelStr,
            list_to_atom(LogLevelStr1)
    end.

valid_loglevel(LogLevel) ->
    NormLogLevel = normalize_loglevel(LogLevel),
    lists:member(NormLogLevel, ?LOGLEVELS).

valid_loglevel_expr({atom, _Line, LogLevel}) ->
    lists:member(LogLevel, ?LOGLEVELS);
valid_loglevel_expr(_Other) ->
    true.

get_line(Expr) ->
    element(2, Expr).

valid_args(ExtendedCall, Args) ->
    N = length(Args),

    case ExtendedCall of
        false ->
            N =:= 1 orelse N =:= 2;
        true ->
            N =:= 2 orelse N =:= 3
    end.

logger_impl_expr(LoggerExpr) ->
    Line = get_line(LoggerExpr),

    case LoggerExpr of
        {atom, _, LoggerAtom} ->
            {atom, Line, ale_codegen:logger_impl(LoggerAtom)};
        _ ->
            {call, Line,
             {remote, Line,
              {atom, Line, ale_codegen},
              {atom, Line, logger_impl}},
             [LoggerExpr]}
    end.
