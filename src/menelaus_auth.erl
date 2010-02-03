%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_auth).
-author('Northscale <info@northscale.com>').

-export([apply_auth/3,
         apply_auth_bucket/3,
         extract_auth/1,
         check_auth/1,
         check_auth_bucket/1,
         bucket_auth_fun/1,
         parse_user_password/1]).

%% External API

apply_auth(Req, F, Args) ->
    UserPassword = extract_auth(Req),
    case check_auth(UserPassword) of
        true -> apply(F, Args ++ [Req]);
        _ -> case Req:get_header_value("invalid-auth-response") of
                 "on" ->
                     %% We need this for browsers that display auth
                     %% dialog when faced with 401 with
                     %% WWW-Authenticate header response, even via XHR
                     Req:respond({401, [], []});
                 _ ->
                     Req:respond({401, [{"WWW-Authenticate",
                                 "Basic realm=\"api\""}],
                                  []})
             end
    end.

apply_auth_bucket(Req, F, Args) ->
    UserPassword = extract_auth(Req),
    case check_auth_bucket(UserPassword) of
        true -> apply(F, Args ++ [Req]);
        _    -> apply_auth(Req, F, Args)
    end.

% {rest_creds, [{creds, [{"user", [{password, "password"}]},
%                        {"admin", [{password, "admin"}]}]}
%              ]}. % An empty list means no login/password auth check.

check_auth_bucket(UserPassword) ->
    % Default pool only for 1.0.
    case ns_config:search_prop(ns_config:get(), pools, "default", empty) of
        empty -> false;
        Pool ->
            Buckets = proplists:get_value(buckets, Pool),
            lists:any(bucket_auth_fun(UserPassword),
                      Buckets)
    end.

check_auth(UserPassword) ->
    case ns_config:search_prop(ns_config:get(), rest_creds, creds, empty) of
        []    -> true; % An empty list means no login/password auth check.
        empty -> true; % An empty list means no login/password auth check.
        Creds -> check_auth(UserPassword, Creds)
    end.

check_auth(_UserPassword, []) ->
    false;
check_auth({User, Password}, [{User, PropList} | _]) ->
    Password =:= proplists:get_value(password, PropList, "");
check_auth(UserPassword, [_NotRightUser | Rest]) ->
    check_auth(UserPassword, Rest).

extract_auth(Req) ->
    case Req:get_header_value("authorization") of
        "Basic " ++ Value ->
            parse_user_password(base64:decode_to_string(Value));
        _ -> undefined
    end.

parse_user_password(UserPasswordStr) ->
    case string:tokens(UserPasswordStr, ":") of
        [] -> undefined;
        [User] -> {User, ""};
        [User, Password] -> {User, Password}
    end.

bucket_auth_fun(UserPassword) ->
    fun({BucketName, BucketProps}) ->
            case proplists:get_value(auth_plain, BucketProps) of
                undefined -> true;
                BucketPassword ->
                    case UserPassword of
                        undefined -> false;
                        {User, Password} ->
                            (BucketName =:= User andalso
                             BucketPassword =:= Password)
                    end
            end
    end.

