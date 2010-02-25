%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc REST client for the menelaus application.

-module(menelaus_rest).
-author('Northscale <info@northscale.com>').

%% API

-export([rest_url/3, rest_get/2, rest_get_json/2, rest_get_otp/3]).

rest_url(Host, Port, Path) ->
    "http://" ++ Host ++ ":" ++ integer_to_list(Port) ++ Path.

rest_get(Url, undefined) ->
    http:request(Url);

rest_get(Url, {User, Password}) ->
    UserPassword = base64:encode_to_string(User ++ ":" ++ Password),
    http:request(get, {Url, [{"Authorization",
                              "Basic " ++ UserPassword}]}, [], []).


rest_get_json(Url, Auth) ->
    inets:start(),
    case menelaus_rest:rest_get(Url, Auth) of
        {ok, Result} ->
            {StatusLine, _Headers, Body} = Result,
            {_HttpVersion, StatusCode, _ReasonPhrase} = StatusLine,
            case StatusCode of
                200 -> {ok, mochijson2:decode(Body)};
                _   -> {error, Result}
            end;
        {error, Any} -> {error, Any}
    end.

% Returns the otpNode & otpCookie for a remote node.
% This is part of joining a node to an otp cluster.

rest_get_otp(Host, Port, Auth) ->
    case rest_get_json(rest_url(Host, Port, "/pools/default"), Auth) of
        {ok, {struct, KVList}} ->
            case proplists:get_value(<<"nodes">>, KVList) of
                undefined -> ns_log:log(?MODULE, 001, "During node join, remote node returned a response with no nodes."),
                    undefined;
                [Node | _] ->
                  {struct, NodeKVList} = Node,
                  OtpNode = proplists:get_value(<<"otpNode">>, NodeKVList),
                  OtpCookie = proplists:get_value(<<"otpCookie">>, NodeKVList),
                  {ok, OtpNode, OtpCookie}
            end;
        {error, Any} -> {error, Any}
    end.

