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

-include("ns_common.hrl").

-export([apply_auth/3,
         apply_ro_auth/3,
         require_auth/1,
         filter_accessible_buckets/2,
         is_bucket_accessible/3,
         apply_auth_any_bucket/3,
         extract_auth/1,
         extract_auth_user/1,
         check_auth/1,
         parse_user_password/1,
         is_under_admin/1,
         is_read_only_auth/1,
         extract_ui_auth_token/1,
         complete_uilogin/3,
         reject_uilogin/2,
         complete_uilogout/1,
         maybe_refresh_token/1,
         may_expose_bucket_auth/1,
         get_user/1,
         get_token/1,
         get_role/1,
         validate_request/1,
         check_creds/3]).

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
    F = bucket_auth_fun(UserPassword, true),
    [Bucket || Bucket <- BucketsAll, F(Bucket)].

%% returns true if given bucket is accessible with current
%% credentials. No auth buckets are always accessible. SASL auth
%% buckets are accessible only with admin or bucket credentials.
-spec is_bucket_accessible({string(), list()}, any(), boolean()) -> boolean().
is_bucket_accessible(BucketTuple, Req, ReadOnlyOk) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    F = bucket_auth_fun(UserPassword, ReadOnlyOk),
    F(BucketTuple).

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
    lookup_cookie(Req, ui_auth_cookie_name(Req)).

generate_auth_cookie(Req, Token) ->
    Options = [{path, "/"}, {http_only, true}],
    mochiweb_cookies:cookie(ui_auth_cookie_name(Req), Token, Options).

kill_auth_cookie(Req) ->
    Options = [{path, "/"}, {http_only, true}],
    {Name, Content} = mochiweb_cookies:cookie(ui_auth_cookie_name(Req), "", Options),
    {Name, Content ++ "; expires=Thu, 01 Jan 1970 00:00:00 GMT"}.

complete_uilogin(Req, User, Role) ->
    Token = menelaus_ui_auth:generate_token({User, Role}),
    CookieHeader = generate_auth_cookie(Req, Token),
    ns_audit:login_success(store_user_info(Req, User, Role, Token)),
    menelaus_util:reply(Req, 200, [CookieHeader]).

reject_uilogin(Req, User) ->
    ns_audit:login_failure(store_user_info(Req, User, undefined, undefined)),
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
    undefined = Req:get_header_value("menelaus_auth-token").

store_user_info(Req, User, Role, Token) ->
    Headers = Req:get(headers),
    H1 = mochiweb_headers:enter("menelaus_auth-user", User, Headers),
    H2 = mochiweb_headers:enter("menelaus_auth-role", Role, H1),
    H3 = mochiweb_headers:enter("menelaus_auth-token", Token, H2),
    mochiweb_request:new(Req:get(socket), Req:get(method), Req:get(raw_path), Req:get(version), H3).

get_user(Req) ->
    Req:get_header_value("menelaus_auth-user").

get_token(Req) ->
    Req:get_header_value("menelaus_auth-token").

get_role(Req) ->
    Req:get_header_value("menelaus_auth-role").

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
                _ ->
                    apply_ro_auth(Req, F, Args)
            end
    end.

%% Checks if given credentials allow access to any SASL-auth
%% bucket.
check_auth_any_bucket(Req, UserPassword) ->
    Buckets = ns_bucket:get_buckets(),
    case lists:any(bucket_auth_fun(UserPassword, true),
                   Buckets) of
        true ->
            User = case UserPassword of
                       {UserX, _} -> UserX;
                       undefined -> anonymous
                   end,
            {true, store_user_info(Req, User, bucket, undefined)};
        false ->
            false
    end.

check_auth(Auth) ->
    case check_admin_auth_int(Auth) of
        {true, _User, _Token} ->
            true;
        false ->
            false
    end.

check_admin_auth(Req, Auth) ->
    case check_admin_auth_int(Auth) of
        {true, User, Token} ->
            {true, store_user_info(Req, User, admin, Token)};
        false ->
            false
    end.

%% checks if given credentials are admin credentials
check_admin_auth_int({token, Token}) ->
    case menelaus_ui_auth:check(Token) of
        {ok, {User, admin}} ->
            {true, User, Token};
        _ ->
            % An undefined user means no login/password auth check.
            case ns_config_auth:get_user(admin) of
                undefined ->
                    {true, undefined, Token};
                _ ->
                    false
            end
    end;
check_admin_auth_int({User, Password}) ->
    case ns_config_auth:authenticate(admin, User, Password) of
        true ->
            {true, User, undefined};
        false ->
            false
    end;
check_admin_auth_int(undefined) ->
    case ns_config_auth:get_user(admin) of
        undefined ->
            {true, undefined, undefined};
        _ ->
            false
    end.

is_read_only_auth(Auth) ->
    case check_read_only_auth(Auth) of
        {true, _, _} ->
            true;
        false ->
            false
    end.

check_read_only_auth(Req, Auth) ->
    case check_read_only_auth(Auth) of
        {true, User, Token} ->
            {true, store_user_info(Req, User, ro_admin, Token)};
        false ->
            check_admin_auth(Req, Auth)
    end.

check_read_only_auth({token, Token}) ->
    case menelaus_ui_auth:check(Token) of
        {ok, {User, ro_admin}} ->
            {true, User, Token};
        _ ->
            false
    end;
check_read_only_auth({User, Password}) ->
    case ns_config_auth:authenticate(ro_admin, User, Password) of
        true ->
            {true, User, undefined};
        false ->
            false
    end;
check_read_only_auth(undefined) ->
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
bucket_auth_fun(UserPassword, ReadOnlyOk) ->
    IsAdmin = case ReadOnlyOk of
                  true ->
                      is_read_only_auth(UserPassword) orelse check_auth(UserPassword);
                  _ ->
                      check_auth(UserPassword)
              end,
    case IsAdmin of
        true ->
            fun (_) -> true end;
        false ->
            fun({BucketName, BucketProps}) ->
                    case {proplists:get_value(auth_type, BucketProps),
                          proplists:get_value(sasl_password, BucketProps),
                          UserPassword} of
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
            end
    end.

is_under_admin(Req) ->
    check_auth(extract_auth(Req)).

may_expose_bucket_auth(Req) ->
    not is_read_only_auth(extract_auth(Req)).

check_creds(User, Password, undefined) ->
    case ns_config_auth:authenticate(admin, User, Password) of
        true ->
            {true, true};
        _ ->
            {false, false}
    end;
check_creds(User, Password, Bucket) ->
    IsAdmin = check_auth({User, Password}),
    case IsAdmin of
        true ->
            {true, true};
        false ->
            Auth = case {User, Password} of
                       {"", ""} -> undefined;
                       AuthX -> AuthX
                   end,
            F = bucket_auth_fun(Auth, false),
            Ok = case ns_bucket:get_bucket(Bucket) of
                     {ok, BucketInfo} ->
                         F({Bucket, BucketInfo});
                     not_present ->
                         false
                 end,
            {Ok, false}
    end.
