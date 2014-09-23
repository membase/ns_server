%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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
-module(capi_http_proxy).

-include("ns_common.hrl").

-export([handle_request/1]).

should_proxy_header('Accept') ->
    true;
should_proxy_header('Accept-Encoding') ->
    true;
should_proxy_header('Accept-Language') ->
    true;
should_proxy_header('Cache-Control') ->
    true;
should_proxy_header('Connection') ->
    true;
should_proxy_header('Content-Type') ->
    true;
should_proxy_header('Pragma') ->
    true;
should_proxy_header('Referer') ->
    true;
should_proxy_header(_) ->
    false.

convert_header_name(Header) when is_atom(Header) ->
    atom_to_list(Header);
convert_header_name(Header) when is_list(Header) ->
    Header.

convert_headers(MochiHeaders) ->
    HeadersList = mochiweb_headers:to_list(MochiHeaders),
    lists:filtermap(fun ({Name, Value}) ->
                            case should_proxy_header(Name) of
                                true ->
                                    {true, {convert_header_name(Name), Value}};
                                false ->
                                    false
                            end
                    end, HeadersList).

convert_body(undefined) ->
    <<>>;
convert_body(Body) ->
    Body.

handle_request(MochiReq) ->
    "/couchBase" ++ Path = MochiReq:get(raw_path),
    SchemaAndHost = "http://" ++ Host =
        binary_to_list(vbucket_map_mirror:node_to_capi_base_url(node(), "127.0.0.1")),
    URL = SchemaAndHost ++ Path,

    Params = MochiReq:parse_qs(),
    Timeout = list_to_integer(proplists:get_value("connection_timeout", Params, "30000")),

    Method = MochiReq:get(method),
    Headers = [{"Host", Host}, {"Capi-Auth-Token", atom_to_list(ns_server:get_babysitter_cookie())}]
        ++ convert_headers(MochiReq:get(headers)),
    Body = convert_body(MochiReq:recv_body()),
    {ok, {{Code, _}, RespHeaders, RespBody}} =
        lhttpc:request(URL, Method, Headers, Body, Timeout, []),
    NewRespHeaders =
        lists:filter(fun ({"Transfer-Encoding", _}) ->
                             false;
                         ({"Www-Authenticate", _}) ->
                             false;
                         (_) ->
                             true
                     end, RespHeaders),
    MochiReq:respond({Code, NewRespHeaders, RespBody}).
