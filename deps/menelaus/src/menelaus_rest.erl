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
    http:request(get, {Url, []}, [{timeout, 2500}, {connect_timeout, 2500}], []);

rest_get(Url, {User, Password}) ->
    UserPassword = base64:encode_to_string(User ++ ":" ++ Password),
    http:request(get, {Url, [{"Authorization",
                              "Basic " ++ UserPassword}]},
                              [{timeout, 2500}, {connect_timeout, 2500}], []).

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
                undefined ->
                    ns_log:log(?MODULE, 001, "During attempted node join (from ~p), the remote node at ~p (port ~p) returned a response with no nodes.",
                              [node(), Host, Port]),
                    undefined;
                [Node | _] ->
                  {struct, NodeKVList} = Node,
                  OtpNode = proplists:get_value(<<"otpNode">>, NodeKVList),
                  OtpCookie = proplists:get_value(<<"otpCookie">>, NodeKVList),
                  {ok, OtpNode, OtpCookie}
            end;
        {error, Err} ->
            ns_log:log(?MODULE, 002, "During attempted node join (from ~p), the remote node at ~p (port ~p) returned an error response (~p). " ++
                                     "Perhaps the wrong host/port was used, or there's a firewall in-between? " ++
                                     "Or, perhaps authorization credentials were incorrect?",
                       [node(), Host, Port, Err]),
            {error, Err}
    end.

