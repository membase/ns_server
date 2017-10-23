%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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
-module(functools).

-compile(export_all).

%% Identity function.
id(X) ->
    X.

%% Create a function of one argument that always returns the constant
%% passed.
const(Value) ->
    fun (_) -> Value end.

%% Compose two functions. Note that the order of the function is
%% reversed to what it normally is in such functions.
compose(First, Second) ->
    compose([First, Second]).

%% Compose many functions.
compose(Funs) when is_list(Funs) ->
    fun (X) ->
            lists:foldl(fun (F, Acc) ->
                                F(Acc)
                        end, X, Funs)
    end.

%% Compose many functions and apply the resulting function to 'X'
chain(X, Funs) ->
    (compose(Funs))(X).

%% Curry a function.
curry(F) ->
    fun (X) ->
            fun (Y) ->
                    F(X, Y)
            end
    end.

%% Uncurry a function.
uncurry(F) ->
    fun (X, Y) ->
            (F(X))(Y)
    end.

%% some partially applied built-in operations
add(Y) ->
    fun (X) -> X + Y end.

sub(Y) ->
    fun (X) -> X - Y end.

mul(Y) ->
    fun (X) -> X * Y end.

idiv(Y) ->
    fun (X) -> X div Y end.

%% first-class versions of some built-in operations
add(X, Y) ->
    X + Y.

sub(X, Y) ->
    X - Y.

mul(X, Y) ->
    X * Y.

idiv(X, Y) ->
    X div Y.
