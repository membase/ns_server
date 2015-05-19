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
-module(menelaus_web_indexes).

-export([handle_settings_get/1, handle_settings_post/1, handle_index_status/1]).

-import(menelaus_util,
        [reply/2,
         reply_json/2,
         validate_has_params/1,
         validate_unsupported_params/1,
         validate_integer/2,
         validate_range/4,
         execute_if_validated/3]).

handle_settings_get(Req) ->
    menelaus_web:assert_is_sherlock(),

    Settings = index_settings_manager:get(generalSettings),
    true = (Settings =/= undefined),

    reply_json(Req, {Settings}).

validate_settings_post(Args) ->
    R0 = validate_has_params({Args, [], []}),
    R1 = lists:foldl(
           fun ({Key, Min, Max}, Acc) ->
                   Acc1 = validate_integer(Key, Acc),
                   validate_range(Key, Min, Max, Acc1)
           end, R0, supported_settings()),

    validate_unsupported_params(R1).

handle_settings_post(Req) ->
    menelaus_web:assert_is_sherlock(),

    execute_if_validated(
      fun (Values) ->
              case index_settings_manager:update(generalSettings, Values) of
                  {ok, NewSettingsAll} ->
                      {_, NewSettings} = lists:keyfind(generalSettings, 1, NewSettingsAll),
                      reply_json(Req, {NewSettings});
                  retry_needed ->
                      reply(Req, 409)
              end
      end, Req, validate_settings_post(Req:parse_post())).

supported_settings() ->
    NearInfinity = 1 bsl 64 - 1,
    [{indexerThreads, 1, 1024},
     {memorySnapshotInterval, 1, NearInfinity},
     {stableSnapshotInterval, 1, NearInfinity},
     {maxRollbackPoints, 1, NearInfinity}].

handle_index_status(Req) ->
    {ok, Indexes0} = index_status_keeper:get_indexes(),
    Indexes = [{Props} || Props <- Indexes0],

    reply_json(Req, Indexes).
