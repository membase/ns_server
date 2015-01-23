%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
%% @doc commands for audit logging
%%
-module(ns_audit).

-include("ns_common.hrl").

-export([login_success/1,
         login_failure/1,
         delete_user/3,
         password_change/3,
         add_node/7,
         remove_node/2,
         failover_node/3,
         enter_node_recovery/3,
         rebalance_initiated/4,
         create_bucket/4,
         modify_bucket/4,
         delete_bucket/2,
         flush_bucket/2,
         start_loading_sample/2]).

code(login_success) ->
    8192;
code(login_failure) ->
    8193;
code(delete_user) ->
    8194;
code(password_change) ->
    8195;
code(add_node) ->
    8196;
code(remove_node) ->
    8197;
code(failover_node) ->
    8198;
code(enter_node_recovery) ->
    8199;
code(rebalance_initiated) ->
    8200;
code(create_bucket) ->
    8201;
code(modify_bucket) ->
    8202;
code(delete_bucket) ->
    8203;
code(flush_bucket) ->
    8204;
code(start_loading_sample) ->
    8205.


to_binary({list, List}) ->
    [to_binary(A) || A <- List];
to_binary(A) when is_list(A) ->
    iolist_to_binary(A);
to_binary(A) ->
    A.

now_to_iso8601(Now = {_, _, Microsecs}) ->
    {{YYYY, MM, DD}, {Hour, Min, Sec}} = LocalNow = calendar:now_to_local_time(Now),

    UTCSec = calendar:datetime_to_gregorian_seconds(calendar:now_to_universal_time(Now)),
    LocSec = calendar:datetime_to_gregorian_seconds(LocalNow),
    Offset =
        case (LocSec - UTCSec) div 60 of
            0 ->
                "Z";
            OffsetTotalMins ->
                OffsetHrs = OffsetTotalMins div 60,
                OffsetMin = abs(OffsetTotalMins rem 60),
                OffsetSign = case OffsetHrs < 0 of
                                 true ->
                                     "-";
                                 false ->
                                     "+"
                             end,
                io_lib:format("~s~2.2.0w:~2.2.0w", [OffsetSign, abs(OffsetHrs), OffsetMin])
        end,
    io_lib:format("~4.4.0w-~2.2.0w-~2.2.0wT~2.2.0w:~2.2.0w:~2.2.0w.~3.3.0w",
                  [YYYY, MM, DD, Hour, Min, Sec, Microsecs div 1000]) ++ Offset.

get_user_id(anonymous) ->
    anonymous;
get_user_id(undefined) ->
    anonymous;
get_user_id(User) ->
    {[{source, ns_server}, {user, to_binary(User)}]}.

get_remote(Req) ->
    Socket = Req:get(socket),
    {ok, {Host, Port}} = mochiweb_socket:peername(Socket),
    {[{ip, to_binary(inet_parse:ntoa(Host))},
      {port, Port}]}.

put(Code, Req, Params) ->
    {User, Token, Remote} =
        case Req of
            undefined ->
                {anonymous, undefined, undefined};
            _ ->
                {get_user_id(menelaus_auth:get_user(Req)),
                 menelaus_auth:get_token(Req),
                 get_remote(Req)}
        end,
    Body = [{timestamp, now_to_iso8601(now())},
            {remote, Remote},
            {sessionid, Token},
            {real_userid, User}] ++ Params,

    Body1 = lists:foldl(
              fun ({_Key, undefined}, Acc) ->
                      Acc;
                  ({_Key, "undefined"}, Acc) ->
                      Acc;
                  ({Key, Value}, Acc) ->
                      [{Key, to_binary(Value)} | Acc]
              end, [], Body),

    ?log_debug("Audit ~p: ~p", [Code, Body1]),
    EncodedBody = ejson:encode({Body1}),

    ns_memcached_sockets_pool:executing_on_socket(
      fun (Sock) ->
              ok = mc_client_binary:audit_put(Sock, code(Code), EncodedBody)
      end).

login_success(Req) ->
    put(login_success, Req, [{role, menelaus_auth:get_role(Req)}]).

login_failure(Req) ->
    put(login_failure, Req, []).

delete_user(Req, User, Role) ->
    put(delete_user, Req, [{role, Role},
                           {userid, get_user_id(User)}]).

password_change(Req, User, Role) ->
    put(password_change, Req, [{role, Role},
                               {userid, get_user_id(User)}]).

add_node(Req, Hostname, Port, User, GroupUUID, Services, Node) ->
    put(add_node, Req, [{node, Node},
                        {groupUUID, GroupUUID},
                        {hostname, Hostname},
                        {port, Port},
                        {services, {list, Services}},
                        {user, get_user_id(User)}]).

remove_node(Req, Node) ->
    put(remove_node, Req, [{node, Node}]).

failover_node(Req, Node, Type) ->
    put(failover_node, Req, [{node, Node}, {type, Type}]).

enter_node_recovery(Req, Node, Type) ->
    put(enter_node_recovery, Req, [{node, Node}, {type, Type}]).

rebalance_initiated(Req, KnownNodes, EjectedNodes, DeltaRecoveryBuckets) ->
    Buckets = case DeltaRecoveryBuckets of
                  all ->
                      all;
                  _ ->
                      {list, DeltaRecoveryBuckets}
              end,
    put(rebalance_initiated, Req,
        [{known_nodes, {list, KnownNodes}},
         {ejected_nodes, {list, EjectedNodes}},
         {delta_recovery_buckets, Buckets}]).

create_bucket(Req, Name, Type, Props) ->
    put(create_bucket, Req,
        [{name, Name},
         {type, Type},
         {props, {[{K, to_binary(V)} || {K, V} <- Props,
                                        K =/= sasl_password]}}]).

modify_bucket(Req, Name, Type, Props) ->
    put(modify_bucket, Req,
        [{name, Name},
         {type, Type},
         {props, {[{K, to_binary(V)} || {K, V} <- Props,
                                        K =/= sasl_password]}}]).

delete_bucket(Req, Name) ->
    put(delete_bucket, Req, [{name, Name}]).

flush_bucket(Req, Name) ->
    put(flush_bucket, Req, [{name, Name}]).

start_loading_sample(Req, Name) ->
    put(start_loading_sample, Req, [{name, Name}]).
