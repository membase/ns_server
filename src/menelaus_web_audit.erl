%% @author Couchbase <info@couchbase.com>
%% @copyright 2018 Couchbase, Inc.
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
%% @doc handlers for audit related REST API's

-module(menelaus_web_audit).

-include("cut.hrl").
-include("ns_common.hrl").

-export([handle_get/1,
         handle_post/1]).

-import(menelaus_util,
        [reply_json/2,
         reply/2,
         validate_has_params/1,
         validate_boolean/2,
         validate_dir/2,
         validate_integer/2,
         validate_range/5,
         validate_range/4,
         validate_by_fun/3,
         validate_any_value/2,
         validate_unsupported_params/1,
         execute_if_validated/4]).

handle_get(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_40(),

    Props = ns_audit_cfg:get_global(),
    Json = lists:map(fun ({K, V}) when is_list(V) ->
                             {K, list_to_binary(V)};
                         (Other) ->
                             Other
                     end, Props),
    reply_json(Req, {Json}).

validators() ->
    [validate_has_params(_),
     validate_boolean(auditdEnabled, _),
     validate_any_value(logPath, _),
     validate_dir(logPath, _),
     validate_integer(rotateInterval, _),
     validate_range(
       rotateInterval, 15*60, 60*60*24*7,
       fun (Name, _Min, _Max) ->
               io_lib:format("The value of ~p must be in range from 15 minutes "
                             "to 7 days", [Name])
       end, _),
     validate_by_fun(
       fun (Value) ->
               case Value rem 60 of
                   0 ->
                       ok;
                   _ ->
                       {error, "Value must not be a fraction of minute"}
               end
       end, rotateInterval, _),
     validate_integer(rotateSize, _),
     validate_range(rotateSize, 0, 500*1024*1024, _),
     validate_unsupported_params(_)].

handle_post(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_40(),

    Args = Req:parse_post(),
    execute_if_validated(fun (Values) ->
                                 ns_audit_cfg:set_global(Values),
                                 reply(Req, 200)
                         end, Req, Args, validators()).
