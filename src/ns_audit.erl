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
         login_failure/1]).

code(login_success) ->
    10000;
code(login_failure) ->
    10001.


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

    props_to_json([{"date", Date}, {"time", Time}, {"UTCOffset", Offset}]).

props_to_json(Props) ->
    {lists:map(fun ({Key, Value}) when is_list(Value) ->
                       {Key, iolist_to_binary(Value)};
                   (Prop) ->
                       Prop
               end, Props)}.

get_user_id(User) ->
    props_to_json([{"source", "internal"}, {"user", User}]).

put(Code, Req, Params) ->
    Body = props_to_json([{"name", Code},
                          {"timestamp", get_timestamp(now())},
                          {"sessionID", menelaus_auth:get_token(Req)},
                          {"remote", Req:get(peer)},
                          {"userid", get_user_id(menelaus_auth:get_user(Req))},
                          {"params", props_to_json(Params)}]),

    EncodedBody = ejson:encode(Body),
    ?log_debug("Audit ~p: ~p", [Code, EncodedBody]),

    ns_memcached_sockets_pool:executing_on_socket(
      fun (Sock) ->
              ok = mc_client_binary:audit_put(Sock, code(Code), EncodedBody)
      end).

login_success(Req) ->
    put(login_success, Req, [{"role", menelaus_auth:get_role(Req)},
                             {"userid", get_user_id(menelaus_auth:get_user(Req))}]).

login_failure(Req) ->
    put(login_failure, Req, [{"userid", get_user_id(menelaus_auth:get_user(Req))}]).
