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
         validate_any_value/3,
         validate_by_fun/3,
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
           end, R0, integer_settings()),
    R2 = validate_loglevel(R1),

    validate_unsupported_params(R2).

validate_loglevel(State) ->
    State1 = validate_any_value(logLevel, State, fun list_to_binary/1),
    validate_by_fun(
      fun (Value) ->
              LogLevels = ["silent", "fatal", "error", "warn", "info",
                           "verbose", "timing", "debug", "trace"],

              case lists:member(binary_to_list(Value), LogLevels) of
                  true ->
                      ok;
                  false ->
                      {error,
                       io_lib:format("logLevel must be one of ~s",
                                     [string:join(LogLevels, ", ")])}
              end
      end, logLevel, State1).

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

integer_settings() ->
    NearInfinity = 1 bsl 64 - 1,
    [{indexerThreads, 1, 1024},
     {memorySnapshotInterval, 1, NearInfinity},
     {stableSnapshotInterval, 1, NearInfinity},
     {maxRollbackPoints, 1, NearInfinity}].

handle_index_status(Req) ->
    {ok, Indexes0, Stale, _} = index_status_keeper:get_indexes(),
    Indexes = [{Props} || Props <- Indexes0],

    Warnings =
        case Stale of
            true ->
                Msg = <<"We are having troubles communicating to the indexer process. "
                        "The information might be stale.">>,
                [Msg];
            false ->
                []
        end,

    reply_json(Req, {[{indexes, Indexes},
                      {warnings, Warnings}]}).
