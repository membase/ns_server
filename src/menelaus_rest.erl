%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Supervisor for the menelaus application.

-module(menelaus_rest).
-author('Northscale <info@northscale.com>').

-compile(export_all).

%% External exports
-export([rest_url/3, rest_get/2]).

rest_url(Host, Port, Path) ->
    "http://" ++ Host ++ ":" ++ Port ++ Path.

rest_get(Url, undefined) ->
    http:request(Url);

rest_get(Url, {User, Password}) ->
    UserPassword = base64:encode_to_string(User ++ ":" ++ Password),
    http:request(get, {Url, [{"Authorization",
                              "Basic " ++ UserPassword}]}, [], []).

% ------------------------------------------------

rest_get_json(Url, Auth) ->
    inets:start(),
    {ok, Result} = menelaus_rest:rest_get(Url, Auth),
    {StatusLine, _Headers, Body} = Result,
    {_HttpVersion, StatusCode, _ReasonPhrase} = StatusLine,
    case StatusCode of
        200 -> {ok, mochijson2:decode(Body)};
        _   -> {error, Result}
    end.

rest_get_otp(Host, Port, Auth) ->
    {ok, {struct, KVList}} =
        rest_get_json(rest_url(Host, Port, "/pools/default"), Auth),
    case proplists:get_value(<<"nodes">>, KVList) of
        undefined -> undefined;
        [Node | _] ->
            {struct, NodeKVList} = Node,
            OtpNode = proplists:get_value(<<"otpNode">>, NodeKVList),
            OtpCookie = proplists:get_value(<<"otpCookie">>, NodeKVList),
            {ok, OtpNode, OtpCookie}
    end.

