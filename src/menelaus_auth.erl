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

-export([apply_auth/3,
         apply_auth_cookie/3,
         require_auth/1,
         filter_accessible_buckets/2,
         is_bucket_accessible/2,
         apply_auth_bucket/3,
         extract_auth/1,
         extract_auth_user/1,
         check_auth/1,
         check_auth_bucket/1,
         bucket_auth_fun/1,
         parse_user_password/1,
         is_under_admin/1,
         is_read_only_admin_exist/0,
         is_read_only_auth/1]).

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
    F = bucket_auth_fun(UserPassword),
    [Bucket || Bucket <- BucketsAll, F(Bucket)].

%% returns true if given bucket is accessible with current
%% credentials. No auth buckets are always accessible. SASL auth
%% buckets are accessible only with admin or bucket credentials.
is_bucket_accessible(Bucket, Req) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    F = bucket_auth_fun(UserPassword),
    F(Bucket).

apply_auth(Req, F, Args) ->
    UserPassword = extract_auth(Req),
    apply_auth_with_auth_data(Req, F, Args, UserPassword).

apply_auth_with_auth_data(Req, F, Args, UserPassword) ->
    case check_auth(UserPassword) of
        true -> apply(F, Args ++ [Req]);
        _ -> require_auth(Req)
    end.

apply_auth_cookie(Req, F, Args) ->
    UserPassword = case extract_auth(Req) of
                       undefined ->
                           case Req:get_header_value("Cookie") of
                               undefined -> undefined;
                               RawCookies ->
                                   ParsedCookies = mochiweb_cookies:parse_cookie(RawCookies),
                                   case proplists:get_value("auth", ParsedCookies) of
                                       undefined -> undefined;
                                       V -> parse_user_password(base64:decode_to_string(mochiweb_util:unquote(V)))
                                   end
                           end;
                       X -> X
                   end,
    apply_auth_with_auth_data(Req, F, Args, UserPassword).

%% applies given function F if current credentials allow access to at
%% least single SASL-auth bucket. So admin credentials and bucket
%% credentials works. Other credentials do not allow access. Empty
%% credentials are not allowed too.
apply_auth_bucket(Req, F, Args) ->
    UserPassword = extract_auth(Req),
    case check_auth_bucket(UserPassword) of
        true -> apply(F, Args ++ [Req]);
        _    -> apply_auth(Req, F, Args)
    end.

% {rest_creds, [{creds, [{"user", [{password, "password"}]},
%                        {"admin", [{password, "admin"}]}]}
%              ]}. % An empty list means no login/password auth check.

%% Checks if given credentials allow access to any SASL-auth
%% bucket.
check_auth_bucket(UserPassword) ->
    Buckets = ns_bucket:get_buckets(),
    lists:any(bucket_auth_fun(UserPassword),
              Buckets).

%% checks if given credentials are admin credentials
check_auth(UserPassword) ->
    case ns_config:search_prop('latest-config-marker', rest_creds, creds, empty) of
        []    -> true; % An empty list means no login/password auth check.
        empty -> true; % An empty list means no login/password auth check.
        Creds -> check_auth(UserPassword, Creds) orelse is_read_only_auth(UserPassword)
    end.

is_read_only_auth(UserPassword) ->
    ns_config:search(read_only_user_creds) =:= {value, UserPassword}.

is_read_only_admin_exist() ->
    case ns_config:search(read_only_user_creds) of
        {value, null} -> false;
        {value, _P} -> true;
        false -> false
    end.

check_auth(_UserPassword, []) ->
    false;
check_auth({User, Password}, [{User, PropList} | _]) ->
    Password =:= proplists:get_value(password, PropList, "");
check_auth(UserPassword, [_NotRightUser | Rest]) ->
    check_auth(UserPassword, Rest).

extract_auth_user(Req) ->
    case Req:get_header_value("authorization") of
        "Basic " ++ Value ->
            parse_user(base64:decode_to_string(Value));
        _ -> undefined
    end.

extract_auth(Req) ->
    case Req:get_header_value("authorization") of
        "Basic " ++ Value ->
            parse_user_password(base64:decode_to_string(Value));
        _ -> undefined
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
bucket_auth_fun(UserPassword) ->
    case check_auth(UserPassword) of
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
