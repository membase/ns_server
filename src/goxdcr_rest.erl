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
         send/2,
         find_all_replication_docs/1,
         all_local_replication_infos/0,
         delete_all_replications/1]).

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
    Params = MochiReq:parse_qs(),
    Timeout = list_to_integer(proplists:get_value("connection_timeout", Params, "30000")),
    send_with_timeout(Method, Path, Headers, Body, Timeout).

send_with_timeout(Method, Path, Headers, Body, Timeout) ->
    URL = "http://127.0.0.1:" ++ integer_to_list(get_rest_port()) ++ Path,

    {ok, {{Code, _}, RespHeaders, RespBody}} =
        lhttpc:request(URL, Method, Headers, Body, Timeout, []),
    {Code, RespHeaders, RespBody}.

special_auth_headers() ->
    menelaus_rest:add_basic_auth([{"Accept", "application/json"}],
                                 ns_config_auth:get_user(special),
                                 ns_config_auth:get_password(special)).

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

interesting_doc_key(<<"id">>) ->
    true;
interesting_doc_key(<<"type">>) ->
    true;
interesting_doc_key(<<"source">>) ->
    true;
interesting_doc_key(<<"target">>) ->
    true;
interesting_doc_key(<<"continuous">>) ->
    true;
interesting_doc_key(_) ->
    false.

query_goxdcr(Method, Path, Timeout) ->
    query_goxdcr(fun (_) -> ok end, Method, Path, Timeout).

query_goxdcr(Fun, Method, Path, Timeout) ->
    RV = {Code, _Headers, Body} =
        send_with_timeout(Method, Path, special_auth_headers(), [], Timeout),
    case Code of
        200 ->
            case Body of
                <<>> ->
                    Fun([]);
                _ ->
                    Fun(ejson:decode(Body))
            end;
        _ ->
            erlang:throw({unsuccesful_goxdcr_call, RV})
    end.

process_doc({Props}) ->
    [{list_to_atom(binary_to_list(Key)), Value} ||
        {Key, Value} <- Props,
        interesting_doc_key(Key)].

find_all_replication_docs(Timeout) ->
    query_goxdcr(fun (Json) ->
                         [process_doc(Doc) || Doc <- Json]
                 end, "GET", "/pools/default/replications", Timeout).


process_repl_info({Info}, Acc) ->
    case misc:expect_prop_value(<<"StatsMap">>, Info) of
        null ->
            Acc;
        {StatsList} ->
            Id = misc:expect_prop_value(<<"Id">>, Info),
            Stats = [{list_to_atom(binary_to_list(K)), list_to_integer(binary_to_list(V))} ||
                        {K, V} <- StatsList],
            [{Id, Stats, []}, Acc]
    end.

all_local_replication_infos() ->
    query_goxdcr(fun (Json) ->
                         lists:foldl(fun (Info, Acc) ->
                                             process_repl_info(Info, Acc)
                                     end, [], Json)
                 end, "GET", "/pools/default/replicationInfos", 30000).

delete_all_replications(Bucket) ->
    query_goxdcr("DELETE", "/pools/default/replications/" ++ Bucket, 30000).
