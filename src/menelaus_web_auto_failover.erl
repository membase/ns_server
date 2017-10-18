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
-module(menelaus_web_auto_failover).

-include("ns_common.hrl").

-export([handle_settings_get/1,
         handle_settings_post/1,
         handle_settings_reset_count/1]).

-import(menelaus_util,
        [reply/2,
         reply_json/2,
         reply_json/3,
         reply_text/3,
         is_valid_positive_integer/1,
         is_valid_positive_integer_in_range/3]).

-define(AUTO_FAILLOVER_MIN_TIMEOUT, 5).
-define(AUTO_FAILLOVER_MIN_CE_TIMEOUT, 30).
-define(AUTO_FAILLOVER_MAX_TIMEOUT, 3600).

handle_settings_get(Req) ->
    Config = build_settings_auto_failover(),
    Enabled = proplists:get_value(enabled, Config),
    Timeout = proplists:get_value(timeout, Config),
    Count = proplists:get_value(count, Config),
    reply_json(Req, {struct, [{enabled, Enabled},
                              {timeout, Timeout},
                              {count, Count}]}).

build_settings_auto_failover() ->
    {value, Config} = ns_config:search(ns_config:get(), auto_failover_cfg),
    Config.

handle_settings_post(Req) ->
    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    Enabled = proplists:get_value("enabled", PostArgs),
    Timeout = proplists:get_value("timeout", PostArgs),
    %% MaxNodes is hard-coded to 1 for now.
    MaxNodes = "1",
    case {ValidateOnly,
          validate_settings_auto_failover(Enabled, Timeout, MaxNodes)} of
        {false, [true, Timeout2, MaxNodes2]} ->
            auto_failover:enable(Timeout2, MaxNodes2),
            ns_audit:enable_auto_failover(Req, Timeout2, MaxNodes2),
            reply(Req, 200);
        {false, false} ->
            auto_failover:disable(),
            ns_audit:disable_auto_failover(Req),
            reply(Req, 200);
        {false, {error, Errors}} ->
            Errors2 = [<<Msg/binary, "\n">> || {_, Msg} <- Errors],
            reply_text(Req, Errors2, 400);
        {true, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 200);
        %% Validation only and no errors
        {true, _}->
            reply_json(Req, {struct, [{errors, null}]}, 200)
    end.

validate_settings_auto_failover(Enabled, Timeout, MaxNodes) ->
    Enabled2 = case Enabled of
                   "true" -> true;
                   "false" -> false;
                   _ -> {enabled, <<"The value of \"enabled\" must be true or false">>}
               end,
    case Enabled2 of
        true ->
            MinTimeout = case cluster_compat_mode:is_cluster_50() andalso
                             cluster_compat_mode:is_enterprise() of
                             true ->
                                 ?AUTO_FAILLOVER_MIN_TIMEOUT;
                             false ->
                                 ?AUTO_FAILLOVER_MIN_CE_TIMEOUT
                         end,
            Errors = [is_valid_positive_integer_in_range(Timeout, MinTimeout, ?AUTO_FAILLOVER_MAX_TIMEOUT) orelse
                      {timeout, erlang:list_to_binary(io_lib:format("The value of \"timeout\" must be a positive integer in a range from ~p to ~p",
                                                                    [MinTimeout, ?AUTO_FAILLOVER_MAX_TIMEOUT]))},
                      is_valid_positive_integer(MaxNodes) orelse
                      {maxNodes, <<"The value of \"maxNodes\" must be a positive integer">>}],
            case lists:filter(fun (E) -> E =/= true end, Errors) of
                [] ->
                    [Enabled2, list_to_integer(Timeout),
                     list_to_integer(MaxNodes)];
                Errors2 ->
                    {error, Errors2}
            end;
        false ->
            Enabled2;
        Error ->
            {error, [Error]}
    end.

%% @doc Resets the number of nodes that were automatically failovered to zero
handle_settings_reset_count(Req) ->
    auto_failover:reset_count(),
    ns_audit:reset_auto_failover_count(Req),
    reply(Req, 200).

