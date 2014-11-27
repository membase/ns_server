%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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

-module(menelaus_cbauth).

-export([handle_cbauth_post/1]).

-include("ns_common.hrl").

handle_cbauth_post(Req) ->
    Params = Req:parse_post(),
    Method = proplists:get_value("method", Params),
    ?log_debug("method: ~s", [Method]),
    case Method of
        "auth" ->
            handle_auth_post(Req, Params);
        "getMcdAuth" ->
            handle_service_auth(Req, Params, true);
        "getHTTPAuth" ->
            handle_service_auth(Req, Params, false)
    end.

handle_auth_post(Req, Params) ->
    [User, Password, Bucket] = [proplists:get_value(K, Params) || K <- ["user", "pwd", "bucket"]],
    ?log_debug("auth args: ~p", [[User, Password, Bucket]]),
    {Allowed, Admin} = menelaus_auth:check_creds(User, Password, Bucket),
    menelaus_util:reply_json(Req, {[{isAdmin, Admin}, {allowed, Allowed}]}).

find_hostport_node(Hostport, Config) ->
    [Host, PortS] = string:tokens(Hostport, ":"),
    Port = list_to_integer(PortS),
    NToS = [{N, bucket_info_cache:build_services(N, Config, ns_cluster_membership:node_services(Config, N))}
            || N <- ns_cluster_membership:active_nodes(Config),
               case misc:node_name_host(N) of
                   {_, "127.0.0.1"} ->
                       true;
                   {_, H} ->
                       H =:= Host
               end],
    find_hostport_node_loop(NToS, Port).

find_hostport_node_loop([], _Port) ->
    false;
find_hostport_node_loop([{N, SVCs} | Rest], Port) ->
    case lists:keyfind(Port, 2, SVCs) =/= false of
        true ->
            N;
        false ->
            find_hostport_node_loop(Rest, Port)
    end.

handle_service_auth(Req, Params, IsMcd) ->
    Hostport = proplists:get_value("hostport", Params),
    Config = ns_config:get(),
    N = find_hostport_node(Hostport, Config),
    case N of
        false ->
            menelaus_util:reply(Req, 400);
        _ ->
            ?log_debug("Hostport: ~p, N: ~p", [Hostport, N]),
            Password = ns_config:search_node_prop(N, Config, memcached, admin_pass),
            Username = case IsMcd of
                           true ->
                               ns_config:search_node_prop(N, Config, memcached, admin_user);
                           _ ->
                               "@"
                       end,
            J = {[{user, erlang:list_to_binary(Username)},
                  {pwd, erlang:list_to_binary(Password)}]},
            menelaus_util:reply_json(Req, J)
    end.
