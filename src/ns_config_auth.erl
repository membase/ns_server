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
%% @doc unified access api for admin and ro_admin credentials

-module(ns_config_auth).

-export([authenticate/3,
         set_credentials/3,
         get_user/1,
         get_password/1,
         credentials_changed/3,
         unset_credentials/1]).

set_credentials(admin, User, Password) ->
    ns_config:set(rest_creds, [{creds,
                                [{User, [{password, Password}]}]}]);
set_credentials(ro_admin, User, Password) ->
    ns_config:set(read_only_user_creds, {User, {password, Password}}).

get_user(admin) ->
    case ns_config:search_prop('latest-config-marker', rest_creds, creds, []) of
        [] ->
            undefined;
        [{U, _}|_] ->
            U
    end;
get_user(ro_admin) ->
    case ns_config:search(read_only_user_creds) of
        {value, {U, _}} ->
            U;
        _ ->
            undefined
    end;
get_user(special) ->
    "@".

get_password(special) ->
    ns_config:search_node_prop('latest-config-marker', memcached, admin_pass).

credentials_changed(admin, User, Password) ->
    case ns_config:search_prop('latest-config-marker', rest_creds, creds, []) of
        [{U, Auth} | _] ->
            P = proplists:get_value(password, Auth, ""),
            User =/= U orelse Password =/= P;
        _ ->
            true
    end.

authenticate(admin, User, Password) ->
    case ns_config:search_prop('latest-config-marker', rest_creds, creds, []) of
        [{User, Auth} | _] ->
            Password =:= proplists:get_value(password, Auth, "");
        [] ->
            % An empty list means no login/password auth check.
            true;
        _ ->
            false
    end;
authenticate(ro_admin, User, Password) ->
    ns_config:search(read_only_user_creds) =:= {value, {User, {password, Password}}};
authenticate(special, User, Password) ->
    User =:= get_user(special) andalso
        Password =:= ns_config:search_node_prop('latest-config-marker', memcached, admin_pass).

unset_credentials(ro_admin) ->
    ns_config:set(read_only_user_creds, null).
