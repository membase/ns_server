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
%% @doc REST client for the menelaus application.

-module(menelaus_rest).
-author('Northscale <info@northscale.com>').

%% API

-export([rest_url/3, json_request/3, rest_get_json/2,
         rest_engage_cluster/4, json_request_hilevel/3]).

-spec rest_url(string(), string() | integer(), string()) -> string().
rest_url(Host, Port, Path) when is_integer(Port) ->
    rest_url(Host, integer_to_list(Port), Path);
rest_url(Host, Port, Path) ->
    "http://" ++ Host ++ ":" ++ Port ++ Path.

rest_add_auth(Request, {User, Password}) ->
    [Url, Headers | Rest] = erlang:tuple_to_list(Request),
    UserPassword = base64:encode_to_string(User ++ ":" ++ Password),
    NewHeaders = [{"Authorization",
                   "Basic " ++ UserPassword} | Headers],
    erlang:list_to_tuple([Url, NewHeaders | Rest]);
rest_add_auth(Request, undefined) ->
    Request.

rest_request(Method, Request, Auth) ->
    inets:start(),
    http:request(Method, rest_add_auth(Request, Auth),
                 [{timeout, 30000}, {connect_timeout, 30000}], []).

decode_json_response({ok, Result}) ->
    {StatusLine, _Headers, Body} = Result,
    {_HttpVersion, StatusCode, _ReasonPhrase} = StatusLine,
    case StatusCode of
        200 -> {ok, mochijson2:decode(Body)};
        _   -> {error, Result}
    end;
decode_json_response({error, _} = Other) -> Other.

json_request(Method, Request, Auth) ->
    decode_json_response(rest_request(Method, Request, Auth)).

decode_json_response_ext({ok, {{_HttpVersion, 200 = _StatusCode, _ReasonPhrase} = _StatusLine,
                               _Headers, Body} = _Result},
                         _Method, _Request) ->
    try mochijson2:decode(Body) of
        X -> {ok, X}
    catch
        Type:What ->
            {error, bad_json, <<"Malformed JSON response">>,
             {Type, What, erlang:get_stacktrace()}}
    end;

decode_json_response_ext({ok, {{_HttpVersion, 400 = _StatusCode, _ReasonPhrase} = _StatusLine,
                               _Headers, Body} = _Result} = Response,
                         Method, Request) ->
    try mochijson2:decode(Body) of
        X -> {client_error, X}
    catch
        _:_ ->
            ns_error_messages:decode_json_response_error(Response, Method, Request)
    end;

decode_json_response_ext(Response, Method, Request) ->
    ns_error_messages:decode_json_response_error(Response, Method, Request).

-spec json_request_hilevel(atom(),
                           {string(), string() | integer(), string(), string(), iolist()},
                           undefined | {string(), string()}) ->
                                  %% json response payload
                                  {ok, any()} |
                                  %% json payload of 400
                                  {client_error, term()} |
                                  %% english error message and nested error
                                  {error, rest_error, binary(), {error, term()} | {bad_status, integer(), string()}}.
json_request_hilevel(Method, {Host, Port, Path, MimeType, Payload} = R, Auth) ->
    RealPayload = binary_to_list(iolist_to_binary(Payload)),
    URL = rest_url(Host, Port, Path),
    RV = rest_request(Method, {URL, [], MimeType, RealPayload}, Auth),
    decode_json_response_ext(RV, Method, setelement(5, R, RealPayload)).

rest_get_json(Url, Auth) ->
    json_request(get, {Url, []}, Auth).

% Returns the otpNode & otpCookie for a remote node.
% This is part of joining a node to an otp cluster.

rest_engage_cluster(Host, Port, Auth, MyIP) ->
    RV = json_request(post, {rest_url(Host, Port, "/engageCluster"),
                            [], "application/x-www-form-urlencoded",
                            "MyIP=" ++ MyIP}, Auth),
    case RV of
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
