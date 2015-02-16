%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
%% @doc this module implements access to goxdcr component via REST API
%%

-module(goxdcr_rest).
-include("ns_common.hrl").

-export([proxy/1,
         proxy/2,
         send/2]).

get_rest_port() ->
    ns_config:read_key_fast({node, node(), xdcr_rest_port}, 9998).

convert_header_name(Header) when is_atom(Header) ->
    atom_to_list(Header);
convert_header_name(Header) when is_list(Header) ->
    Header.

convert_headers(MochiReq) ->
    HeadersList = mochiweb_headers:to_list(MochiReq:get(headers)),
    Headers = lists:filtermap(fun ({'Content-Length', _Value}) ->
                                      false;
                                  ({Name, Value}) ->
                                      {true, {convert_header_name(Name), Value}}
                              end, HeadersList),
    case menelaus_auth:extract_ui_auth_token(MochiReq) of
        undefined ->
            Headers;
        Token ->
            [{"ns_server-auth-token", Token} | Headers]
    end.

send(MochiReq, Method, Path, Headers, Body) ->
    URL = "http://127.0.0.1:" ++ integer_to_list(get_rest_port()) ++ Path,

    Params = MochiReq:parse_qs(),
    Timeout = list_to_integer(proplists:get_value("connection_timeout", Params, "30000")),

    {ok, {{Code, _}, RespHeaders, RespBody}} =
        lhttpc:request(URL, Method, Headers, Body, Timeout, []),
    {Code, RespHeaders, RespBody}.


proxy(MochiReq) ->
    proxy(MochiReq, MochiReq:get(raw_path)).

proxy(MochiReq, Path) ->
    Headers = convert_headers(MochiReq),
    Body = case MochiReq:recv_body() of
               undefined ->
                   <<>>;
               B ->
                   B
           end,
    MochiReq:respond(send(MochiReq, MochiReq:get(method), Path, Headers, Body)).

send(MochiReq, Body) ->
    Headers = convert_headers(MochiReq),
    send(MochiReq, MochiReq:get(method), MochiReq:get(raw_path), Headers, Body).
