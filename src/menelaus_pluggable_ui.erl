%% @author Couchbase, Inc <info@couchbase.com>
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
-module(menelaus_pluggable_ui).

-export([find_plugins/0,
         inject_head_fragments/3,
         is_plugin/2,
         proxy_req/4,
         maybe_serve_file/4]).

-include("ns_common.hrl").

-define(CONFIG_DIR, etc).
-define(DOCROOTS_DIR, lib).
-define(PLUGIN_FILE_PATTERN, "pluggable-ui-*.json").

-define(HEAD_FRAG_HTML, <<"head.frag.html">>).
-define(HEAD_MARKER, <<"<!-- Inject head.frag.html file content for Pluggable UI components here -->">>).
-define(TIMEOUT, 60000).
-define(PART_SIZE, 100000).
-define(WINDOW_SIZE, 5).

-type service_name()   :: atom().
-type rest_api_prefix():: string().
-type proxy_strategy() :: local.
-record(plugin, { name            :: service_name(),
                  proxy_strategy  :: proxy_strategy(),
                  rest_api_prefix :: rest_api_prefix(),
                  doc_root        :: {multiple_roots, [string()]} | string()}).
-type plugin()  :: #plugin{}.
-type plugins() :: [plugin()].

-define(VIEW_PLUGIN, #plugin{name = views,
                             proxy_strategy = local,
                             rest_api_prefix = "couchBase",
                             doc_root = ""}).

-spec find_plugins() -> plugins().
find_plugins() ->
    SpecFiles = find_plugin_spec_files(),
    [?VIEW_PLUGIN | read_and_validate_plugin_specs(SpecFiles)].

%% The plugin files passed via the command line are processed first so it is
%% possible to override the standard files.
find_plugin_spec_files() ->
    find_plugin_spec_files_from_env() ++ find_plugin_spec_files_std().

%% The plugin files from the standard configuration dir are sorted to get a
%% well defined order when loading the files.
find_plugin_spec_files_std() ->
    lists:sort(
      filelib:wildcard(
        filename:join(
          path_config:component_path(?CONFIG_DIR),
          ?PLUGIN_FILE_PATTERN))).

%% The plugin files passed via the command line are not sorted, so it is
%% possible to change the order of then in case there are any strange
%% dependencies. This is just expected to be done during development.
find_plugin_spec_files_from_env() ->
    case application:get_env(ns_server, ui_plugins) of
        {ok, Raw} ->
            string:tokens(Raw, ",");
        _ ->
            []
    end.

read_and_validate_plugin_specs(SpecFiles) ->
    lists:foldl(fun read_and_validate_plugin_spec/2, [], SpecFiles).

read_and_validate_plugin_spec(File, Acc) ->
    {ok, Bin} = file:read_file(File),
    {KVs} = ejson:decode(Bin),
    validate_plugin_spec(KVs, Acc).

-spec validate_plugin_spec([{binary(), binary()}], plugins()) -> plugins().
validate_plugin_spec(KVs, Plugins) ->
    ServiceName = binary_to_atom(get_element(<<"service">>, KVs), latin1),
    ProxyStrategy = decode_proxy_strategy(get_element(<<"proxy-strategy">>,
                                                      KVs)),
    RestApiPrefix = binary_to_list(get_element(<<"rest-api-prefix">>, KVs)),
    DocRoot = decode_docroot(get_element(<<"doc-root">>, KVs)),
    case {valid_service(ServiceName),
          find_plugin_by_prefix(RestApiPrefix, Plugins)} of
        {true, false} ->
            ?log_info("Loaded pluggable UI specification for ~p~n",
                      [ServiceName]),
            [#plugin{name = ServiceName,
                     proxy_strategy = ProxyStrategy,
                     rest_api_prefix = RestApiPrefix,
                     doc_root = DocRoot} | Plugins];
        {true, #plugin{}} ->
            ?log_info("Pluggable UI specification for ~p not loaded, "
                      "duplicate REST API prefix ~p~n",
                      [ServiceName, RestApiPrefix]),
            Plugins;
        {false, _} ->
            ?log_info("Pluggable UI specification for ~p not loaded~n",
                      [ServiceName]),
            Plugins
    end.

valid_service(ServiceName) ->
    lists:member(ServiceName,
                 ns_cluster_membership:supported_services()).

get_element(Key, KVs) ->
    {Key, Val} = lists:keyfind(Key, 1, KVs),
    Val.

decode_proxy_strategy(<<"local">>) ->
    local.

%% When run from cluster_run doc-root may be a list of directories.
%% DocRoot has to be a list in order for mochiweb to be able to guess
%% the MIME type.
decode_docroot(Roots) ->
    Prefix = path_config:component_path(?DOCROOTS_DIR),
    decode_docroot(Prefix, Roots).

decode_docroot(Prefix, Roots) when is_list(Roots) ->
    {multiple_roots, [decode_docroot(Prefix, Root) || Root <- Roots]};
decode_docroot(Prefix, Root) ->
    filename:join(Prefix, binary_to_list(Root)).

%%% =============================================================
%%%
proxy_req(RestPrefix, Path, Plugins, Req) ->
    case find_plugin_by_prefix(RestPrefix, Plugins) of
        #plugin{name = Service, proxy_strategy = ProxyStrategy} ->
            case address_and_port_for(Service, ProxyStrategy) of
                HostPort when is_tuple(HostPort) ->
                    Timeout = get_timeout(Service, Req),
                    AuthToken = auth_token(Service, Req),
                    Headers = AuthToken ++ convert_headers(Req),
                    do_proxy_req(HostPort, Path, Headers, Timeout, Req);
                Error ->
                    server_error(Req, Service, Error)
            end;
        false ->
            server_error(Req, RestPrefix, unknown_service)
    end.

address_and_port_for(Service, local) ->
    case should_run_service(Service, node()) of
        true ->
            address_and_port(Service, node());
        false ->
            service_not_running
    end.

should_run_service(views, Node) ->
    should_run_service(kv, Node);
should_run_service(Service, Node) ->
    ns_cluster_membership:should_run_service(Service, Node).

address_and_port(Service, Node) ->
    Addr = node_address(Node),
    Port = port_for(Service, Node),
    {Addr, Port}.

node_address(Node) ->
    {_Node, Addr} = misc:node_name_host(Node),
    Addr.

port_for(fts, Node) ->
    {value, Port} = ns_config:search(ns_config:latest(),
                                     {node, Node, fts_http_port}),
    Port;

port_for(n1ql, Node) ->
    {value, Port} = ns_config:search(ns_config:latest(),
                                     {node, Node, query_port}),
    Port;

port_for(views, Node) ->
    {value, Port} = ns_config:search(ns_config:latest(),
                                     {node, Node, capi_port}),
    Port.

get_timeout(views, Req) ->
    Params = Req:parse_qs(),
    list_to_integer(proplists:get_value("connection_timeout", Params, "30000"));
get_timeout(_Service, _Req) ->
    ?TIMEOUT.

auth_token(views, _Req) ->
    [{"Capi-Auth-Token", atom_to_list(ns_server:get_babysitter_cookie())}];
auth_token(_Service, Req) ->
    case menelaus_auth:extract_ui_auth_token(Req) of
        undefined ->
            [];
        Token ->
            [{"ns-server-auth-token", Token}]
    end.

convert_headers(Req) ->
    Headers = mochiweb_headers:to_list(Req:get(headers)),
    lists:filtermap(fun ({'Content-Length', _Value}) ->
                            false;
                        ({'Transfer-Encoding', _Value}) ->
                            false;
                        ({Name, Value}) ->
                            {true, {convert_header_name(Name), Value}}
                    end, Headers).

convert_header_name(Header) when is_atom(Header) ->
    atom_to_list(Header);
convert_header_name(Header) when is_list(Header) ->
    Header.

do_proxy_req({Host, Port}, Path, Headers, Timeout, Req) ->
    Method = Req:get(method),
    Body = get_body(Req),
    Options = [{partial_download, [{window_size, ?WINDOW_SIZE},
                                   {part_size, ?PART_SIZE}]}],
    Resp = lhttpc:request(Host, Port, false, Path, Method, Headers, Body,
                          Timeout, Options),
    handle_resp(Resp, Req).

get_body(Req) ->
    case Req:recv_body() of
        Body when is_binary(Body) ->
            Body;
        undefined ->
            <<>>
    end.

handle_resp({ok, {{StatusCode, _ReasonPhrase}, RcvdHeaders, Pid}}, Req)
  when is_pid(Pid) ->
    SendHeaders = filter_resp_headers(RcvdHeaders),
    Resp = start_response(Req, StatusCode, SendHeaders),
    stream_body(Pid, Resp);
handle_resp({ok, {{StatusCode, _ReasonPhrase}, RcvdHeaders, undefined = _Body}},
            Req) ->
    SendHeaders = filter_resp_headers(RcvdHeaders),
    menelaus_util:respond(Req, {StatusCode, SendHeaders, <<>>});
handle_resp({error, _Reason}=Error, Req) ->
    ?log_error("http client error ~p~n", [Error]),
    menelaus_util:respond(Req, {500, [], <<"Unexpected server error">> }).

filter_resp_headers(Headers) ->
    lists:filter(fun is_safe_response_header/1, Headers).

is_safe_response_header({"Content-Length", _}) ->
    false;
is_safe_response_header({"Transfer-Encoding", _}) ->
    false;
is_safe_response_header(_) ->
    true.

start_response(Req, StatusCode, Headers) ->
    menelaus_util:respond(Req, {StatusCode, Headers, chunked}).

stream_body(Pid, Resp) ->
    case lhttpc:get_body_part(Pid) of
        {ok, Part} when is_binary(Part) ->
            Resp:write_chunk(Part),
            stream_body(Pid, Resp);
        {ok, {http_eob, _Trailers}} ->
            Resp:write_chunk(<<>>)
    end.

server_error(Req, Service, service_not_running) ->
    Msg = list_to_binary("Service " ++ atom_to_list(Service)
                         ++ " not running on this node"),
    send_server_error(Req, Msg);
server_error(Req, RestPrefix, unknown_service) ->
    Msg = list_to_binary("Unknown REST prefix: " ++ RestPrefix),
    send_server_error(Req, Msg).

send_server_error(Req, Msg) ->
    menelaus_util:respond(Req, {404, [], Msg}).

%%% =============================================================
%%%
maybe_serve_file(RestPrefix, Plugins, Req, Path) ->
    case doc_root(RestPrefix, Plugins) of
        DocRoot when is_list(DocRoot) ->
            serve_file(Req, Path, DocRoot);
        {multiple_roots, DocRoots} ->
            serve_file_multiple_roots(Req, Path, DocRoots);
        undefined ->
            menelaus_util:reply_not_found(Req)
    end.

doc_root(RestPrefix, Plugins) ->
    case find_plugin_by_prefix(RestPrefix, Plugins) of
        #plugin{doc_root = DocRoot} ->
            DocRoot;
        false ->
            undefined
    end.

serve_file_multiple_roots(Req, Path, [DocRoot]) ->
    serve_file(Req, Path, DocRoot);
serve_file_multiple_roots(Req, Path, [DocRoot | DocRoots]) ->
    File = filename:join(DocRoot, Path),
    case filelib:is_regular(File) of
        true ->
            serve_file(Req, Path, DocRoot);
        false ->
            serve_file_multiple_roots(Req, Path, DocRoots)
    end.

serve_file(Req, Path, DocRoot) ->
    menelaus_util:serve_file(Req,
                             Path,
                             DocRoot,
                             [{"Cache-Control", "max-age=10"}]).

%%% =============================================================
%%%
-spec is_plugin(string(), plugins()) -> boolean().
is_plugin(Prefix, Plugins) ->
    case find_plugin_by_prefix(Prefix, Plugins) of
        #plugin{} ->
            true;
        _ ->
            false
    end.

find_plugin_by_prefix(Prefix, Plugins) ->
    find_plugin(Prefix, Plugins, #plugin.rest_api_prefix).

find_plugin(Prefix, Plugins, KeyPos) ->
    lists:keyfind(Prefix, KeyPos, Plugins).


%%% =============================================================
%%%
inject_head_fragments(AppRoot, Path, Plugins) ->
    inject_head_fragments(filename:join(AppRoot, Path), Plugins).

inject_head_fragments(File, Plugins) ->
    {ok, Index} = file:read_file(File),
    [Head, Tail] = split_index(Index),
    [Head, head_fragments(Plugins), Tail].

split_index(Bin) ->
    binary:split(Bin, ?HEAD_MARKER).

head_fragments(Plugins) ->
    [head_fragment(P) || P <- Plugins].

head_fragment(#plugin{name = Service, doc_root = DocRoot}) ->
    File = filename:join(DocRoot, ?HEAD_FRAG_HTML),
    Fragment = get_head_fragment(Service, File, file:read_file(File)),
    create_service_block(Service, Fragment).

get_head_fragment(_Service, _File, {ok, Bin}) ->
    Bin;
get_head_fragment(Service, File, {error, Reason}) ->
    Msg = lists:flatten(io_lib:format(
                          "Failed to read ~s for service ~p, reason '~p'",
                          [File, Service, Reason])),
    ?log_error(Msg),
    html_comment(Msg).

create_service_block(Service, Bin) ->
    SBin = atom_to_binary(Service, latin1),
    [start_of_fragment(SBin),
     Bin,
     end_of_fragment(SBin)].

start_of_fragment(Service) ->
    html_comment([<<"Beginning of head.frag.html for service ">>, Service]).

end_of_fragment(Service) ->
    html_comment([<<"End of head.frag.html for service ">>, Service]).

html_comment(Content) ->
    [<<"<!-- ">>, Content, <<" -->\n">>].
