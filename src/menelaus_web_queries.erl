%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
-module(menelaus_web_queries).

-include("ns_common.hrl").
-export([handle_settings_get/1, handle_settings_post/1]).

-import(menelaus_util,
        [reply_json/2,
         assert_is_vulcan/0,
         validate_any_value/3,
         validate_dir/2,
         validate_has_params/1,
         validate_integer/2,
         validate_by_fun/3,
         validate_unsupported_params/1,
         execute_if_validated/3]).

-define(QUERY_TMP_SPACE_MIN_SIZE, 5).

handle_settings_get(Req) ->
    assert_is_vulcan(),

    Config = get_settings(),
    reply_json(Req, {Config}).

get_settings() ->
    query_settings_manager:get(generalSettings).

validate_settings_post(Args) ->
    NearInfinity = 1 bsl 64 - 1,
    R0 = validate_has_params({Args, [], []}),
    R1 = validate_integer(queryTmpSpaceSize, R0),
    R2 = validate_by_fun(fun (Value) ->
                                 case Value >= ?QUERY_TMP_SPACE_MIN_SIZE andalso
                                     Value =< NearInfinity of
                                     true ->
                                         ok;
                                     false ->
                                         case Value =:= 0 orelse
                                             Value =:= -1 of
                                             true ->
                                                 ok;
                                             false ->
                                                 {error, "The value of \"queryTmpSpaceSize\" must be a positive integer >= 5"}
                                         end
                                 end
                         end, queryTmpSpaceSize, R1),
    R3 = validate_any_value(queryTmpSpaceDir, R2, fun list_to_binary/1),
    R4 = validate_dir(queryTmpSpaceDir, R3),
    validate_unsupported_params(R4).

update_settings(Key, Value) ->
    case query_settings_manager:update(Key, Value) of
        {ok, _} ->
            ok;
        retry_needed ->
            erlang:error(exceeded_retries)
    end.

handle_settings_post(Req) ->
    assert_is_vulcan(),

    execute_if_validated(
      fun (Values) ->
              case Values of
                  [] ->
                      ok;
                  _ ->
                      ok = update_settings(generalSettings, Values)
              end,
              reply_json(Req, {get_settings()})
      end, Req, validate_settings_post(Req:parse_post())).
