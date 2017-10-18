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
%% @doc handlers for miscellaneous REST API's

-module(menelaus_web_misc).

-export([handle_uilogin/1,
         handle_uilogout/1,
         handle_versions/1,
         handle_dot/2,
         handle_dotsvg/2,
         handle_tasks/2,
         handle_log_post/1]).

-import(menelaus_util,
        [reply_json/2,
         reply_json/3,
         reply_ok/3,
         reply_ok/4,
         insecure_pipe_through_command/2,
         parse_validate_number/3]).

-include("ns_common.hrl").

handle_uilogin(Req) ->
    Params = Req:parse_post(),
    User = proplists:get_value("user", Params),
    Password = proplists:get_value("password", Params),
    menelaus_auth:uilogin(Req, User, Password).

handle_uilogout(Req) ->
    case menelaus_auth:extract_ui_auth_token(Req) of
        undefined ->
            ok;
        Token ->
            menelaus_ui_auth:logout(Token)
    end,
    menelaus_auth:complete_uilogout(Req).

handle_versions(Req) ->
    reply_json(Req, {struct, menelaus_web_cache:versions_response()}).

handle_dot(Bucket, Req) ->
    reply_ok(Req, "text/plain; charset=utf-8", ns_janitor_vis:graphviz(Bucket)).

handle_dotsvg(Bucket, Req) ->
    Dot = ns_janitor_vis:graphviz(Bucket),
    DoRefresh = case proplists:get_value("refresh", Req:parse_qs(), "") of
                    "ok" -> true;
                    "yes" -> true;
                    "1" -> true;
                    _ -> false
                end,
    MaybeRefresh = if DoRefresh ->
                           [{"refresh", 1}];
                      true -> []
                   end,
    reply_ok(Req, "image/svg+xml",
             insecure_pipe_through_command("dot -Tsvg", Dot),
             MaybeRefresh).

handle_tasks(PoolId, Req) ->
    RebTimeoutS = proplists:get_value("rebalanceStatusTimeout", Req:parse_qs(), "2000"),
    case parse_validate_number(RebTimeoutS, 1000, 120000) of
        {ok, RebTimeout} ->
            do_handle_tasks(PoolId, Req, RebTimeout);
        _ ->
            reply_json(Req, {struct, [{rebalanceStatusTimeout, <<"invalid">>}]}, 400)
    end.

do_handle_tasks(PoolId, Req, RebTimeout) ->
    JSON = ns_doctor:build_tasks_list(PoolId, RebTimeout),
    reply_json(Req, JSON, 200).

handle_log_post(Req) ->
    Params = Req:parse_post(),
    Msg = proplists:get_value("message", Params),
    LogLevel = proplists:get_value("logLevel", Params),
    Component = proplists:get_value("component", Params),

    Errors =
        lists:flatten([case Msg of
                           undefined ->
                               {<<"message">>, <<"missing value">>};
                           _ ->
                               []
                       end,
                       case LogLevel of
                           "info" ->
                               [];
                           "warn" ->
                               [];
                           "error" ->
                               [];
                           _ ->
                               {<<"logLevel">>, <<"invalid or missing value">>}
                       end,
                       case Component of
                           undefined ->
                               {<<"component">>, <<"missing value">>};
                           _ ->
                               []
                       end]),

    case Errors of
        [] ->
            Fun = list_to_existing_atom([$x | LogLevel]),
            ale:Fun(?USER_LOGGER,
                    {list_to_atom(Component), unknown, -1}, undefined, Msg, []),
            reply_json(Req, []);
        _ ->
            reply_json(Req, {struct, Errors}, 400)
    end.
