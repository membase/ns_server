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
-module(quote_transform_test).

-compile([{parse_transform, quote_transform}]).

-include_lib("eunit/include/eunit.hrl").

q_test() ->
    Q = quote_transform:q(fun (B) ->
                                  A + B
                          end),
    {value, Lambda, _} = erl_eval:exprs([Q], quote_transform:simple_bindings([{'A', 42}])),
    true = is_function(Lambda),
    ?assertEqual(40, Lambda(-2)).

lambda_test() ->
    true = is_function(quote_transform:lambda(fun () -> ok end)),

    Lambda = (quote_transform:lambda(
                fun (A) ->
                        fun (B) -> A + B end
                end))(42),
    true = is_function(Lambda),
    ?assertEqual(40, Lambda(-2)).
