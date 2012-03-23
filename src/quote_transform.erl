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
%%
-module(quote_transform).

-export([parse_transform/2, simple_bindings/1, internal_mk_lambda/1]).

simple_bindings(Pairs) ->
    lists:foldl(fun ({Atom, Value}, Acc) ->
                        erl_eval:add_binding(Atom, Value, Acc)
                end, erl_eval:new_bindings(), Pairs).

internal_mk_lambda(Expr) ->
    RV = erl_eval:expr(Expr, []),
    {value, Lambda, _} = RV,
    Lambda.

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
                        {atom, _Line2, quote_transform},
                        {atom, _Line3, q}},
           [Argument]}) ->
    String = lists:flatten(io_lib:format("~p.", [Argument])),
    {ok, Terms, _} = erl_scan:string(String, Line),
    {ok, [Expr]} = erl_parse:parse_exprs(Terms),
    Expr;

transform({call, Line, {remote, _Line1,
                        {atom, _Line2, quote_transform},
                        {atom, _Line3, lambda}},
           [Argument]}) ->
    Step = {call, Line, {remote, Line,
                         {atom, Line, quote_transform},
                         {atom, Line, internal_mk_lambda}},
            [{call, Line, {remote, Line,
                           {atom, Line, quote_transform},
                           {atom, Line, q}},
              [Argument]}]},
    %% io:format("Step:~p~n", [Step]),
    RV = transform(Step),
    %% io:format("RV:~p~n", [RV]),
    RV;

transform(Stmt) when is_tuple(Stmt) ->
    list_to_tuple(transform(tuple_to_list(Stmt)));
transform(Stmt) when is_list(Stmt) ->
    [transform(S) || S <- Stmt];
transform(Stmt) ->
    Stmt.
