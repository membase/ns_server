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
         handle_delete_user/2,
         handle_check_permissions_post/1,
         check_permissions_url_version/1,
         handle_check_permission_for_cbauth/1,
         reply_forbidden/2]).

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
role_to_string({Role, [all]}) ->
    lists:flatten(io_lib:format("~p[*]", [Role]));
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

list_to_rbac_atom(List) ->
    try
        list_to_existing_atom(List)
    catch error:badarg ->
            '_unknown_'
    end.

parse_permission(RawPermission) ->
    case string:tokens(RawPermission, "!") of
        [Object, Operation] ->
            case parse_object(Object) of
                error ->
                    error;
                Parsed ->
                    {Parsed, list_to_rbac_atom(Operation)}
            end;
        _ ->
            error
    end.

parse_object("cluster" ++ RawObject) ->
    parse_vertices(RawObject, []);
parse_object(_) ->
    error.

parse_vertices([], Acc) ->
    lists:reverse(Acc);
parse_vertices([$. | Rest], Acc) ->
    case parse_until(Rest, ".[") of
        {Name, [$. | Rest1]} ->
            parse_vertices([$. | Rest1], [list_to_rbac_atom(Name) | Acc]);
        {Name, []} ->
            parse_vertices([], [list_to_rbac_atom(Name) | Acc]);
        {Name, [$[ | Rest1]} ->
            case parse_until(Rest1, "]") of
                {Param, [$] | Rest2]} ->
                    parse_vertices(Rest2, [{list_to_rbac_atom(Name), Param} | Acc]);
                _ ->
                    error
            end
    end;
parse_vertices(_, _) ->
    error.

parse_permissions(Body) ->
    RawPermissions = string:tokens(Body, ","),
    lists:map(fun (RawPermission) ->
                      Trimmed = misc:trim(RawPermission),
                      {Trimmed, parse_permission(Trimmed)}
              end, RawPermissions).

parse_permissions_test() ->
    ?assertMatch(
       [{"cluster.admin!write", {[admin], write}},
        {"cluster.admin", error},
        {"admin!write", error}],
       parse_permissions("cluster.admin!write, cluster.admin, admin!write")),
    ?assertMatch(
       [{"cluster.bucket[test.test]!read", {[{bucket, "test.test"}], read}},
        {"cluster.bucket[test.test].stats!read", {[{bucket, "test.test"}, stats], read}}],
       parse_permissions(" cluster.bucket[test.test]!read, cluster.bucket[test.test].stats!read ")),
    ?assertMatch(
       [{"cluster.no_such_atom!no_such_atom", {['_unknown_'], '_unknown_'}}],
       parse_permissions("cluster.no_such_atom!no_such_atom")).

handle_check_permissions_post(Req) ->
    Body = Req:recv_body(),
    case Body of
        undefined ->
            menelaus_util:reply_json(Req, <<"Request body should not be empty.">>, 400);
        _ ->
            Permissions = parse_permissions(binary_to_list(Body)),
            Malformed = [Bad || {Bad, error} <- Permissions],
            case Malformed of
                [] ->
                    Tested =
                        [{RawPermission, menelaus_auth:has_permission(Permission, Req)} ||
                            {RawPermission, Permission} <- Permissions],
                    menelaus_util:reply_json(Req, {Tested});
                _ ->
                    Message = io_lib:format("Malformed permissions: [~s].",
                                            [string:join(Malformed, ",")]),
                    menelaus_util:reply_json(Req, iolist_to_binary(Message), 400)
            end
    end.

check_permissions_url_version(Config) ->
    erlang:phash2([menelaus_roles:get_definitions(Config),
                   menelaus_roles:get_users(Config),
                   ns_bucket:get_bucket_names(ns_bucket:get_buckets(Config))]).

handle_check_permission_for_cbauth(Req) ->
    Params = Req:parse_qs(),
    Identity = {proplists:get_value("user", Params),
                list_to_existing_atom(proplists:get_value("src", Params))},
    RawPermission = proplists:get_value("permission", Params),
    Permission = parse_permission(misc:trim(RawPermission)),

    case menelaus_roles:is_allowed(Permission, Identity) of
        true ->
            menelaus_util:reply_text(Req, "", 200);
        false ->
            menelaus_util:reply_text(Req, "", 401)
    end.

vertex_to_iolist(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
vertex_to_iolist({Atom, all}) ->
    [atom_to_list(Atom), "[*]"];
vertex_to_iolist({Atom, any}) ->
    [atom_to_list(Atom), "[?]"];
vertex_to_iolist({Atom, Param}) ->
    [atom_to_list(Atom), "[", Param, "]"].

permission_to_iolist({Object, Operation}) ->
    FormattedVertices = ["cluster" | [vertex_to_iolist(Vertex) || Vertex <- Object]],
    [string:join(FormattedVertices, "."), "!", atom_to_list(Operation)].

format_permissions(Permissions) ->
    lists:foldl(fun ({Object, Operations}, Acc) when is_list(Operations) ->
                        lists:foldl(
                          fun (Oper, Acc1) ->
                                  [iolist_to_binary(permission_to_iolist({Object, Oper})) | Acc1]
                          end, Acc, Operations);
                    (Permission, Acc) ->
                        [iolist_to_binary(permission_to_iolist(Permission)) | Acc]
                end, [], Permissions).

format_permissions_test() ->
    Permissions = [{[{bucket, all}, views], compact},
                   {[{bucket, any}, views], write},
                   {[{bucket, "default"}], all},
                   {[], all},
                   {[admin, diag], read},
                   {[{bucket, "test"}, xdcr], [write, execute]}],
    Formatted = [<<"cluster.bucket[*].views!compact">>,
                 <<"cluster.bucket[?].views!write">>,
                 <<"cluster.bucket[default]!all">>,
                 <<"cluster!all">>,
                 <<"cluster.admin.diag!read">>,
                 <<"cluster.bucket[test].xdcr!write">>,
                 <<"cluster.bucket[test].xdcr!execute">>],
    ?assertEqual(
       lists:sort(Formatted),
       lists:sort(format_permissions(Permissions))).

reply_forbidden(Req, Permissions) when is_list(Permissions) ->
    menelaus_util:reply_json(
      Req, {[{message, <<"Forbidden. User needs one of the following permissions">>},
             {permissions, format_permissions(Permissions)}]}, 403);
reply_forbidden(Req, Permission) ->
    reply_forbidden(Req, [Permission]).
