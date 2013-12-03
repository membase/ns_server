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

-export([rest_url/3,
         json_request_hilevel/3,
         json_request_hilevel/4]).

-spec rest_url(string(), string() | integer(), string()) -> string().
rest_url(Host, Port, Path) when is_integer(Port) ->
    rest_url(Host, integer_to_list(Port), Path);
rest_url(Host, Port, Path) ->
    "http://" ++ Host ++ ":" ++ Port ++ Path.

rest_add_auth(Headers, {User, Password}) ->
    UserPassword = base64:encode_to_string(User ++ ":" ++ Password),
    [{"Authorization",
      "Basic " ++ UserPassword} | Headers];
rest_add_auth(Headers, undefined) ->
    Headers.

rest_add_mime_type(Headers, undefined) ->
    Headers;
rest_add_mime_type(Headers, MimeType) ->
    [{"Content-Type", MimeType} | Headers].

rest_request(Method, URL, Headers, MimeType, Body, Auth, HTTPOptions) ->
    NewHeaders0 = rest_add_auth(Headers, Auth),
    NewHeaders = rest_add_mime_type(NewHeaders0, MimeType),
    Timeout = proplists:get_value(timeout, HTTPOptions, 30000),
    HTTPOptions1 = lists:keydelete(timeout, 1, HTTPOptions),
    lhttpc:request(URL, Method, NewHeaders, Body, Timeout, HTTPOptions1).

decode_json_response_ext({ok, {{200 = _StatusCode, _} = _StatusLine,
                               _Headers, Body} = _Result},
                         _Method, _Request) ->
    try mochijson2:decode(Body) of
        X -> {ok, X}
    catch
        Type:What ->
            {error, bad_json, <<"Malformed JSON response">>,
             {Type, What, erlang:get_stacktrace()}}
    end;

decode_json_response_ext({ok, {{400 = _StatusCode, _} = _StatusLine,
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
                           {string(), string() | integer(), string(), string(), iolist()}
                           | {string(), string() | integer(), string()},
                           undefined | {string(), string()},
                           [any()]) ->
                                  %% json response payload
                                  {ok, any()} |
                                  %% json payload of 400
                                  {client_error, term()} |
                                  %% english error message and nested error
                                  {error, rest_error, binary(), {error, term()} | {bad_status, integer(), string()}}.
json_request_hilevel(Method, {Host, Port, Path, MimeType, Payload} = R, Auth, HTTPOptions) ->
    RealPayload = binary_to_list(iolist_to_binary(Payload)),
    URL = rest_url(Host, Port, Path),
    RV = rest_request(Method, URL, [], MimeType, RealPayload, Auth, HTTPOptions),
    decode_json_response_ext(RV, Method, setelement(5, R, RealPayload));
json_request_hilevel(Method, {Host, Port, Path}, Auth, HTTPOptions) ->
    URL = rest_url(Host, Port, Path),
    RV = rest_request(Method, URL, [], undefined, [], Auth, HTTPOptions),
    decode_json_response_ext(RV, Method, {Host, Port, Path, [], []}).

json_request_hilevel(Method, Request, Auth) ->
    DefaultOptions = [{timeout, 30000}, {connect_timeout, 30000}],
    json_request_hilevel(Method, Request, Auth, DefaultOptions).
