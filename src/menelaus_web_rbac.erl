%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
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

%% @doc rest api's for rbac and ldap support

-module(menelaus_web_rbac).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([handle_saslauthd_auth_settings/1,
         handle_saslauthd_auth_settings_post/1,
         handle_validate_saslauthd_creds_post/1,
         handle_get_roles/1,
         handle_get_users/1,
         handle_put_user/2,
         handle_delete_user/2]).

assert_is_ldap_enabled() ->
    case cluster_compat_mode:is_ldap_enabled() of
        true ->
            ok;
        false ->
            erlang:throw({web_exception,
                          400,
                          "This http API endpoint is only supported in enterprise edition "
                          "running on GNU/Linux",
                          []})
    end.

handle_saslauthd_auth_settings(Req) ->
    assert_is_ldap_enabled(),

    menelaus_util:reply_json(Req, {saslauthd_auth:build_settings()}).

extract_user_list(undefined) ->
    asterisk;
extract_user_list(String) ->
    StringNoCR = [C || C <- String, C =/= $\r],
    Strings = string:tokens(StringNoCR, "\n"),
    [B || B <- [list_to_binary(misc:trim(S)) || S <- Strings],
          B =/= <<>>].

parse_validate_saslauthd_settings(Params) ->
    EnabledR = case menelaus_web:parse_validate_boolean_field("enabled", enabled, Params) of
                   [] ->
                       [{error, enabled, <<"is missing">>}];
                   EnabledX -> EnabledX
               end,
    [AdminsParam, RoAdminsParam] =
        case EnabledR of
            [{ok, enabled, false}] ->
                ["", ""];
            _ ->
                [proplists:get_value(K, Params) || K <- ["admins", "roAdmins"]]
        end,
    Admins = extract_user_list(AdminsParam),
    RoAdmins = extract_user_list(RoAdminsParam),
    MaybeExtraFields = case proplists:get_keys(Params) -- ["enabled", "roAdmins", "admins"] of
                           [] ->
                               [];
                           UnknownKeys ->
                               Msg = io_lib:format("failed to recognize the following fields ~s", [string:join(UnknownKeys, ", ")]),
                               [{error, '_', iolist_to_binary(Msg)}]
                       end,
    MaybeTwoAsterisks = case Admins =:= asterisk andalso RoAdmins =:= asterisk of
                            true ->
                                [{error, 'admins', <<"at least one of admins or roAdmins needs to be given">>}];
                            false ->
                                []
                        end,
    Everything = EnabledR ++ MaybeExtraFields ++ MaybeTwoAsterisks,
    case [{Field, Msg} || {error, Field, Msg} <- Everything] of
        [] ->
            [{ok, enabled, Enabled}] = EnabledR,
            {ok, [{enabled, Enabled},
                  {admins, Admins},
                  {roAdmins, RoAdmins}]};
        Errors ->
            {errors, Errors}
    end.

handle_saslauthd_auth_settings_post(Req) ->
    assert_is_ldap_enabled(),

    case parse_validate_saslauthd_settings(Req:parse_post()) of
        {ok, Props} ->
            saslauthd_auth:set_settings(Props),
            ns_audit:setup_ldap(Req, Props),
            handle_saslauthd_auth_settings(Req);
        {errors, Errors} ->
            menelaus_util:reply_json(Req, {Errors}, 400)
    end.

handle_validate_saslauthd_creds_post(Req) ->
    assert_is_ldap_enabled(),

    Params = Req:parse_post(),
    VRV = menelaus_auth:verify_login_creds(proplists:get_value("user", Params, ""),
                                           proplists:get_value("password", Params, "")),
    {Role, Src} =
        case VRV of
            %% TODO RBAC: return correct role for ldap users
            {ok, {_, saslauthd}} -> {fullAdmin, saslauthd};
            {ok, {_, admin}} -> {fullAdmin, builtin};
            {ok, {_, ro_admin}} -> {fullAdmin, builtin};
            {error, Error} ->
                erlang:throw({web_exception, 400, Error, []});
            _ -> none
        end,
    menelaus_util:reply_json(Req, {[{role, Role}, {source, Src}]}).

role_to_json(Name) when is_atom(Name) ->
    [{role, Name}];
role_to_json({Name, [all]}) ->
    [{role, Name}, {bucket_name, <<"*">>}];
role_to_json({Name, [BucketName]}) ->
    [{role, Name}, {bucket_name, list_to_binary(BucketName)}].

handle_get_roles(Req) ->
    menelaus_web:assert_is_enterprise(),
    menelaus_web:assert_is_watson(),

    Json = [{role_to_json(Role) ++ Props} ||
               {Role, Props} <- menelaus_roles:get_all_assignable_roles(ns_config:get())],
    menelaus_util:reply_json(Req, Json).

handle_get_users(Req) ->
    menelaus_web:assert_is_enterprise(),
    menelaus_web:assert_is_watson(),

    Users = menelaus_roles:get_users(),
    Json = lists:map(
             fun ({{User, saslauthd}, Props}) ->
                     Roles = proplists:get_value(roles, Props, []),
                     UserJson = [{id, list_to_binary(User)},
                                 {roles, [{role_to_json(Role)} || Role <- Roles]}],
                     {case lists:keyfind(name, 1, Props) of
                          false ->
                              UserJson;
                          {name, Name} ->
                              [{name, list_to_binary(Name)} | UserJson]
                      end}
             end, Users),
    menelaus_util:reply_json(Req, Json).

parse_until(Str, Delimeters) ->
    lists:splitwith(fun (Char) ->
                            not lists:member(Char, Delimeters)
                    end, Str).

parse_role(RoleRaw) ->
    try
        case parse_until(RoleRaw, "[") of
            {Role, []} ->
                list_to_existing_atom(Role);
            {Role, "[*]"} ->
                {list_to_existing_atom(Role), [all]};
            {Role, [$[ | ParamAndBracket]} ->
                case parse_until(ParamAndBracket, "]") of
                    {Param, "]"} ->
                        {list_to_existing_atom(Role), [Param]};
                    _ ->
                        {error, RoleRaw}
                end
        end
    catch error:badarg ->
            {error, RoleRaw}
    end.

parse_roles(undefined) ->
    [];
parse_roles(RolesStr) ->
    RolesRaw = string:tokens(RolesStr, ","),
    [parse_role(misc:trim(RoleRaw)) || RoleRaw <- RolesRaw].

role_to_string(Role) when is_atom(Role) ->
    atom_to_list(Role);
role_to_string({Role, [BucketName]}) ->
    lists:flatten(io_lib:format("~p[~s]", [Role, BucketName])).

parse_roles_test() ->
    Res = parse_roles("admin, bucket_admin[test.test], bucket_admin[*], no_such_atom, bucket_admin[default"),
    ?assertMatch([admin,
                  {bucket_admin, ["test.test"]},
                  {bucket_admin, [all]},
                  {error, "no_such_atom"},
                  {error, "bucket_admin[default"}], Res).

reply_bad_roles(Req, BadRoles) ->
    Str = string:join(BadRoles, ","),
    menelaus_util:reply_json(
      Req,
      iolist_to_binary(io_lib:format("Malformed or unknown roles: [~s]", [Str])), 400).

handle_put_user(UserId, Req) ->
    menelaus_web:assert_is_enterprise(),
    menelaus_web:assert_is_watson(),

    Props = Req:parse_post(),
    Roles = parse_roles(proplists:get_value("roles", Props)),

    BadRoles = [BadRole || {error, BadRole} <- Roles],
    case BadRoles of
        [] ->
            case menelaus_roles:store_user({UserId, saslauthd},
                                           proplists:get_value("name", Props),
                                           Roles) of
                {commit, _} ->
                    handle_get_users(Req);
                {abort, {error, roles_validation, UnknownRoles}} ->
                    reply_bad_roles(Req, [role_to_string(UR) || UR <- UnknownRoles]);
                retry_needed ->
                    erlang:error(exceeded_retries)
            end;
        _ ->
            reply_bad_roles(Req, BadRoles)
    end.

handle_delete_user(UserId, Req) ->
    case menelaus_roles:delete_user({UserId, saslauthd}) of
        {commit, _} ->
            handle_get_users(Req);
        {abort, {error, not_found}} ->
            menelaus_util:reply_json(Req, <<"User was not found.">>, 404);
        retry_needed ->
            erlang:error(exceeded_retries)
    end.


