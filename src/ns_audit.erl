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
         rebalance_initiated/4]).

code(login_success) ->
    10000;
code(login_failure) ->
    10001;
code(delete_user) ->
    10004;
code(password_change) ->
    10005;
code(add_node) ->
    10007;
code(remove_node) ->
    10008;
code(failover_node) ->
    10009;
code(enter_node_recovery) ->
    10010;
code(rebalance_initiated) ->
    10011.


to_binary(A) when is_list(A) ->
    iolist_to_binary(A);
to_binary(A) ->
    A.

get_timestamp(Now = {_, _, Microsecs}) ->
    {{YYYY, MM, DD}, {Hour, Min, Sec}} = LocalNow = calendar:now_to_local_time(Now),

    UTCSec = calendar:datetime_to_gregorian_seconds(calendar:now_to_universal_time(Now)),
    LocSec = calendar:datetime_to_gregorian_seconds(LocalNow),
    OffsetTotalMins = (LocSec - UTCSec) div 60,
    OffsetHrs = OffsetTotalMins div 60,
    OffsetMin = abs(OffsetTotalMins rem 60),

    Date = io_lib:format("~4.4.0w-~2.2.0w-~2.2.0w", [YYYY, MM, DD]),
    Time = io_lib:format("~2.2.0w:~2.2.0w:~2.2.0w.~6.6.0w", [Hour, Min, Sec, Microsecs]),
    Offset = io_lib:format("~p:~2.2.0w", [OffsetHrs, OffsetMin]),

    {[{date, to_binary(Date)},
      {time, to_binary(Time)},
      {'UTCOffset', to_binary(Offset)}]}.

get_user_id(anonymous) ->
    anonymous;
get_user_id(undefined) ->
    anonymous;
get_user_id(User) ->
    {[{source, internal}, {user, to_binary(User)}]}.

put(Code, Req, Params) ->
    {User, Token, Peer} =
        case Req of
            undefined ->
                {anonymous, undefined, undefined};
            _ ->
                {get_user_id(menelaus_auth:get_user(Req)),
                 to_binary(menelaus_auth:get_token(Req)),
                 to_binary(Req:get(peer))}
        end,
    Body = {[{name, Code},
             {timestamp, get_timestamp(now())},
             {sessionID, Token},
             {remote, Peer},
             {userid, User},
             {params, {Params}}]},

    EncodedBody = ejson:encode(Body),
    ?log_debug("Audit ~p: ~p", [Code, EncodedBody]),

    ns_memcached_sockets_pool:executing_on_socket(
      fun (Sock) ->
              ok = mc_client_binary:audit_put(Sock, code(Code), EncodedBody)
      end).

login_success(Req) ->
    put(login_success, Req, [{role, to_binary(menelaus_auth:get_role(Req))},
                             {userid, get_user_id(menelaus_auth:get_user(Req))}]).

login_failure(Req) ->
    put(login_failure, Req, [{userid, get_user_id(menelaus_auth:get_user(Req))}]).

delete_user(Req, User, Role) ->
    put(delete_user, Req, [{role, to_binary(Role)},
                           {userid, get_user_id(User)}]).

password_change(Req, User, Role) ->
    put(password_change, Req, [{role, to_binary(Role)},
                               {userid, get_user_id(User)}]).

add_node(Req, Hostname, Port, User, GroupUUID, Services, Node) ->
    put(add_node, Req, [{node, Node},
                        {groupUUID, to_binary(GroupUUID)},
                        {hostname, to_binary(Hostname)},
                        {port, Port},
                        {services, Services},
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
                      [to_binary(Bucket) || Bucket <- DeltaRecoveryBuckets]
              end,
    put(rebalance_initiated, Req,
        [{known_nodes, KnownNodes},
         {ejected_nodes, EjectedNodes},
         {delta_recovery_buckets, Buckets}]).
