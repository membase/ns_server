%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% @doc Web server for menelaus.

-module(menelaus_auth).
-author('Northscale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").

-export([apply_auth/3,
         apply_ro_auth/3,
         apply_auth_bucket/5,
         filter_accessible_buckets/2,
         is_bucket_accessible/2,
         apply_auth_any_bucket/3,
         extract_auth/1,
         extract_auth_user/1,
         parse_user_password/1,
         is_under_role/2,
         extract_ui_auth_token/1,
         complete_uilogin/4,
         reject_uilogin/2,
         complete_uilogout/1,
         maybe_refresh_token/1,
         get_user/1,
         get_token/1,
         get_role/1,
         get_source/1,
         validate_request/1,
         verify_login_creds/2]).

%% External API

%% Respond with 401 Auth. required
require_auth(Req) ->
    case Req:get_header_value("invalid-auth-response") of
        "on" ->
            %% We need this for browsers that display auth
            %% dialog when faced with 401 with
            %% WWW-Authenticate header response, even via XHR
            menelaus_util:reply(Req, 401);
        _ ->
            menelaus_util:reply(Req, 401, [{"WWW-Authenticate",
                                            "Basic realm=\"Couchbase Server Admin / REST\""}])
    end.

%% Returns list of accessible buckets for current credentials. Admin
%% credentials grant access to all buckets. Bucket credentials grant
%% access to that bucket only. No credentials cause this function to
%% return empty list.
%%
%% NOTE: this means that listing buckets always requires non-empty
%% credentials
filter_accessible_buckets(BucketsAll, Req) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    case get_role(Req) of
        "admin" ->
            BucketsAll;
        "ro_admin" ->
            BucketsAll;
        _ ->
            F = bucket_auth_fun(UserPassword),
            [Bucket || Bucket <- BucketsAll, F(Bucket)]
    end.

%% returns true if given bucket is accessible with current
%% credentials. No auth buckets are always accessible. SASL auth
%% buckets are accessible only with admin or bucket credentials.
-spec is_bucket_accessible({string(), list()}, any()) -> boolean().
is_bucket_accessible(BucketTuple, Req) ->
    Auth = menelaus_auth:extract_auth(Req),
    case check_admin_auth_int(Auth) of
        {true, _, _, _} ->
            true;
        false ->
            F = bucket_auth_fun(Auth),
            case F(BucketTuple) of
                true ->
                    true;
                false ->
                    case check_ldap_int(Auth, [admin]) of
                        {true, _, _} ->
                            true;
                        false ->
                            false
                    end
            end
    end.

apply_auth(Req, F, Args) ->
    UserPassword = extract_auth(Req),
    apply_auth_with_auth_data(Req, F, Args, UserPassword, fun check_admin_auth/2).

apply_ro_auth(Req, F, Args) ->
    UserPassword = extract_auth(Req),
    apply_auth_with_auth_data(Req, F, Args, UserPassword, fun check_read_only_auth/2).

apply_auth_with_auth_data(Req, F, Args, UserPassword, AuthFun) ->
    case AuthFun(Req, UserPassword) of
        {true, NewReq} ->
            apply(F, Args ++ [NewReq]);
        _ ->
            require_auth(Req)
    end.


get_cookies(Req) ->
    case Req:get_header_value("Cookie") of
        undefined -> [];
        RawCookies ->
            RV = mochiweb_cookies:parse_cookie(RawCookies),
            RV
    end.

lookup_cookie(Req, Cookie) ->
    proplists:get_value(Cookie, get_cookies(Req)).

ui_auth_cookie_name(Req) ->
    %% NOTE: cookies are _not_ per-port and in general quite
    %% unexpectedly a stupid piece of mess. In order to have working
    %% dev mode clusters where different nodes are at different ports
    %% we use different cookie names for different host:port
    %% combination.
    case Req:get_header_value("host") of
        undefined ->
            "ui-auth";
        Host ->
            "ui-auth-" ++ mochiweb_util:quote_plus(Host)
    end.

extract_ui_auth_token(Req) ->
    case Req:get_header_value("ns_server-auth-token") of
        undefined ->
            lookup_cookie(Req, ui_auth_cookie_name(Req));
        T ->
            T
    end.

generate_auth_cookie(Req, Token) ->
    Options = [{path, "/"}, {http_only, true}],
    mochiweb_cookies:cookie(ui_auth_cookie_name(Req), Token, Options).

kill_auth_cookie(Req) ->
    Options = [{path, "/"}, {http_only, true}],
    {Name, Content} = mochiweb_cookies:cookie(ui_auth_cookie_name(Req), "", Options),
    {Name, Content ++ "; expires=Thu, 01 Jan 1970 00:00:00 GMT"}.

complete_uilogin(Req, User, Role, Src) ->
    Token = menelaus_ui_auth:generate_token({User, Role, Src}),
    CookieHeader = generate_auth_cookie(Req, Token),
    ns_audit:login_success(store_user_info(Req, User, Role, Src, Token)),
    menelaus_util:reply(Req, 200, [CookieHeader]).

reject_uilogin(Req, User) ->
    ns_audit:login_failure(store_user_info(Req, User, undefined, undefined, undefined)),
    menelaus_util:reply(Req, 400).

complete_uilogout(Req) ->
    CookieHeader = kill_auth_cookie(Req),
    menelaus_util:reply(Req, 200, [CookieHeader]).

maybe_refresh_token(Req) ->
    case menelaus_auth:extract_auth(Req) of
        {token, Token} ->
            case menelaus_ui_auth:maybe_refresh(Token) of
                nothing ->
                    [];
                {new_token, NewToken} ->
                    [generate_auth_cookie(Req, NewToken)]
            end;
        _ ->
            []
    end.

validate_request(Req) ->
    undefined = Req:get_header_value("menelaus_auth-user"),
    undefined = Req:get_header_value("menelaus_auth-role"),
    undefined = Req:get_header_value("menelaus_auth-token"),
    undefined = Req:get_header_value("menelaus_auth-source").

store_user_info(Req, User, Role, Source, Token) ->
    Headers = Req:get(headers),
    H1 = mochiweb_headers:enter("menelaus_auth-user", User, Headers),
    H2 = mochiweb_headers:enter("menelaus_auth-role", Role, H1),
    H3 = mochiweb_headers:enter("menelaus_auth-token", Token, H2),
    H4 = mochiweb_headers:enter("menelaus_auth-source", Source, H3),
    mochiweb_request:new(Req:get(socket), Req:get(method), Req:get(raw_path), Req:get(version), H4).

get_user(Req) ->
    Req:get_header_value("menelaus_auth-user").

get_token(Req) ->
    Req:get_header_value("menelaus_auth-token").

get_role(Req) ->
    Req:get_header_value("menelaus_auth-role").

get_source(Req) ->
    Req:get_header_value("menelaus_auth-source").

%% applies given function F if current credentials allow access to at
%% least single SASL-auth bucket. So admin credentials and bucket
%% credentials works. Other credentials do not allow access. Empty
%% credentials are not allowed too.
apply_auth_any_bucket(Req, F, Args) ->
    case Req:get_header_value("ns_server-ui") of
        "yes" ->
            apply_ro_auth(Req, F, Args);
        _ ->
            UserPassword = extract_auth(Req),
            case check_auth_any_bucket(Req, UserPassword) of
                {true, NewReq} ->
                    apply(F, Args ++ [NewReq]);
                false ->
                    require_auth(Req)
            end
    end.

store_bucket_auth(Req, Auth) ->
    {User, Role} = case Auth of
                       {UserX, _} ->
                           {UserX, bucket};
                       undefined ->
                           {undefined, undefined}
                   end,
    store_user_info(Req, User, Role, builtin, undefined).

%% Checks if given credentials allow access to any SASL-auth
%% bucket.
check_auth_any_bucket(Req, Auth) ->
    case check_read_only_auth_no_ldap(Req, Auth) of
        {true, _NewReq} = RV ->
            RV;
        false ->
            Buckets = ns_bucket:get_buckets(),
            case lists:any(bucket_auth_fun(Auth), Buckets) of
                true ->
                    {true, store_bucket_auth(Req, Auth)};
                false ->
                    check_ldap(Req, Auth, [ro_admin, admin])
            end
    end.

apply_auth_bucket(Req, F, Args, BucketId, ReadOnlyOk) ->
    case ns_bucket:get_bucket(BucketId) of
        {ok, BucketConf} ->
            case Req:get_header_value("ns_server-ui") of
                "yes" ->
                    case ReadOnlyOk of
                        true ->
                            apply_ro_auth(Req, F, Args);
                        false ->
                            apply_auth(Req, F, Args)
                    end;
                _ ->
                    Auth = extract_auth(Req),
                    case check_auth_bucket(Req, Auth, {BucketId, BucketConf}, ReadOnlyOk) of
                        {true, NewReq} ->
                            menelaus_web_buckets:checking_bucket_uuid(
                              NewReq, BucketConf,
                              fun () ->
                                      apply(F, Args ++ [NewReq])
                              end);
                        false ->
                            require_auth(Req)
                    end
            end;
        not_present ->
            menelaus_util:reply_not_found(Req)
    end.

check_auth_bucket(Req, Auth, BucketTuple, ReadOnlyOk) ->
    RV = case ReadOnlyOk of
             true ->
                 check_read_only_auth_no_ldap(Req, Auth);
             false ->
                 check_admin_auth_no_ldap(Req, Auth)
         end,
    case RV of
        {true, _NewReq} ->
            RV;
        false ->
            F = bucket_auth_fun(Auth),
            case F(BucketTuple) of
                true ->
                    {true, store_bucket_auth(Req, Auth)};
                false ->
                    AllowedRoles = case ReadOnlyOk of
                                       true ->
                                           [ro_admin, admin];
                                       false ->
                                           [admin]
                                   end,
                    check_ldap(Req, Auth, AllowedRoles)
            end
    end.

check_admin_auth(Req, Auth) ->
    case check_admin_auth_no_ldap(Req, Auth) of
        false ->
            check_ldap(Req, Auth, [admin]);
        RV ->
            RV
    end.

check_admin_auth_no_ldap(Req, Auth) ->
    case check_admin_auth_int(Auth) of
        {true, User, Source, Token} ->
            {true, store_user_info(Req, User, admin, Source, Token)};
        false ->
            false
    end.

%% checks if given credentials are admin credentials
check_admin_auth_int({token, Token}) ->
    case menelaus_ui_auth:check(Token) of
        {ok, {User, admin, Source}} ->
            {true, User, Source, Token};
        _ ->
            % An undefined user means no login/password auth check.
            case ns_config_auth:get_user(admin) of
                undefined ->
                    {true, undefined, undefined, Token};
                _ ->
                    false
            end
    end;
check_admin_auth_int({User, Password}) ->
    case ns_config_auth:authenticate(admin, User, Password) of
        true ->
            {true, User, builtin, undefined};
        false ->
            false
    end;
check_admin_auth_int(undefined) ->
    case ns_config_auth:get_user(admin) of
        undefined ->
            {true, undefined, undefined, undefined};
        _ ->
            false
    end.

check_read_only_auth(Req, Auth) ->
    case check_read_only_auth_no_ldap(Req, Auth) of
        false ->
            check_ldap(Req, Auth, [ro_admin, admin]);
        RV ->
            RV
    end.

check_read_only_auth_no_ldap(Req, Auth) ->
    case check_read_only_auth_int(Auth) of
        {true, User, Source, Token} ->
            {true, store_user_info(Req, User, ro_admin, Source, Token)};
        false ->
            check_admin_auth_no_ldap(Req, Auth)
    end.

check_read_only_auth_int({token, Token}) ->
    case menelaus_ui_auth:check(Token) of
        {ok, {User, ro_admin, Source}} ->
            {true, User, Source, Token};
        _ ->
            false
    end;
check_read_only_auth_int({User, Password}) ->
    case ns_config_auth:authenticate(ro_admin, User, Password) of
        true ->
            {true, User, builtin, undefined};
        false ->
            false
    end;
check_read_only_auth_int(undefined) ->
    false.

extract_auth_user(Req) ->
    case Req:get_header_value("authorization") of
        "Basic " ++ Value ->
            parse_user(base64:decode_to_string(Value));
        _ -> undefined
    end.

-spec extract_auth(any()) -> {User :: string(), Password :: string()}
                                 | {token, string()} | undefined.
extract_auth(Req) ->
    case Req:get_header_value("ns_server-ui") of
        "yes" ->
            case extract_ui_auth_token(Req) of
                undefined -> undefined;
                Token -> {token, Token}
            end;
        _ ->
            case Req:get_header_value("authorization") of
                "Basic " ++ Value ->
                    parse_user_password(base64:decode_to_string(Value));
                _ ->
                    Method = Req:get(method),
                    case Method =:= 'GET' orelse Method =:= 'HEAD' of
                        true ->
                            case extract_ui_auth_token(Req) of
                                undefined -> undefined;
                                Token -> {token, Token}
                            end;
                        _ ->
                            undefined
                    end
            end
    end.

parse_user_password(UserPasswordStr) ->
    case string:chr(UserPasswordStr, $:) of
        0 ->
            case UserPasswordStr of
                "" ->
                    undefined;
                _ ->
                    {UserPasswordStr, ""}
            end;
        I ->
            {string:substr(UserPasswordStr, 1, I - 1),
             string:substr(UserPasswordStr, I + 1)}
    end.

parse_user(UserPasswordStr) ->
    case string:tokens(UserPasswordStr, ":") of
        [] -> undefined;
        [User] -> User;
        [User, _Password] -> User
    end.

%% returns function that when applied to bucket <name, config> tuple
%% returns if UserPassword credentials allow access to that bucket.
%%
%% NOTE: that no-auth buckets are always accessible even without
%% password at all
bucket_auth_fun(Auth) ->
    fun ({BucketName, BucketProps}) ->
            case {proplists:get_value(auth_type, BucketProps),
                  proplists:get_value(sasl_password, BucketProps),
                  Auth} of
                {none, _, undefined} ->
                    true;
                {none, _, {BucketName, ""}} ->
                    true;
                {sasl, "", undefined} ->
                    true;
                {sasl, BucketPassword, {BucketName, BucketPassword}} ->
                    true;
                _ ->
                    false
            end
    end.

is_under_role(Req, Role) when is_atom(Role) ->
    get_role(Req) =:= atom_to_list(Role).

check_ldap(Req, Auth, AllowedRoles) ->
    case check_ldap_int(Auth, AllowedRoles) of
        {true, User, Role} ->
            {true, store_user_info(Req, User, Role, saslauthd, undefined)};
        false ->
            false
    end.

check_ldap_int({token, _Token}, _) ->
    false;
check_ldap_int({User, Password}, AllowedRoles) ->
    Role = saslauthd_auth:check(User, Password),
    case lists:member(Role, AllowedRoles) of
        true ->
            {true, User, Role};
        false ->
            false
    end;
check_ldap_int(undefined, _) ->
    false.

verify_login_creds(User, Password) ->
    case ns_config_auth:authenticate(admin, User, Password) of
        true ->
            {ok, admin, builtin};
        false ->
            case ns_config_auth:authenticate(ro_admin, User, Password) of
                true ->
                    {ok, ro_admin, builtin};
                false ->
                    case saslauthd_auth:check(User, Password) of
                        admin ->
                            {ok, admin, saslauthd};
                        ro_admin ->
                            {ok, ro_admin, saslauthd};
                        false ->
                            false;
                        {error, Error} ->
                            {error, Error}
                    end
            end
    end.

-ifdef(EUNIT).

-record(test_data, {admin = undefined,
                    ro_admin = undefined,
                    buckets = [],
                    ldap_users = [],
                    tokens = []}).

t_seed(Data) ->
    ets:insert(state, {data, Data}).

t_get_data() ->
    [{data, Data}] = ets:lookup(state, data),
    Data.

t_setup() ->
    Reply =
        fun ({_, 401, _}, _) ->
                ets:insert(state, {result, require_auth}),
                require_auth
        end,

    ReplyNotFound =
        fun ({_}, _) ->
                ets:insert(state, {result, not_found}),
                not_found
        end,


    GetUser =
        fun ({admin}, _) ->
                Data = t_get_data(),
                Data#test_data.admin
        end,

    CheckConfig =
        fun ({admin, User, Password}, _) ->
                Data = t_get_data(),
                case Data#test_data.admin of
                    undefined ->
                        true;
                    {User, Password} ->
                        true;
                    _ ->
                        false
                end;
            ({ro_admin, User, Password}, _) ->
                Data = t_get_data(),
                Data#test_data.ro_admin =:= {User, Password}
        end,

    CheckLdap =
        fun ({User, Password}, _) ->
                Data = t_get_data(),
                [{ldap_count, C}] = ets:lookup(state, ldap_count),
                ets:insert(state, {ldap_count, C + 1}),
                case lists:keyfind({User, Password}, 1, Data#test_data.ldap_users) of
                    false ->
                        false;
                    {{User, Password}, Role} ->
                        Role
                end
        end,

    CheckToken =
        fun ({Token}, _) ->
                Data = t_get_data(),
                case lists:keyfind(Token, 1, Data#test_data.tokens) of
                    {Token, Ret} ->
                        {ok, Ret};
                    false ->
                        false
                end
        end,

    GetBucket =
        fun ({BucketId}, _) ->
                Data = t_get_data(),
                case lists:keyfind(BucketId, 1, Data#test_data.buckets) of
                    {BucketId, BucketConf} ->
                        {ok, BucketConf};
                    false ->
                        not_present
                end
        end,

    GetBuckets =
        fun ({}, _) ->
                Data = t_get_data(),
                Data#test_data.buckets
        end,

    CheckingBucketUUID =
        fun ({_Req, _BucketConf, F}, _) ->
                F()
        end,

    Tid = ets:new(state, [named_table, public]),

    Funs =
        [{menelaus_util, reply, 3, Reply},
         {menelaus_util, reply_not_found, 1, ReplyNotFound},
         {ns_config_auth, get_user, 1, GetUser},
         {ns_config_auth, authenticate, 3, CheckConfig},
         {saslauthd_auth, check, 2, CheckLdap},
         {menelaus_ui_auth, check, 1, CheckToken},
         {ns_bucket, get_bucket, 1, GetBucket},
         {ns_bucket, get_buckets, 0, GetBuckets},
         {menelaus_web_buckets, checking_bucket_uuid, 3, CheckingBucketUUID}],

    {Tid, lists:foldl(
            fun ({Module, Name, Arity, Fun}, Mocked) ->
                    NewMocked =
                        case lists:keyfind(Module, 1, Mocked) of
                            false ->
                                {ok, Pid} = mock:mock(Module),
                                [{Module, Pid} | Mocked];
                            _ ->
                                Mocked
                        end,
                    ok = mock:expects(Module, Name, fun (T) -> tuple_size(T) =:= Arity end,
                                      Fun, {at_least, 0}),
                    NewMocked
            end, [], Funs)}.

t_teardown({Tid, Mods}) ->
    ets:delete(Tid),

    lists:foreach(
      fun ({Module, Pid}) ->
              unlink(Pid),
              exit(Pid, kill),
              misc:wait_for_process(Pid, infinity),

              code:purge(Module),
              true = code:delete(Module)
      end, Mods),
    ok.

all_test_() ->
    [{setup, spawn, fun t_setup/0, fun t_teardown/1,
      [fun test_no_admin_anonymous/0,
       fun test_no_admin_token/0,
       fun test_no_admin_basic_auth/0,
       fun test_admin_auth/0,
       fun test_ro_admin_auth/0,
       fun test_any_bucket_anonymous/0,
       fun test_any_bucket/0,
       fun test_bucket/0,
       fun test_filter_accessible_buckets/0,
       fun test_is_bucket_accessible/0
      ]}].

t_start(Message, Args) ->
    ?debugFmt(Message, Args),
    t_clean().

t_start(Message) ->
    ?debugMsg(Message),
    t_clean().

t_clean() ->
    ets:insert(state, {result, undefined}),
    ets:insert(state, {ldap_count, 0}).

t_success(_, Req) ->
    ets:insert(state, {result, {ok, Req}}).

t_print_ldap_count() ->
    [{ldap_count, C}] = ets:lookup(state, ldap_count),
    ?debugFmt("ldap server was accessed ~p times~n", [C]).

t_assert_result({User, Role, Source, Token}) ->
    t_assert_success(User, Role, Source, Token);
t_assert_result(Result) ->
    t_print_ldap_count(),
    ?assertEqual([{result, Result}], ets:lookup(state, result)).

t_assert_success(User, Role, Source, Token) ->
    t_print_ldap_count(),
    [{result, {ok, R}}] = ets:lookup(state, result),
    ?assertEqual({User, Role, Source, Token},
                 {get_user(R), get_role(R), get_source(R), get_token(R)}).

t_new_request({token, Token}) ->
    t_new_request([{"ns_server-auth-token", Token}, {"ns_server-ui", "yes"}]);
t_new_request({User, Password}) ->
    t_new_request(menelaus_rest:add_basic_auth([], User, Password));
t_new_request(Headers) ->
    mochiweb_request:new(
      undefined, "GET", "/blah", {1, 1}, mochiweb_headers:make(Headers)).

t_assert_ldap(Count) ->
    ?assertEqual([{ldap_count, Count}], ets:lookup(state, ldap_count)).

t_assert_buckets(Expected, Actual) when is_atom(Actual) ->
    ?assertEqual(Expected, Actual);
t_assert_buckets(Expected, Actual) ->
    t_print_ldap_count(),
    ActualNames = [Name || {Name, _} <- Actual],
    ?assertEqual(lists:sort(Expected), lists:sort(ActualNames)).

t_sample_buckets() ->
    [{"b_noauth", [{auth_type, none}]},
     {"b_empty_pass", [{auth_type, sasl}, {sasl_password, ""}]},
     {"b_auth", [{auth_type, sasl}, {sasl_password, "pwd5"}]}].

t_seed_sample_data() ->
    t_seed_sample_data(["b_noauth", "b_empty_pass", "b_auth"]).

t_seed_sample_data(BucketNames) ->
    AllBuckets = t_sample_buckets(),
    Buckets = [lists:keyfind(Bucket, 1, AllBuckets) ||
                  Bucket <- BucketNames],
    t_seed(
      #test_data{
         admin = {"Admin", "pwd1"},
         ro_admin = {"Roadmin", "pwd2"},
         buckets = Buckets,
         ldap_users = [{{"Ldapadmin", "pwd3"}, admin},
                       {{"Ldapro", "pwd4"}, ro_admin}],
         tokens = [{"admin_token", {"Admin", admin, "builtin"}},
                   {"ro_admin_token", {"Roadmin", ro_admin, "builtin"}},
                   {"ldap_admin_token", {"Ldapadmin", admin, "saslauthd"}},
                   {"ldap_ro_token", {"Ldapro", ro_admin, "saslauthd"}}]
        }).

test_no_admin_anonymous() ->
    t_seed(#test_data{}),

    TestAnonAccess =
        fun (Apply, Msg) ->
                t_start("Anonymous " ++ Msg ++ " to non initialized cluster is allowed."),
                Apply(t_new_request([]), fun t_success/2, [none]),
                t_assert_success("undefined", "admin", "undefined", "undefined"),
                t_assert_ldap(0)
        end,

    [TestAnonAccess(Apply, Msg) ||
        {Apply, Msg} <- [{fun apply_auth/3, "admin access"},
                         {fun apply_ro_auth/3, "ro admin access"},
                         {fun apply_auth_any_bucket/3, "access to any bucket"}]],

    t_seed(#test_data{buckets = t_sample_buckets()}),

    TestBucket =
        fun (BucketId, ReadOnlyOk) ->
                t_start("Anonymous access to existing bucke in non initialized cluster is allowed. BucketId = ~p, ReadOnlyOk = ~p",
                       [BucketId, ReadOnlyOk]),
                apply_auth_bucket(t_new_request([]), fun t_success/2, [none], BucketId, ReadOnlyOk),
                t_assert_success("undefined", "admin", "undefined", "undefined"),
                t_assert_ldap(0)
        end,

    [TestBucket(BucketId, ReadOnlyOk) || BucketId <- ["b_noauth", "b_empty_pass", "b_auth"],
                                         ReadOnlyOk <- [true, false]].

test_no_admin_token() ->
    t_seed(
      #test_data{
         tokens = [{"admin_token", {"Admin", admin, "builtin"}}]
        }),

    TestTokenAccess =
        fun (Name, Fun, {Token, Result}) ->
                t_start("Token access to non initialized cluster is allowed. Fun = ~p, Token = ~p",
                       [Name, Token]),
                Fun(t_new_request({token, Token}), fun t_success/2, [none]),
                t_assert_result(Result),
                t_assert_ldap(0)
        end,
    [TestTokenAccess(Name, Fun, Args) ||
        {Name, Fun} <- [{apply_auth, fun apply_auth/3},
                        {apply_ro_auth, fun apply_ro_auth/3},
                        {apply_auth_any_bucket, fun apply_auth_any_bucket/3}],
        Args <- [{"admin_token", {"Admin","admin","builtin","admin_token"}},
                 {"unknown", {"undefined", "admin", "undefined", "unknown"}}]],

    t_seed(#test_data{buckets = t_sample_buckets()}),

    TestBucket =
        fun (BucketId, Token, ReadOnlyOk) ->
                t_start("Token access to existing bucket in non initialized cluster is allowed. Token = ~p, Bucket = ~p, ReadOnlyOk = ~p",
                       [Token, BucketId, ReadOnlyOk]),
                apply_auth_bucket(t_new_request({token, Token}), fun t_success/2,
                                  [none], BucketId, ReadOnlyOk),
                t_assert_success("undefined", "admin", "undefined", Token),
                t_assert_ldap(0)
        end,

    [TestBucket(BucketId, Token, ReadOnlyOk) ||
        Token <- ["admin_token", "unknown"],
        BucketId <- ["b_noauth", "b_empty_pass", "b_auth"],
        ReadOnlyOk <- [true, false]].

test_no_admin_basic_auth() ->
    t_seed(#test_data{}),

    TestAccess =
        fun (Name, Fun) ->
                t_start("Any basic auth access to non initialized cluster is allowed. Fun = ~p",
                        [Name]),
                Fun(t_new_request({"user", "pwd"}), fun t_success/2, [none]),
                t_assert_success("user", "admin", "builtin", "undefined")
                %%t_assert_ldap(0)
        end,

    [TestAccess(Name, Fun) ||
        {Name, Fun} <- [{apply_auth, fun apply_auth/3},
                        {apply_ro_auth, fun apply_ro_auth/3},
                        {apply_auth_any_bucket, fun apply_auth_any_bucket/3}]],

    t_start("Access to non existing bucket in non initialized cluster is not allowed."),
    apply_auth_bucket(t_new_request({"user", "pwd"}), fun t_success/2, [none], "test", true),
    t_assert_result(not_found),
    t_assert_ldap(0),

    t_seed(#test_data{buckets = t_sample_buckets()}),

    TestBucket =
        fun (BucketId, ReadOnlyOk) ->
                t_start("Basic auth access to existing bucket in non initialized cluster is allowed. Bucket = ~p, ReadOnlyOk = ~p",
                        [BucketId, ReadOnlyOk]),
                apply_auth_bucket(t_new_request({"user", "pwd"}), fun t_success/2,
                                  [none], BucketId, ReadOnlyOk),
                t_assert_success("user", "admin", "builtin", "undefined")
                %%t_assert_ldap(0)
        end,

    [TestBucket(BucketId, ReadOnlyOk) ||
        BucketId <- ["b_noauth", "b_empty_pass", "b_auth"],
        ReadOnlyOk <- [true, false]].

test_admin_auth() ->
    t_seed_sample_data(),

    t_start("Admin access - match."),
    apply_auth(t_new_request({"Admin", "pwd1"}), fun t_success/2, [none]),
    t_assert_success("Admin", "admin", "builtin", "undefined"),
    t_assert_ldap(0),

    t_start("Admin access - no match."),
    apply_auth(t_new_request({"Admin", "pwd1111"}), fun t_success/2, [none]),
    t_assert_result(require_auth),
    t_assert_ldap(1),

    t_start("Admin access - match. LDAP."),
    apply_auth(t_new_request({"Ldapadmin", "pwd3"}), fun t_success/2, [none]),
    t_assert_success("Ldapadmin", "admin", "saslauthd", "undefined"),
    t_assert_ldap(1),

    t_start("Admin access - matched to ro_admin. LDAP."),
    apply_auth(t_new_request({"Ldapro", "pwd4"}), fun t_success/2, [none]),
    t_assert_result(require_auth),
    t_assert_ldap(1).

test_ro_admin_auth() ->
    t_seed_sample_data(),

    t_start("RO Admin access - match."),
    apply_ro_auth(t_new_request({"Roadmin", "pwd2"}), fun t_success/2, [none]),
    t_assert_success("Roadmin", "ro_admin", "builtin", "undefined"),
    t_assert_ldap(0),

    t_start("RO Admin access - matched to admin."),
    apply_ro_auth(t_new_request({"Admin", "pwd1"}), fun t_success/2, [none]),
    t_assert_success("Admin", "admin", "builtin", "undefined"),
    %%t_assert_ldap(0),

    t_start("RO Admin access - no match."),
    apply_ro_auth(t_new_request({"someone", "pwd1"}), fun t_success/2, [none]),
    t_assert_result(require_auth),
    %% t_assert_ldap(1),

    t_start("RO Admin access - matched to admin. LDAP."),
    apply_ro_auth(t_new_request({"Ldapadmin", "pwd3"}), fun t_success/2, [none]),
    t_assert_success("Ldapadmin", "admin", "saslauthd", "undefined"),
    %%t_assert_ldap(1),

    t_start("RO Admin access - match. LDAP."),
    apply_ro_auth(t_new_request({"Ldapro", "pwd4"}), fun t_success/2, [none]),
    t_assert_success("Ldapro", "ro_admin", "saslauthd", "undefined"),
    t_assert_ldap(1).

test_any_bucket_anonymous() ->
    t_seed_sample_data(["b_noauth", "b_auth"]),

    t_start("Any bucket anonymous access with no auth."),
    apply_auth_any_bucket(t_new_request([]), fun t_success/2, [none]),
    t_assert_success("undefined", "undefined", "builtin", "undefined"),
    t_assert_ldap(0),

    t_seed_sample_data(["b_empty_pass", "b_auth"]),

    t_start("Any bucket anonymous access with no password."),
    apply_auth_any_bucket(t_new_request([]), fun t_success/2, [none]),
    t_assert_success("undefined", "undefined", "builtin", "undefined"),
    t_assert_ldap(0),

    t_seed(#test_data{admin = {"Admin", "pwd1"}}),

    t_start("Any bucket anonymous access with no buckets."),
    apply_auth_any_bucket(t_new_request([]), fun t_success/2, [none]),
    t_assert_result(require_auth),
    t_assert_ldap(0),

    t_seed_sample_data(["b_auth"]),

    t_start("Any bucket anonymous access with auth bucket."),
    apply_auth_any_bucket(t_new_request([]), fun t_success/2, [none]),
    t_assert_result(require_auth),
    t_assert_ldap(0).

test_any_bucket() ->
    TestAccess =
        fun (Buckets, {Auth, _LdapCount, Result}) ->
                t_seed_sample_data(Buckets),

                t_start("Any bucket access. Buckets = ~p, Auth = ~p", [Buckets, Auth]),
                apply_auth_any_bucket(t_new_request(Auth), fun t_success/2, [none]),
                t_assert_result(Result)
                %%t_assert_ldap(LdapCount)
        end,
    [TestAccess(Buckets, Args) ||
        Buckets <- [["b_auth"], [], ["b_empty_pass", "b_auth"], ["b_noauth", "b_auth"]],
        Args <- [{{"Admin", "pwd1"}, 0, {"Admin","admin","builtin","undefined"}},
                 {{"Ldapadmin", "pwd3"}, 1, {"Ldapadmin","admin","saslauthd","undefined"}},
                 {{"Ldapro", "pwd4"}, 1, {"Ldapro","ro_admin","saslauthd","undefined"}},
                 {{"Wrong", "wrong"}, 1, require_auth},
                 {{token, "wrong"}, 0, require_auth},
                 {{token, "admin_token"}, 0, {"Admin","admin","builtin","admin_token"}},
                 {{token, "ro_admin_token"}, 0, {"Roadmin","ro_admin","builtin","ro_admin_token"}},
                 {{token, "ldap_admin_token"}, 0, {"Ldapadmin","admin","saslauthd","ldap_admin_token"}},
                 {{token, "ldap_ro_token"}, 0, {"Ldapro","ro_admin","saslauthd","ldap_ro_token"}}
                ]],

    [TestAccess(Buckets, Args) ||
        Buckets <- [["b_empty_pass", "b_noauth", "b_auth"]],
        Args <- [{{"b_auth", "pwd5"}, 0, {"b_auth","bucket","builtin","undefined"}},
                 {{"b_auth", "wrong"}, 1, require_auth},
                 {{"b_empty_pass", ""}, 0, {"b_empty_pass","bucket","builtin","undefined"}},
                 {{"b_empty_pass", "wrong"}, 1, require_auth},
                 {{"b_noauth", ""}, 0, {"b_noauth","bucket","builtin","undefined"}},
                 {{"b_noauth", "wrong"}, 1, require_auth}
                ]].

test_bucket() ->
    t_seed_sample_data(),
    TestAccess =
        fun (Bucket, {Auth, ReadOnlyOk, _LdapCount, Result}) ->

                t_start("Bucket access. Bucket = ~p, Auth = ~p, ReadOnlyOk = ~p",
                        [Bucket, Auth, ReadOnlyOk]),
                apply_auth_bucket(t_new_request(Auth), fun t_success/2, [none], Bucket, ReadOnlyOk),
                t_assert_result(Result)
                %%t_assert_ldap(LdapCount)
        end,

    [TestAccess(Bucket, Args) ||
        Bucket <- ["b_empty_pass", "b_noauth", "b_auth"],
        Args <- [{{"Admin", "pwd1"}, true, 0, {"Admin","admin","builtin","undefined"}},
                 {{"Admin", "pwd1"}, false, 0, {"Admin","admin","builtin","undefined"}},
                 {{"Roadmin", "pwd2"}, true, 0, {"Roadmin","ro_admin","builtin","undefined"}},
                 {{"Roadmin", "pwd2"}, false, 1, require_auth},
                 {{token, "admin_token"}, true, 0, {"Admin","admin","builtin","admin_token"}},
                 {{token, "admin_token"}, false, 0, {"Admin","admin","builtin","admin_token"}},
                 {{token, "ro_admin_token"}, true, 0, {"Roadmin","ro_admin","builtin","ro_admin_token"}},
                 {{token, "ro_admin_token"}, false, 0, require_auth},
                 {{token, "wrong_token"}, true, 0, require_auth},
                 {{token, "wrong_token"}, false, 0, require_auth},
                 {{"Ldapadmin", "pwd3"}, true, 1, {"Ldapadmin","admin","saslauthd","undefined"}},
                 {{"Ldapadmin", "pwd3"}, false, 1, {"Ldapadmin","admin","saslauthd","undefined"}},
                 {{"Ldapro", "pwd4"}, true, 1, {"Ldapro","ro_admin","saslauthd","undefined"}},
                 {{"Ldapro", "pwd4"}, false, 1, require_auth},
                 {{"wrong", "wrong"}, true, 1, require_auth},
                 {{"wrong", "wrong"}, false, 1, require_auth}
                ]],

    [TestAccess(Bucket, Args) ||
        Bucket <- ["b_empty_pass", "b_noauth"],
        Args <- [{[], true, 0, {"undefined","undefined","builtin","undefined"}},
                 {[], false, 0, {"undefined","undefined","builtin","undefined"}}
                ]],

    [TestAccess(Bucket, Args) ||
        Bucket <- ["b_auth"],
        Args <- [{{"b_auth", "pwd5"}, true, 0, {"b_auth","bucket","builtin","undefined"}},
                 {{"b_auth", "pwd5"}, false, 0, {"b_auth","bucket","builtin","undefined"}}
                ]].

test_filter_accessible_buckets() ->
    t_seed_sample_data(),
    SampleBuckets = t_sample_buckets(),
    BucketsAll = [Name || {Name, _} <- SampleBuckets],

    Test =
        fun ({Auth, Expected, _LdapCount}) ->
                t_start("Filter accessible buckets. Auth = ~p", [Auth]),
                Buckets = apply_auth_any_bucket(
                            t_new_request(Auth),
                            fun (_, NewReq) ->
                                    filter_accessible_buckets(t_sample_buckets(), NewReq)
                            end, [none]),
                t_assert_buckets(Expected, Buckets)
                %%t_assert_ldap(LdapCount)
        end,

    [Test(Args) ||
        Args <- [{{"Admin", "pwd1"}, BucketsAll, 0},
                 {{"Roadmin", "pwd2"}, BucketsAll, 0},
                 {{"Ldapadmin", "pwd3"}, BucketsAll, 1},
                 {{"Ldapro", "pwd4"}, BucketsAll, 1},
                 {{token, "admin_token"}, BucketsAll, 0},
                 {{token, "ro_admin_token"}, BucketsAll, 0},
                 {{token, "ldap_admin_token"}, BucketsAll, 0},
                 {{token, "ldap_ro_token"}, BucketsAll, 0},
                 {{token, "wrong_token"}, require_auth, 0},
                 %% this contradicts function description:
                 {[], ["b_empty_pass","b_noauth"], 0},
                 {{"b_auth", "pwd5"}, ["b_auth"], 0},
                 {{"b_noauth", ""}, ["b_noauth"], 0},
                 {{"b_empty_pass", ""}, ["b_empty_pass"], 0},
                 {{"b_noauth", "pwd"}, require_auth, 1},
                 {{"b_empty_pass", "pwd"}, require_auth, 1},
                 {{"b_auth", "wrong"}, require_auth, 1},
                 {{"wrong", "wrong"}, require_auth, 1}
                ]].


test_is_bucket_accessible() ->
    t_seed_sample_data(),
    SampleBuckets = t_sample_buckets(),
    BucketsAll = [Name || {Name, _} <- SampleBuckets],

    Test =
        fun (Bucket, Auth, _LdapCount, Expected) ->
                BucketTuple = lists:keyfind(Bucket, 1, SampleBuckets),
                t_start("Is bucket accessible. Bucket = ~p, Auth = ~p", [Bucket, Auth]),
                Result = is_bucket_accessible(BucketTuple, t_new_request(Auth)),
                t_print_ldap_count(),
                ?assertEqual(Expected, Result)
                %%t_assert_ldap(LdapCount)
        end,

    [Test(Bucket, Auth, LdapCount, Expected) ||
        Bucket <- BucketsAll,
        {Auth, LdapCount, Expected} <-
            [{{"Admin", "pwd1"}, 0, true},
             {{"Roadmin", "pwd2"}, 1, false},
             {{"wrong", "wrong"}, 1, false},
             {{"Ldapadmin", "pwd3"}, 1, true},
             {{"Ldapro", "pwd4"}, 1, false},
             {{token, "admin_token"}, 0, true},
             {{token, "ro_admin_token"}, 0, false},
             {{token, "wrong_token"}, 0, false}
            ]],

    [Test(Bucket, Auth, LdapCount, Expected) ||
        {Bucket, Auth, LdapCount, Expected} <-
            [{"b_auth", {"b_auth", "pwd5"}, 0, true},
             {"b_auth", {"b_noauth", ""}, 1, false},
             {"b_auth", {"wrong", "wrong"}, 1, false},
             {"b_auth", [], 0, false},
             {"b_noauth", {"b_noauth", ""}, 0, true},
             {"b_noauth", [], 0, true},
             {"b_noauth", {"b_noauth", "pwd"}, 1, false},
             {"b_empty_pass", {"b_empty_pass", ""}, 0, true},
             {"b_empty_pass", [], 0, true},
             {"b_empty_pass", {"b_empty_pass", "pwd"}, 1, false}
            ]].

-endif.
