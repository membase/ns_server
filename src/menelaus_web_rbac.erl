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
-include("pipes.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([handle_saslauthd_auth_settings/1,
         handle_saslauthd_auth_settings_post/1,
         handle_validate_saslauthd_creds_post/1,
         handle_get_roles/1,
         handle_get_users/2,
         handle_get_users/3,
         handle_get_user/3,
         handle_whoami/1,
         handle_put_user/3,
         handle_delete_user/3,
         handle_change_password/1,
         handle_settings_read_only_admin_name/1,
         handle_settings_read_only_user_post/1,
         handle_read_only_user_delete/1,
         handle_read_only_user_reset/1,
         handle_reset_admin_password/1,
         handle_check_permissions_post/1,
         check_permissions_url_version/1,
         handle_check_permission_for_cbauth/1,
         forbidden_response/1,
         role_to_string/1,
         validate_cred/2,
         handle_get_password_policy/1,
         handle_post_password_policy/1,
         assert_no_users_upgrade/0]).

-define(MIN_USERS_PAGE_SIZE, 2).
-define(MAX_USERS_PAGE_SIZE, 100).

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
    EnabledR = case menelaus_util:parse_validate_boolean_field("enabled", enabled, Params) of
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
    case cluster_compat_mode:is_cluster_45() of
        true ->
            erlang:throw({web_exception,
                          400,
                          "This http API endpoint is not supported in 4.5 clusters", []});
        false ->
            ok
    end,

    Params = Req:parse_post(),
    User = proplists:get_value("user", Params, ""),
    VRV = menelaus_auth:verify_login_creds(User, proplists:get_value("password", Params, "")),

    {Role, Src} =
        case VRV of
            {ok, {_, external}} -> {saslauthd_auth:get_role_pre_45(User), saslauthd};
            {ok, {_, R}} -> {R, builtin};
            {error, Error} ->
                erlang:throw({web_exception, 400, Error, []});
            _ -> {false, builtin}
        end,
    JRole = case Role of
                admin ->
                    fullAdmin;
                ro_admin ->
                    roAdmin;
                false ->
                    none
            end,
    menelaus_util:reply_json(Req, {[{role, JRole}, {source, Src}]}).

role_to_json(Name) when is_atom(Name) ->
    [{role, Name}];
role_to_json({Name, [any]}) ->
    [{role, Name}, {bucket_name, <<"*">>}];
role_to_json({Name, [{BucketName, _Id}]}) ->
    [{role, Name}, {bucket_name, list_to_binary(BucketName)}];
role_to_json({Name, [BucketName]}) ->
    [{role, Name}, {bucket_name, list_to_binary(BucketName)}].

filter_roles_by_permission(_Config, undefined, Roles) ->
    Roles;
filter_roles_by_permission(Config, RawPermission, Roles) ->
    AllValues = menelaus_roles:calculate_possible_param_values(ns_bucket:get_buckets(Config)),
    case parse_permission(RawPermission) of
        error ->
            error;
        Permission ->
            lists:filtermap(
              fun ({Role, _} = RoleInfo) ->
                      Definitions = menelaus_roles:get_definitions(Config),
                      [CompiledRole] = menelaus_roles:compile_roles([Role], Definitions, AllValues),
                      case menelaus_roles:is_allowed(Permission, [CompiledRole]) of
                          true ->
                              {true, RoleInfo};
                          false ->
                              false
                      end
              end, Roles)
    end.

assert_api_can_be_used() ->
    menelaus_util:assert_is_45(),
    case cluster_compat_mode:is_cluster_50() of
        true ->
            ok;
        false ->
            menelaus_util:assert_is_enterprise()
    end.

handle_get_roles(Req) ->
    assert_api_can_be_used(),

    Params = Req:parse_qs(),
    Permission = proplists:get_value("permission", Params, undefined),

    Config = ns_config:get(),
    Roles = menelaus_roles:get_all_assignable_roles(Config),
    case filter_roles_by_permission(Config, Permission, Roles) of
        error ->
            menelaus_util:reply_json(Req, <<"Malformed permission.">>, 400);
        FilteredRoles ->
            Json = [{role_to_json(Role) ++ Props} || {Role, Props} <- FilteredRoles],
            menelaus_util:reply_json(Req, Json)
    end.

get_user_json(Identity, Props, Passwordless) ->
    Roles = proplists:get_value(roles, Props, []),
    Name = proplists:get_value(name, Props),
    get_user_json(Identity, Name, Passwordless, Roles).

get_user_json({Id, Domain}, Name, Passwordless, Roles) ->
    UserJson = [{id, list_to_binary(Id)},
                {domain, Domain},
                {roles, [{role_to_json(Role)} || Role <- Roles]}],
    UserJson1 =
        case Name of
            undefined ->
                UserJson;
            _ ->
                [{name, list_to_binary(Name)} | UserJson]
        end,
    UserJson2 =
        case Passwordless of
            false ->
                UserJson1;
            _ ->
                [{passwordless, true} | UserJson1]
        end,
    {UserJson2}.

handle_get_users(Path, Req) ->
    assert_api_can_be_used(),

    case cluster_compat_mode:is_cluster_50() of
        true ->
            handle_get_users_with_domain(Req, '_', Path);
        false ->
            handle_get_users_45(Req)
    end.

validate_get_users(Args, DomainAtom, HasStartFrom) ->
    R1 = menelaus_util:validate_integer(pageSize, {Args, [], []}),
    R2 = menelaus_util:validate_range(pageSize, ?MIN_USERS_PAGE_SIZE, ?MAX_USERS_PAGE_SIZE, R1),
    R3 = menelaus_util:validate_any_value(startFrom, R2),
    R4 =
        case HasStartFrom of
            false ->
                R3;
            true ->
                case DomainAtom of
                    '_' ->
                        R4_1 = menelaus_util:validate_required(startFromDomain, R3),
                        R4_2 = menelaus_util:validate_any_value(startFromDomain, R4_1),
                        menelaus_util:validate_by_fun(
                          fun (Value) ->
                                  case domain_to_atom(Value) of
                                      unknown ->
                                          {error, "Unknown user domain"};
                                      Atom ->
                                          {value, Atom}
                                  end
                          end, startFromDomain, R4_2);
                    _ ->
                        R4_1 = menelaus_util:validate_prohibited(startFromDomain, R3),
                        menelaus_util:return_value(startFromDomain, DomainAtom, R4_1)
                end
        end,
    menelaus_util:validate_unsupported_params(R4).

handle_get_users(Path, Domain, Req) ->
    menelaus_util:assert_is_50(),

    case domain_to_atom(Domain) of
        unknown ->
            menelaus_util:reply_json(Req, <<"Unknown user domain.">>, 404);
        DomainAtom ->
            handle_get_users_with_domain(Req, DomainAtom, Path)
    end.

handle_get_users_with_domain(Req, DomainAtom, Path) ->
    Query = Req:parse_qs(),

    case lists:keyfind("pageSize", 1, Query) of
        false ->
            handle_get_all_users(Req, {'_', DomainAtom});
        _ ->
            HasStartFrom = lists:keyfind("startFrom", 1, Query) =/= false,
            menelaus_util:execute_if_validated(
              fun (Values) ->
                      Start =
                          case proplists:get_value(startFrom, Values) of
                              undefined ->
                                  undefined;
                              U ->
                                  {U, proplists:get_value(startFromDomain, Values)}
                          end,
                      handle_get_users_page(Req, DomainAtom, Path,
                                            proplists:get_value(pageSize, Values),
                                            Start)
              end, Req, validate_get_users(Query, DomainAtom, HasStartFrom))
    end.

handle_get_users_45(Req) ->
    Users = menelaus_users:get_users_45(ns_config:latest()),
    Json = lists:map(
             fun ({{LdapUser, saslauthd}, Props}) ->
                     Roles = proplists:get_value(roles, Props, []),
                     get_user_json({LdapUser, external}, proplists:get_value(name, Props),
                                   false, Roles)
             end, Users),
    menelaus_util:reply_json(Req, Json).

handle_get_all_users(Req, Pattern) ->
    Passwordless = menelaus_users:get_passwordless(),
    pipes:run(menelaus_users:select_users(Pattern),
              [filter_out_invalid_roles(),
               jsonify_users(Passwordless),
               sjson:encode_extended_json([{compact, false},
                                           {strict, false}]),
               pipes:simple_buffer(2048)],
              menelaus_util:send_chunked(Req, 200, [{"Content-Type", "application/json"}])).

handle_get_user(Domain, UserId, Req) ->
    menelaus_util:assert_is_50(),
    case domain_to_atom(Domain) of
        unknown ->
            menelaus_util:reply_json(Req, <<"Unknown user domain.">>, 404);
        DomainAtom ->
            Identity = {UserId, DomainAtom},
            case menelaus_users:user_exists(Identity) of
                false ->
                    menelaus_util:reply_json(Req, <<"Unknown user.">>, 404);
                true ->
                    menelaus_util:reply_json(Req, get_user_json(Identity))
            end
    end.

filter_out_invalid_roles() ->
    Definitions = menelaus_roles:get_definitions(),
    AllPossibleValues = menelaus_roles:calculate_possible_param_values(ns_bucket:get_buckets()),
    ?make_transducer(
       begin
           pipes:foreach(
             ?producer(),
             fun ({Key, Props}) ->
                     NewProps =
                         menelaus_users:filter_out_invalid_roles(Props, Definitions,
                                                                 AllPossibleValues),
                     ?yield({Key, NewProps})
             end)
       end).

jsonify_users(Passwordless) ->
    ?make_transducer(
       begin
           ?yield(array_start),
           pipes:foreach(?producer(),
                         fun ({{user, Identity}, Props}) ->
                                 ?yield({json, get_user_json(Identity, Props,
                                                             lists:member(Identity, Passwordless))})
                         end),
           ?yield(array_end)
       end).

-record(skew, {skew, size, less_fun, filter, skipped = 0}).

add_to_skew(_El, undefined) ->
    undefined;
add_to_skew(El, #skew{skew = CouchSkew,
                      size = Size,
                      filter = Filter,
                      less_fun = LessFun,
                      skipped = Skipped} = Skew) ->
    case Filter(El, LessFun) of
        false ->
            Skew#skew{skipped = Skipped + 1};
        true ->
            CouchSkew1 = couch_skew:in(El, LessFun, CouchSkew),
            case couch_skew:size(CouchSkew1) > Size of
                true ->
                    {_, CouchSkew2} = couch_skew:out(LessFun, CouchSkew1),
                    Skew#skew{skew = CouchSkew2};
                false ->
                    Skew#skew{skew = CouchSkew1}
            end
    end.

skew_to_list(#skew{skew = CouchSkew,
                   less_fun = LessFun}) ->
    skew_to_list(CouchSkew, LessFun, []).

skew_to_list(CouchSkew, LessFun, Acc) ->
    case couch_skew:size(CouchSkew) of
        0 ->
            Acc;
        _ ->
            {El, NewSkew} = couch_skew:out(LessFun, CouchSkew),
            skew_to_list(NewSkew, LessFun, [El | Acc])
    end.

skew_size(#skew{skew = CouchSkew}) ->
    couch_skew:size(CouchSkew).

skew_out(#skew{skew = CouchSkew, less_fun = LessFun} = Skew) ->
    {El, NewCouchSkew} = couch_skew:out(LessFun, CouchSkew),
    {El, Skew#skew{skew = NewCouchSkew}}.

skew_min(undefined) ->
    undefined;
skew_min(#skew{skew = CouchSkew}) ->
    case couch_skew:size(CouchSkew) of
        0 ->
            undefined;
        _ ->
            couch_skew:min(CouchSkew)
    end.

skew_skipped(#skew{skipped = Skipped}) ->
    Skipped.

create_skews(Start, PageSize) ->
    SkewThis =
        #skew{
           skew = couch_skew:new(),
           size = PageSize + 1,
           less_fun = fun ({A, _}, {B, _}) ->
                              A >= B
                      end,
           filter = fun (El, LessFun) ->
                            Start =:= undefined orelse LessFun(El, {Start, x})
                    end},
    SkewPrev =
        case Start of
            undefined ->
                undefined;
            _ ->
                #skew{
                   skew = couch_skew:new(),
                   size = PageSize,
                   less_fun = fun ({A, _}, {B, _}) ->
                                      A < B
                              end,
                   filter = fun (El, LessFun) ->
                                    LessFun(El, {Start, x})
                            end}
        end,
    SkewLast =
        #skew{
           skew = couch_skew:new(),
           size = PageSize,
           less_fun = fun ({A, _}, {B, _}) ->
                              A < B
                      end,
           filter = fun (_El, _LessFun) ->
                            true
                    end},
    [SkewPrev, SkewThis, SkewLast].

add_to_skews(El, Skews) ->
    [add_to_skew(El, Skew) || Skew <- Skews].

build_link(Name, noparams, PageSize, _DomainAtom, Path) ->
    {Name, iolist_to_binary(
             io_lib:format("/~s?pageSize=~p", [Path, PageSize]))};
build_link(Name, {User, Domain}, PageSize, '_', Path) ->
    {Name, iolist_to_binary(
             io_lib:format("/~s?startFrom=~s&startFromDomain=~p&pageSize=~p",
                           [Path, User, Domain, PageSize]))};
build_link(Name, {User, _Domain}, PageSize, _DomainAtom, Path) ->
    {Name, iolist_to_binary(
             io_lib:format("/~s?startFrom=~s&pageSize=~p", [Path, User, PageSize]))}.

seed_links(Pairs) ->
    [{Name, {http_uri:encode(User), Domain}} || {Name, {User, Domain}} <- Pairs].

build_links(Links, PageSize, DomainAtom, Path) ->
    {links, {[build_link(Name, Identity, PageSize, DomainAtom, Path) || {Name, Identity} <- Links]}}.

json_from_skews([SkewPrev, SkewThis, SkewLast], PageSize, UserJson) ->
    {Users, Next} =
        case skew_size(SkewThis) of
            Size when Size =:= PageSize + 1 ->
                {{N, _}, NewSkew} = skew_out(SkewThis),
                {skew_to_list(NewSkew), N};
            _ ->
                {skew_to_list(SkewThis), undefined}
        end,
    {First, Prev} = case skew_min(SkewPrev) of
                        undefined ->
                            {undefined, undefined};
                        {P, _} ->
                            {noparams, P}
                    end,
    {Last, CorrectedNext} =
        case Next of
            undefined ->
                {undefined, Next};
            _ ->
                case skew_min(SkewLast) of
                    {L, _} when L < Next ->
                        {L, L};
                    {L, _} ->
                        {L, Next}
                end
        end,
    {[{skipped, skew_skipped(SkewThis)}, {users, [UserJson(El) || El <- Users]}],
     seed_links([{first, First}, {prev, Prev}, {next, CorrectedNext}, {last, Last}])}.

handle_get_users_page(Req, DomainAtom, Path, PageSize, Start) ->
    Passwordless = menelaus_users:get_passwordless(),
    {PageSkews, Total} =
        pipes:run(menelaus_users:select_users({'_', DomainAtom}),
                  filter_out_invalid_roles(),
                  ?make_consumer(
                     pipes:fold(
                       ?producer(),
                       fun ({{user, Identity}, Props}, {Skews, T}) ->
                               {add_to_skews({Identity, Props}, Skews), T + 1}
                       end, {create_skews(Start, PageSize), 0}))),
    UserJson =
        fun ({Identity, Props}) ->
                get_user_json(Identity, Props, lists:member(Identity, Passwordless))
        end,

    {JsonFromSkews, Links} = json_from_skews(PageSkews, PageSize, UserJson),

    Json = {[{total, Total} | [build_links(Links, PageSize, DomainAtom, Path) | JsonFromSkews]]},
    menelaus_util:reply_ok(Req, "application/json", misc:ejson_encode_pretty(Json)).

handle_whoami(Req) ->
    Identity = menelaus_auth:get_identity(Req),
    menelaus_util:reply_json(Req, get_user_json(Identity)).

get_user_json(Identity) ->
    Passwordless = menelaus_users:get_passwordless(),
    Definitions = menelaus_roles:get_definitions(),
    AllPossibleValues = menelaus_roles:calculate_possible_param_values(ns_bucket:get_buckets()),

    Roles = menelaus_roles:filter_out_invalid_roles(
              menelaus_roles:get_roles(Identity), Definitions, AllPossibleValues),
    Name = menelaus_users:get_user_name(Identity),
    get_user_json(Identity, Name, lists:member(Identity, Passwordless), Roles).

parse_until(Str, Delimeters) ->
    lists:splitwith(fun (Char) ->
                            not lists:member(Char, Delimeters)
                    end, Str).

role_to_atom(Role) ->
    list_to_existing_atom(string:to_lower(Role)).

parse_role(RoleRaw) ->
    try
        case parse_until(RoleRaw, "[") of
            {Role, []} ->
                role_to_atom(Role);
            {Role, "[*]"} ->
                {role_to_atom(Role), [any]};
            {Role, [$[ | ParamAndBracket]} ->
                case parse_until(ParamAndBracket, "]") of
                    {Param, "]"} ->
                        {role_to_atom(Role), [Param]};
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
role_to_string({Role, [any]}) ->
    lists:flatten(io_lib:format("~p[*]", [Role]));
role_to_string({Role, [{BucketName, _}]}) ->
    role_to_string({Role, [BucketName]});
role_to_string({Role, [BucketName]}) ->
    lists:flatten(io_lib:format("~p[~s]", [Role, BucketName])).

reply_bad_roles(Req, BadRoles) ->
    Str = string:join(BadRoles, ","),
    menelaus_util:reply_json(
      Req,
      iolist_to_binary(io_lib:format(
                         "Cannot assign roles to user because the following roles are unknown, "
                         "malformed or role parameters are undefined: [~s]", [Str])), 400).

domain_to_atom("local") ->
    local;
domain_to_atom("external") ->
    external;
domain_to_atom(_) ->
    unknown.

verify_length([P, Len]) ->
    length(P) >= Len.

verify_control_chars(P) ->
    lists:all(
      fun (C) ->
              C > 31 andalso C =/= 127
      end, P).

verify_utf8(P) ->
    couch_util:validate_utf8(P).

verify_lowercase(P) ->
    string:to_upper(P) =/= P.

verify_uppercase(P) ->
    string:to_lower(P) =/= P.

verify_digits(P) ->
    lists:any(
      fun (C) ->
              C > 47 andalso C < 58
      end, P).

password_special_characters() ->
    "@%+\\/'\"!#$^?:,(){}[]~`-_".

verify_special(P) ->
    lists:any(
      fun (C) ->
              lists:member(C, "@%+\\/'\"!#$^?:,(){}[]~`-_")
      end, P).

get_verifier(uppercase, P) ->
    {fun verify_uppercase/1, P, <<"The password must contain at least one uppercase letter">>};
get_verifier(lowercase, P) ->
    {fun verify_lowercase/1, P, <<"The password must contain at least one lowercase letter">>};
get_verifier(digits, P) ->
    {fun verify_digits/1, P, <<"The password must contain at least one digit">>};
get_verifier(special, P) ->
    {fun verify_special/1, P,
     list_to_binary("The password must contain at least one of the following characters: " ++
                        password_special_characters())}.

execute_verifiers([]) ->
    true;
execute_verifiers([{Fun, Arg, Error} | Rest]) ->
    case Fun(Arg) of
        true ->
            execute_verifiers(Rest);
        false ->
            Error
    end.

get_password_policy() ->
    {value, Policy} = ns_config:search(password_policy),
    MinLength = proplists:get_value(min_length, Policy),
    true = MinLength =/= undefined,
    MustPresent = proplists:get_value(must_present, Policy),
    true = MustPresent =/= undefined,
    {MinLength, MustPresent}.

validate_cred(undefined, _) -> <<"Field must be given">>;
validate_cred(P, password) ->
    {MinLength, MustPresent} = get_password_policy(),
    LengthError = io_lib:format("The password must be at least ~p characters long.", [MinLength]),

    Verifiers =
        [{fun verify_length/1, [P, MinLength], list_to_binary(LengthError)},
         {fun verify_utf8/1, P, <<"The password must be valid utf8">>},
         {fun verify_control_chars/1, P, <<"The password must not contain control characters">>}] ++
        [get_verifier(V, P) || V <- MustPresent],

    execute_verifiers(Verifiers);
validate_cred([], username) ->
    <<"Username must not be empty">>;
validate_cred(Username, username) when length(Username) > 128 ->
    <<"Username may not exceed 128 characters">>;
validate_cred(Username, username) ->
    V = lists:all(
          fun (C) ->
                  C > 32 andalso C =/= 127 andalso
                      not lists:member(C, "()<>@,;:\\\"/[]?={}")
          end, Username)
        andalso couch_util:validate_utf8(Username),

    V orelse
        <<"The username must not contain spaces, control or any of ()<>@,;:\\\"/[]?={} characters and must be valid utf8">>.

handle_put_user(Domain, UserId, Req) ->
    assert_api_can_be_used(),
    assert_no_users_upgrade(),

    case validate_cred(UserId, username) of
        true ->
            case domain_to_atom(Domain) of
                unknown ->
                    menelaus_util:reply_json(Req, <<"Unknown user domain.">>, 404);
                external = T ->
                    menelaus_util:assert_is_enterprise(),
                    handle_put_user_with_identity({UserId, T}, Req);
                local = T ->
                    menelaus_util:assert_is_50(),
                    handle_put_user_with_identity({UserId, T}, Req)
            end;
        Error ->
            menelaus_util:reply_global_error(Req, Error)
    end.

validate_password(R1) ->
    R2 = menelaus_util:validate_any_value(password, R1),
    menelaus_util:validate_by_fun(
      fun (P) ->
              case validate_cred(P, password) of
                  true ->
                      ok;
                  Error ->
                      {error, Error}
              end
      end, password, R2).

validate_put_user(Domain, Args) ->
    R0 = menelaus_util:validate_has_params({Args, [], []}),
    R1 = menelaus_util:validate_any_value(name, R0),
    R2 = menelaus_util:validate_required(roles, R1),
    R3 = menelaus_util:validate_any_value(roles, R2),
    R4 = case Domain of
             local ->
                 validate_password(R3);
             external ->
                 R3
         end,
    menelaus_util:validate_unsupported_params(R4).

handle_put_user_with_identity({_UserId, Domain} = Identity, Req) ->
    menelaus_util:execute_if_validated(
      fun (Values) ->
              handle_put_user_validated(Identity,
                                        proplists:get_value(name, Values),
                                        proplists:get_value(password, Values),
                                        proplists:get_value(roles, Values),
                                        Req)
      end, Req, validate_put_user(Domain, Req:parse_post())).

handle_put_user_validated(Identity, Name, Password, RawRoles, Req) ->
    Roles = parse_roles(RawRoles),

    BadRoles = [BadRole || {error, BadRole} <- Roles],
    case BadRoles of
        [] ->
            UniqueRoles = ordsets:to_list(ordsets:from_list(Roles)),
            case menelaus_users:store_user(Identity, Name, Password, UniqueRoles) of
                {commit, _} ->
                    ns_audit:set_user(Req, Identity, UniqueRoles, Name),
                    reply_put_delete_users(Req);
                {abort, {error, roles_validation, UnknownRoles}} ->
                    reply_bad_roles(Req, [role_to_string(UR) || UR <- UnknownRoles]);
                {abort, password_required} ->
                    menelaus_util:reply_error(Req, "password", "Password is required for new user.");
                {abort, too_many} ->
                    menelaus_util:reply_error(
                      Req, "_", "You cannot create any more users on Community Edition.");
                retry_needed ->
                    erlang:error(exceeded_retries)
            end;
        _ ->
            ParsedRoles = lists:filter(fun ({error, _}) ->
                                               false;
                                           (_) ->
                                               true
                                       end, Roles),
            {_, MoreBadRoles} = menelaus_roles:validate_roles(ParsedRoles, ns_config:latest()),
            reply_bad_roles(Req, BadRoles ++ [role_to_string(R) || R <- MoreBadRoles])
    end.

handle_delete_user(Domain, UserId, Req) ->
    menelaus_util:assert_is_45(),
    assert_no_users_upgrade(),

    case domain_to_atom(Domain) of
        unknown ->
            menelaus_util:reply_json(Req, <<"Unknown user domain.">>, 404);
        T ->
            Identity = {UserId, T},
            case menelaus_users:delete_user(Identity) of
                {commit, _} ->
                    ns_audit:delete_user(Req, Identity),
                    reply_put_delete_users(Req);
                {abort, {error, not_found}} ->
                    menelaus_util:reply_json(Req, <<"User was not found.">>, 404);
                retry_needed ->
                    erlang:error(exceeded_retries)
            end
    end.

reply_put_delete_users(Req) ->
    case cluster_compat_mode:is_cluster_50() of
        true ->
            menelaus_util:reply_json(Req, <<>>, 200);
        false ->
            handle_get_users_45(Req)
    end.

validate_change_password(Args) ->
    R0 = menelaus_util:validate_has_params({Args, [], []}),
    R1 = menelaus_util:validate_required(password, R0),
    R2 = menelaus_util:validate_any_value(password, R1),
    R3 = menelaus_util:validate_by_fun(
           fun (P) ->
                   case validate_cred(P, password) of
                       true ->
                           ok;
                       Error ->
                           {error, Error}
                   end
           end, password, R2),
    menelaus_util:validate_unsupported_params(R3).

handle_change_password(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_50(),

    case menelaus_auth:get_token(Req) of
        undefined ->
            case menelaus_auth:get_identity(Req) of
                {_, local} = Identity ->
                    handle_change_password_with_identity(Req, Identity);
                {_, admin} = Identity ->
                    handle_change_password_with_identity(Req, Identity);
                _ ->
                    menelaus_util:reply_json(
                      Req, <<"Changing of password is not allowed for this user.">>, 404)
            end;
        _ ->
            menelaus_util:require_auth(Req)
    end.

handle_change_password_with_identity(Req, Identity) ->
    menelaus_util:execute_if_validated(
      fun (Values) ->
              case do_change_password(Identity, proplists:get_value(password, Values)) of
                  ok ->
                      ns_audit:password_change(Req, Identity),
                      menelaus_util:reply(Req, 200);
                  user_not_found ->
                      menelaus_util:reply_json(Req, <<"User was not found.">>, 404);
                  unchanged ->
                      menelaus_util:reply(Req, 200)
              end
      end, Req, validate_change_password(Req:parse_post())).

do_change_password({_, local} = Identity, Password) ->
    menelaus_users:change_password(Identity, Password);
do_change_password({User, admin}, Password) ->
    ns_config_auth:set_credentials(admin, User, Password).

handle_settings_read_only_admin_name(Req) ->
    case ns_config_auth:get_user(ro_admin) of
        undefined ->
            menelaus_util:reply_not_found(Req);
        Name ->
            menelaus_util:reply_json(Req, list_to_binary(Name), 200)
    end.

handle_settings_read_only_user_post(Req) ->
    assert_no_users_upgrade(),

    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    U = proplists:get_value("username", PostArgs),
    P = proplists:get_value("password", PostArgs),
    Errors0 = [{K, V} || {K, V} <- [{username, validate_cred(U, username)},
                                    {password, validate_cred(P, password)}],
                         V =/= true],
    Errors = Errors0 ++
        case ns_config_auth:get_user(admin) of
            U ->
                [{username, <<"Read-only user cannot be same user as administrator">>}];
            _ ->
                []
        end,

    case Errors of
        [] ->
            case ValidateOnly of
                false ->
                    ns_config_auth:set_credentials(ro_admin, U, P),
                    ns_audit:password_change(Req, {U, ro_admin});
                true ->
                    true
            end,
            menelaus_util:reply_json(Req, [], 200);
        _ ->
            menelaus_util:reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400)
    end.

handle_read_only_user_delete(Req) ->
    assert_no_users_upgrade(),

    case ns_config_auth:get_user(ro_admin) of
        undefined ->
            menelaus_util:reply_json(Req, <<"Read-Only admin does not exist">>, 404);
        User ->
            ns_config_auth:unset_credentials(ro_admin),
            ns_audit:delete_user(Req, {User, ro_admin}),
            menelaus_util:reply_json(Req, [], 200)
    end.

handle_read_only_user_reset(Req) ->
    assert_no_users_upgrade(),

    case ns_config_auth:get_user(ro_admin) of
        undefined ->
            menelaus_util:reply_json(Req, <<"Read-Only admin does not exist">>, 404);
        ROAName ->
            ReqArgs = Req:parse_post(),
            NewROAPass = proplists:get_value("password", ReqArgs),
            case validate_cred(NewROAPass, password) of
                true ->
                    ns_config_auth:set_credentials(ro_admin, ROAName, NewROAPass),
                    ns_audit:password_change(Req, {ROAName, ro_admin}),
                    menelaus_util:reply_json(Req, [], 200);
                Error ->
                    menelaus_util:reply_json(Req, {struct, [{errors, {struct, [{password, Error}]}}]}, 400)
            end
    end.

gen_password(Length) ->
    Letters = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*?",
    random:seed(os:timestamp()),
    get_random_string(Length, Letters).

get_random_string(Length, AllowedChars) ->
    lists:foldl(fun(_, Acc) ->
                        [lists:nth(random:uniform(length(AllowedChars)),
                                   AllowedChars)]
                            ++ Acc
                end, [], lists:seq(1, Length)).

reset_admin_password(Password) ->
    {User, Error} =
        case ns_config_auth:get_user(admin) of
            undefined ->
                {undefined, "Failed to reset administrative password. Node is not initialized."};
            U ->
                {U, case validate_cred(Password, password) of
                        true ->
                            undefined;
                        ErrStr ->
                            ErrStr
                    end}
        end,

    case Error of
        undefined ->
            ok = ns_config_auth:set_credentials(admin, User, Password),
            ns_audit:password_change(undefined, {User, admin}),
            {ok, Password};
        _ ->
            {error, Error}
    end.

handle_reset_admin_password(Req) ->
    assert_no_users_upgrade(),

    menelaus_util:ensure_local(Req),
    Password =
        case proplists:get_value("generate", Req:parse_qs()) of
            "1" ->
                gen_password(8);
            _ ->
                PostArgs = Req:parse_post(),
                proplists:get_value("password", PostArgs)
        end,
    case Password of
        undefined ->
            menelaus_util:reply_error(Req, "password", "Password should be supplied");
        _ ->
            case reset_admin_password(Password) of
                {ok, Password} ->
                    menelaus_util:reply_json(Req, {struct, [{password, list_to_binary(Password)}]});
                {error, Error} ->
                    menelaus_util:reply_global_error(Req, Error)
            end
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
                    parse_vertices(Rest2, [{list_to_rbac_atom(Name),
                                            case Param of
                                                "." ->
                                                    any;
                                                _ ->
                                                    Param
                                            end} | Acc]);
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
    B = term_to_binary(
          [cluster_compat_mode:get_compat_version(Config),
           menelaus_users:get_users_version(),
           [{Name, proplists:get_value(uuid, BucketConfig)} ||
               {Name, BucketConfig} <- ns_bucket:get_buckets(Config)],
           ns_config_auth:get_no_auth_buckets(Config)]),
    base64:encode(crypto:hash(sha, B)).

handle_check_permission_for_cbauth(Req) ->
    Params = Req:parse_qs(),
    Identity = {proplists:get_value("user", Params),
                list_to_existing_atom(proplists:get_value("domain", Params))},
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
vertex_to_iolist({Atom, any}) ->
    [atom_to_list(Atom), "[.]"];
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

forbidden_response(Permissions) when is_list(Permissions) ->
    {[{message, <<"Forbidden. User needs one of the following permissions">>},
      {permissions, format_permissions(Permissions)}]};
forbidden_response(Permission) ->
    forbidden_response([Permission]).

handle_get_password_policy(Req) ->
    menelaus_util:assert_is_50(),
    {MinLength, MustPresent} = get_password_policy(),
    menelaus_util:reply_json(Req,
                             {[{minLength, MinLength},
                               {enforceUppercase, lists:member(uppercase, MustPresent)},
                               {enforceLowercase, lists:member(lowercase, MustPresent)},
                               {enforceDigits, lists:member(digits, MustPresent)},
                               {enforceSpecialChars, lists:member(special, MustPresent)}]}).

validate_post_password_policy(Args) ->
    R0 = menelaus_util:validate_has_params({Args, [], []}),
    R1 = menelaus_util:validate_required(minLength, R0),
    R2 = menelaus_util:validate_integer(minLength, R1),
    R3 = menelaus_util:validate_range(minLength, 0, 100, R2),
    R4 = menelaus_util:validate_boolean(enforceUppercase, R3),
    R5 = menelaus_util:validate_boolean(enforceLowercase, R4),
    R6 = menelaus_util:validate_boolean(enforceDigits, R5),
    R7 = menelaus_util:validate_boolean(enforceSpecialChars, R6),
    menelaus_util:validate_unsupported_params(R7).

must_present_value(JsonField, MustPresentAtom, Args) ->
    case proplists:get_value(JsonField, Args) of
        true ->
            [MustPresentAtom];
        _ ->
            []
    end.

handle_post_password_policy(Req) ->
    menelaus_util:execute_if_validated(
      fun (Values) ->
              Policy = [{min_length, proplists:get_value(minLength, Values)},
                        {must_present,
                         must_present_value(enforceUppercase, uppercase, Values) ++
                             must_present_value(enforceLowercase, lowercase, Values) ++
                             must_present_value(enforceDigits, digits, Values) ++
                             must_present_value(enforceSpecialChars, special, Values)}],
              ns_config:set(password_policy, Policy),
              ns_audit:password_policy(Req, Policy),
              menelaus_util:reply(Req, 200)
      end, Req, validate_post_password_policy(Req:parse_post())).

assert_no_users_upgrade() ->
    case menelaus_users:upgrade_status() of
        undefined ->
            ok;
        started ->
            erlang:throw({web_exception,
                          503,
                          "Not allowed during cluster upgrade.",
                          []})
    end.

%% Tests
parse_roles_test() ->
    Res = parse_roles("admin, bucket_admin[test.test], bucket_admin[*], no_such_atom, bucket_admin[default"),
    ?assertMatch([admin,
                  {bucket_admin, ["test.test"]},
                  {bucket_admin, [any]},
                  {error, "no_such_atom"},
                  {error, "bucket_admin[default"}], Res).

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

format_permissions_test() ->
    Permissions = [{[{bucket, any}, views], write},
                   {[{bucket, "default"}], all},
                   {[], all},
                   {[admin, diag], read},
                   {[{bucket, "test"}, xdcr], [write, execute]}],
    Formatted = [<<"cluster.bucket[.].views!write">>,
                 <<"cluster.bucket[default]!all">>,
                 <<"cluster!all">>,
                 <<"cluster.admin.diag!read">>,
                 <<"cluster.bucket[test].xdcr!write">>,
                 <<"cluster.bucket[test].xdcr!execute">>],
    ?assertEqual(
       lists:sort(Formatted),
       lists:sort(format_permissions(Permissions))).

toy_users(First, Last) ->
    [{{lists:flatten(io_lib:format("a~b", [U])), local}, []} || U <- lists:seq(First, Last)].

process_toy_users(Users, Start, PageSize) ->
    {JsonFromSkews, Links} =
        json_from_skews(
          lists:foldl(
            fun (U, Skews) ->
                    add_to_skews(U, Skews)
            end, create_skews(Start, PageSize), Users),
          PageSize, fun (U) -> U end),
    {lists:sort(JsonFromSkews), lists:sort(Links)}.

toy_result(Params, Links) ->
    {lists:sort(Params), lists:sort(seed_links(Links))}.

no_users_no_params_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, []}],
         []),
       process_toy_users([], undefined, 3)).

no_users_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, []}],
         []),
       process_toy_users([], {"a14", local}, 3)).

one_user_no_params_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, toy_users(10, 10)}],
         []),
       process_toy_users(toy_users(10, 10), undefined, 3)).

first_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, toy_users(10, 12)}],
         [{last, {"a28", local}},
          {next, {"a13", local}}]),
       process_toy_users(toy_users(10, 30), undefined, 3)).

first_page_with_params_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, toy_users(10, 12)}],
         [{last, {"a28", local}},
          {next, {"a13", local}}]),
       process_toy_users(toy_users(10, 30), {"a10", local}, 3)).

middle_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 4},
          {users, toy_users(14, 16)}],
         [{first, noparams},
          {prev, {"a11", local}},
          {last, {"a28", local}},
          {next, {"a17", local}}]),
       process_toy_users(toy_users(10, 30), {"a14", local}, 3)).

middle_page_non_existent_user_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 5},
          {users, toy_users(15, 17)}],
         [{first, noparams},
          {prev, {"a12", local}},
          {last, {"a28", local}},
          {next, {"a18", local}}]),
       process_toy_users(toy_users(10, 30), {"a14b", local}, 3)).

near_the_end_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 17},
          {users, toy_users(27, 29)}],
         [{first, noparams},
          {prev, {"a24", local}},
          {last, {"a28", local}},
          {next, {"a28", local}}]),
       process_toy_users(toy_users(10, 30), {"a27", local}, 3)).

at_the_end_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 19},
          {users, toy_users(29, 30)}],
         [{first, noparams},
          {prev, {"a26", local}}]),
       process_toy_users(toy_users(10, 30), {"a29", local}, 3)).

after_the_end_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 21},
          {users, []}],
         [{first, noparams},
          {prev, {"a28", local}}]),
       process_toy_users(toy_users(10, 30), {"b29", local}, 3)).

validate_cred_username_test() ->
    LongButValid = "Username_that_is_127_characters_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    ?assertEqual(127, length(LongButValid)),
    ?assertEqual(true, validate_cred("valid", username)),
    ?assertEqual(true, validate_cred(LongButValid, username)),
    ?assertNotEqual(true, validate_cred([], username)),
    ?assertNotEqual(true, validate_cred("", username)),
    ?assertNotEqual(true, validate_cred(LongButValid ++ "more_than_128_characters", username)),
    ?assertNotEqual(true, validate_cred([7], username)),
    ?assertNotEqual(true, validate_cred([127], username)),
    ?assertNotEqual(true, validate_cred("=", username)),

    %%% The following block does not work after compilation with erralng 16
    %%% due to non-native utf8 enoding of strings in .beam compiled files.
    %%% TODO: re-enable this after upgrading to eralng 19+.
    % Utf8 = "ξ",
    % ?assertEqual(1,length(Utf8)),
    % ?assertEqual(true, validate_cred(Utf8, username)),                  % "ξ" is codepoint 958
    % ?assertEqual(true, validate_cred(LongButValid ++ Utf8, username)),  % 128 code points
    ok.
