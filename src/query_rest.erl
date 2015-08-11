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
%% @doc this module implements access to cbq-engine via REST API
%%

-module(query_rest).

-include("ns_common.hrl").

-export([get_query_port/2,
         get_ssl_query_port/2,
         get_stats/0,
         maybe_refresh_cert/0]).

get_query_port(Config, Node) ->
    ns_config:search(Config, {node, Node, query_port}, undefined).

get_ssl_query_port(Config, Node) ->
    ns_config:search(Config, {node, Node, ssl_query_port}, undefined).

get_stats() ->
    case ns_cluster_membership:should_run_service(ns_config:latest(), n1ql, node()) of
        true ->
            do_get_stats();
        false ->
            []
    end.

do_get_stats() ->
    RV = send("GET", "/admin/stats", 30000),
    case RV of
        {200, _Headers, BodyRaw} ->
            case (catch ejson:decode(BodyRaw)) of
                {[_|_] = Stats} ->
                    Stats;
                Err ->
                    ?log_error("Failed to parse query stats: ~p", [Err]),
                    []
            end;
        _ ->
            ?log_error("Ignoring. Failed to grab stats: ~p", [RV]),
            []
    end.

send(Method, Path, Timeout) ->
    Port =  get_query_port(ns_config:latest(), node()),
    URL = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    User = ns_config_auth:get_user(special),
    Pwd = ns_config_auth:get_password(special),
    Headers = menelaus_rest:add_basic_auth([], User, Pwd),
    {ok, {{Code, _}, RespHeaders, RespBody}} =
        rest_utils:request(query, URL, Method, Headers, [], Timeout),
    {Code, RespHeaders, RespBody}.

refresh_cert() ->
    ?log_debug("Tell cbq-engine to refresh ssl certificate"),
    try send("POST", "/admin/ssl_cert", 30000) of
        {200, _Headers, _Body} ->
            ok
    catch
        error:{badmatch, {error, {econnrefused, _}}} ->
            ?log_debug("Failed to notify cbq-engine because it is not started yet. This is usually normal")
    end.

maybe_refresh_cert() ->
    case ns_cluster_membership:should_run_service(ns_config:latest(), n1ql, node()) of
        true ->
            case get_ssl_query_port(ns_config:latest(), node()) of
                undefined ->
                    ok;
                _ ->
                    refresh_cert()
            end;
        false->
            ok
    end.
