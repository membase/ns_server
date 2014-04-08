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
         apply_special_auth/3,
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
         complete_uilogin/2,
         maybe_refresh_token/1,
         may_expose_bucket_auth/1]).

%% External API

%% Respond with 401 Auth. required
require_auth(Req) ->
    case Req:get_header_value("invalid-auth-response") of
        "on" ->
            %% We need this for browsers that display auth
            %% dialog when faced with 401 with
            %% WWW-Authenticate header response, even via XHR
            Req:respond({401, add_header(), []});
        _ ->
            Req:respond({401, [{"WWW-Authenticate",
                                "Basic realm=\"Couchbase Server Admin / REST\""} | add_header()],
                         []})
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
    apply_auth_with_auth_data(Req, F, Args, UserPassword, fun check_auth/1).

apply_ro_auth(Req, F, Args) ->
    UserPassword = extract_auth(Req),
    apply_auth_with_auth_data(Req, F, Args, UserPassword, fun check_ro_auth/1).

apply_special_auth(Req, F, Args) ->
    UserPassword = extract_auth(Req),
    apply_auth_with_auth_data(Req, F, Args, UserPassword, fun check_special_auth/1).

apply_auth_with_auth_data(Req, F, Args, UserPassword, AuthFun) ->
    case AuthFun(UserPassword) of
        true -> apply(F, Args ++ [Req]);
        _ -> require_auth(Req)
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
    Options = [{path, "/"}, {http_only, true}, {max_age, ?UI_AUTH_EXPIRATION_SECONDS}],
    mochiweb_cookies:cookie(ui_auth_cookie_name(Req), Token, Options).

complete_uilogin(Req, Role) ->
    Token = menelaus_ui_auth:generate_token(Role),
    CookieHeader = generate_auth_cookie(Req, Token),
    Req:respond({200, [CookieHeader | add_header()], ""}).

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

%% applies given function F if current credentials allow access to at
%% least single SASL-auth bucket. So admin credentials and bucket
%% credentials works. Other credentials do not allow access. Empty
%% credentials are not allowed too.
apply_auth_any_bucket(Req, F, Args) ->
    UserPassword = extract_auth(Req),
    case check_auth_any_bucket(UserPassword) of
        true -> apply(F, Args ++ [Req]);
        _    -> apply_ro_auth(Req, F, Args)
    end.

%% Checks if given credentials allow access to any SASL-auth
%% bucket.
check_auth_any_bucket(UserPassword) ->
    Buckets = ns_bucket:get_buckets(),
    lists:any(bucket_auth_fun(UserPassword, true),
              Buckets).

%% checks if given credentials are admin credentials
check_auth({token, Token}) ->
    case menelaus_ui_auth:check(Token) of
        {ok, admin} ->
            true;
        _ ->
            % An undefined user means no login/password auth check.
            ns_config_auth:get_user(admin) =:= undefined
    end;
check_auth({User, Password}) ->
    ns_config_auth:authenticate(admin, User, Password);
check_auth(undefined) ->
    ns_config_auth:get_user(admin) =:= undefined.

check_ro_auth(UserPassword) ->
    is_read_only_auth(UserPassword) orelse check_auth(UserPassword).

check_special_auth({User, Password}) ->
    ns_config_auth:authenticate(special, User, Password) orelse
        check_auth({User, Password});
check_special_auth(undefined) ->
    false.

is_read_only_auth({token, Token}) ->
    case menelaus_ui_auth:check(Token) of
        {ok, ro_admin} -> true;
        _ -> false
    end;
is_read_only_auth({User, Password}) ->
    ns_config_auth:authenticate(ro_admin, User, Password);
is_read_only_auth(undefined) ->
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
    case Req:get_header_value("authorization") of
        "Basic " ++ Value ->
            parse_user_password(base64:decode_to_string(Value));
        _ ->
            case extract_ui_auth_token(Req) of
                undefined -> undefined;
                Token -> {token, Token}
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
                  true -> check_ro_auth(UserPassword);
                  _ -> check_auth(UserPassword)
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

% too much typing to add this, and I'd rather not hide the response too much
add_header() ->
    menelaus_util:server_header().

is_under_admin(Req) ->
    check_auth(extract_auth(Req)).

may_expose_bucket_auth(Req) ->
    not is_read_only_auth(extract_auth(Req)).
