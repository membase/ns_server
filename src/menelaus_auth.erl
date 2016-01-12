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

-export([has_permission/2,
         get_accessible_buckets/2,
         extract_auth/1,
         extract_auth_user/1,
         extract_ui_auth_token/1,
         complete_uilogin/2,
         reject_uilogin/2,
         complete_uilogout/1,
         maybe_refresh_token/1,
         get_identity/1,
         get_token/1,
         get_role/1,
         get_advertised_source/1,
         validate_request/1,
         verify_login_creds/2,
         verify_rest_auth/2]).

%% External API

get_accessible_buckets(Fun, Req) ->
    Identity = menelaus_auth:get_identity(Req),
    Roles = menelaus_roles:get_compiled_roles(Identity),

    [BucketName ||
        {BucketName, _Config} <- ns_bucket:get_buckets(),
        menelaus_roles:is_allowed(Fun(BucketName), Roles)].

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
    case Req:get_header_value("ns-server-auth-token") of
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

complete_uilogin(Req, Identity) ->
    Token = menelaus_ui_auth:generate_token(Identity),
    CookieHeader = generate_auth_cookie(Req, Token),
    ns_audit:login_success(store_user_info(Req, Identity, Token)),
    menelaus_util:reply(Req, 200, [CookieHeader]).

reject_uilogin(Req, Identity) ->
    ns_audit:login_failure(store_user_info(Req, Identity, undefined)),
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
    undefined = Req:get_header_value("menelaus-auth-user"),
    undefined = Req:get_header_value("menelaus-auth-src"),
    undefined = Req:get_header_value("menelaus-auth-token").

store_user_info(Req, {User, Src}, Token) ->
    Headers = Req:get(headers),
    H1 = mochiweb_headers:enter("menelaus-auth-user", User, Headers),
    H2 = mochiweb_headers:enter("menelaus-auth-src", Src, H1),
    H3 = mochiweb_headers:enter("menelaus-auth-token", Token, H2),
    mochiweb_request:new(Req:get(socket), Req:get(method), Req:get(raw_path), Req:get(version), H3).

get_identity(Req) ->
    case {Req:get_header_value("menelaus-auth-user"),
          Req:get_header_value("menelaus-auth-src")} of
        {undefined, undefined} ->
            undefined;
        {User, Src} ->
            {User, list_to_existing_atom(Src)}
    end.

get_token(Req) ->
    Req:get_header_value("menelaus-auth-token").

get_advertised_source(admin) ->
    builtin;
get_advertised_source(ro_admin) ->
    builtin;
get_advertised_source(Src) ->
    Src.

%% TODO RBAC: to be removed
get_role(_Req) ->
    none.

extract_auth_user(Req) ->
    case Req:get_header_value("authorization") of
        "Basic " ++ Value ->
            parse_user(base64:decode_to_string(Value));
        _ -> undefined
    end.

-spec extract_auth(any()) -> {User :: string(), Password :: string()}
                                 | {token, string()} | undefined.
extract_auth(Req) ->
    case Req:get_header_value("ns-server-ui") of
        "yes" ->
            {token, extract_ui_auth_token(Req)};
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

has_permission(Permission, Req) ->
    menelaus_roles:is_allowed(Permission, get_identity(Req)).

authenticate(undefined) ->
    {ok, {"", anonymous}};
authenticate({token, Token}) ->
    case menelaus_ui_auth:check(Token) of
        false ->
            %% this is needed so UI can get /pools on unprovisioned
            %% system with leftover cookie
            case ns_config_auth:is_system_provisioned() of
                false ->
                    {ok, {"", wrong_token}};
                true ->
                    false
            end;
        Other ->
            Other
    end;
authenticate({Username, Password}) ->
    case ns_config_auth:authenticate(admin, Username, Password) of
        true ->
            {ok, {Username, admin}};
        false ->
            case ns_config_auth:authenticate(ro_admin, Username, Password) of
                true ->
                    {ok, {Username, ro_admin}};
                false ->
                    case ns_config_auth:is_bucket_auth(Username, Password) of
                        true ->
                            {ok, {Username, bucket}};
                        false ->
                            case saslauthd_auth:authenticate(Username, Password) of
                                true ->
                                    {ok, {Username, saslauthd}};
                                false ->
                                    false;
                                {error, Error} ->
                                    {error, Error}
                            end
                    end
            end
    end.

verify_login_creds(Username, Password) ->
    case authenticate({Username, Password}) of
        {ok, {Username, bucket}} ->
            false;
        Other ->
            Other
    end.

verify_rest_auth(Req, Permissions) ->
    Auth = extract_auth(Req),
    case authenticate(Auth) of
        false ->
            false;
        {ok, Identity} ->
            Roles = menelaus_roles:get_compiled_roles(Identity),
            case menelaus_roles:is_allowed(Permissions, Roles) of
                true ->
                    Token = case Auth of
                                {token, T} ->
                                    T;
                                _ ->
                                    undefined
                            end,
                    {true, store_user_info(Req, Identity, Token)};
                false ->
                    ?log_debug("Access denied.~nIdentity: ~p~nRoles: ~p~nPermissions: ~p~n",
                               [Identity, Roles, Permissions]),
                    false
            end
    end.
