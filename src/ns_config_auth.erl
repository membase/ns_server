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

-include("ns_common.hrl").

-export([authenticate/3,
         set_credentials/3,
         get_user/1,
         get_password/1,
         credentials_changed/3,
         unset_credentials/1,
         upgrade/1,
         get_creds/1,
         is_system_provisioned/0]).

get_key(admin) ->
    rest_creds;
get_key(ro_admin) ->
    read_only_user_creds.

set_credentials(Role, User, Password) ->
    case cluster_compat_mode:is_cluster_30() of
        true ->
            set_credentials_30(Role, User, Password);
        false ->
            set_credentials_old(Role, User, Password)
    end.

set_credentials_30(Role, User, Password) ->
    ns_config:set(get_key(Role), {User, {password, hash_password(Password)}}).

set_credentials_old(admin, User, Password) ->
    ns_config:set(rest_creds, [{creds,
                                [{User, [{password, Password}]}]}]);
set_credentials_old(ro_admin, User, Password) ->
    ns_config:set(read_only_user_creds, {User, {password, Password}}).

is_system_provisioned() ->
    case ns_config:search(get_key(admin)) of
        {value, {_U, _}} ->
            true;
        {value, [{creds, [{_U, _}|_]}]} ->
            true;
        _ ->
            false
    end.

get_user(special) ->
    "@";
get_user(Role) ->
    case cluster_compat_mode:is_cluster_30() of
        true ->
            get_user_30(Role);
        false ->
            get_user_old(Role)
    end.

get_user_30(Role) ->
    case ns_config:search(get_key(Role)) of
        {value, {U, _}} ->
            U;
        _ ->
            undefined
    end.

get_user_old(admin) ->
    case ns_config:search_prop('latest-config-marker', rest_creds, creds, []) of
        [] ->
            undefined;
        [{U, _}|_] ->
            U
    end;
get_user_old(ro_admin) ->
    case ns_config:search(read_only_user_creds) of
        {value, {U, _}} ->
            U;
        _ ->
            undefined
    end.

get_password(special) ->
    ns_config:search_node_prop('latest-config-marker', memcached, admin_pass).

get_creds(Role) ->
    case ns_config:search(get_key(Role)) of
        {value, {User, {password, {Salt, Mac}}}} ->
            {User, Salt, Mac};
        _ ->
            undefined
    end.

credentials_changed(Role, User, Password) ->
    case cluster_compat_mode:is_cluster_30() of
        true ->
            credentials_changed_30(Role, User, Password);
        false ->
            credentials_changed_old(Role, User, Password)
    end.

credentials_changed_30(Role, User, Password) ->
    case ns_config:search(get_key(Role)) of
        {value, {User, {password, {Salt, Mac}}}} ->
            hash_password(Salt, Password) =/= Mac;
        _ ->
            true
    end.

credentials_changed_old(admin, User, Password) ->
    case ns_config:search_prop('latest-config-marker', rest_creds, creds, []) of
        [{U, Auth} | _] ->
            P = proplists:get_value(password, Auth, ""),
            User =/= U orelse Password =/= P;
        _ ->
            true
    end.

authenticate(admin, "@" = User, Password) ->
    Password =:= ns_config:search_node_prop('latest-config-marker', memcached, admin_pass)
        orelse authenticate_non_special(admin, User, Password);
authenticate(Role, User, Password) ->
    authenticate_non_special(Role, User, Password).

authenticate_non_special(Role, User, Password) ->
    case cluster_compat_mode:is_cluster_30() of
        true ->
            authenticate_30(Role, User, Password);
        false ->
            authenticate_old(Role, User, Password)
    end.

authenticate_old(admin, User, Password) ->
    case ns_config:search_prop('latest-config-marker', rest_creds, creds, []) of
        [{User, Auth} | _] ->
            Password =:= proplists:get_value(password, Auth, "");
        [] ->
            % An empty list means no login/password auth check.
            true;
        _ ->
            false
    end;
authenticate_old(ro_admin, User, Password) ->
    ns_config:search(read_only_user_creds) =:= {value, {User, {password, Password}}}.

authenticate_30(Role, User, Password) ->
    do_authenticate(Role, ns_config:search(get_key(Role)), User, Password).

do_authenticate(_Role, {value, {User, {password, {Salt, Mac}}}}, User, Password) ->
    hash_password(Salt, Password) =:= Mac;
do_authenticate(admin, {value, null}, _User, _Password) ->
    true;
do_authenticate(_Role, _Creds, _User, _Password) ->
    false.

unset_credentials(Role) ->
    ns_config:set(get_key(Role), null).

upgrade(Config)->
    case ns_config:search_prop(Config, rest_creds, creds, []) of
        [{User, Auth} | _] ->
            Password = proplists:get_value(password, Auth, ""),
            [{set, rest_creds, {User, {password, hash_password(Password)}}}];
        _ ->
            [{set, rest_creds, null}]
    end ++
        case ns_config:search(Config, read_only_user_creds) of
            {value, {ROUser, {password, ROPassword}}} ->
                [{set, read_only_user_creds, {ROUser, {password, hash_password(ROPassword)}}}];
            false ->
                [{set, read_only_user_creds, null}];
            {value, null} ->
                []
        end.

hash_password(Password) ->
    Salt = crypto:rand_bytes(16),
    {Salt, hash_password(Salt, Password)}.

hash_password(Salt, Password) ->
    {module, crypto} = code:ensure_loaded(crypto),
    {F, A} =
        case erlang:function_exported(crypto, hmac, 3) of
            true ->
                {hmac, [sha, Salt, list_to_binary(Password)]};
            false ->
                {sha_mac, [Salt, list_to_binary(Password)]}
        end,

    erlang:apply(crypto, F, A).
