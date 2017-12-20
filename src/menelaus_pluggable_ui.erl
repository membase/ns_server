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
-define(DEF_REQ_HEADERS_FILTER, {drop, ["content-length",
                                        "transfer-encoding",
                                        "ns-server-proxy-timeout"]}).
-define(DEF_RESP_HEADERS_FILTER, {drop, ["content-length",
                                         "transfer-encoding",
                                         "www-authenticate"]}).
-type service_name()   :: atom().
-type rest_api_prefix():: string().
-type proxy_strategy() :: local.
-type filter_op()      :: keep | drop.
-type ui_compat_version() :: [integer()].
-record(plugin, { name                   :: service_name(),
                  proxy_strategy         :: proxy_strategy(),
                  rest_api_prefix        :: rest_api_prefix(),
                  doc_roots              :: [string()],
                  version_dirs           :: [{ui_compat_version(), string()}],
                  request_headers_filter :: {filter_op(), [string()]}}).
-type plugin()  :: #plugin{}.
-type plugins() :: [plugin()].

-define(VIEW_PLUGIN, #plugin{name = views,
                             proxy_strategy = local,
                             rest_api_prefix = "couchBase",
                             doc_roots = [],
                             request_headers_filter = {keep, ["accept",
                                                              "accept-encoding",
                                                              "accept-language",
                                                              "authorization",
                                                              "cache-control",
                                                              "connection",
                                                              "content-type",
                                                              "pragma",
                                                              "referer"]}}).
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
    DocRoots = decode_docroots(get_element(<<"doc-root">>, KVs)),
    VersionDirs = decode_version_dirs(get_opt_element(<<"version-dirs">>, KVs)),
    ReqHdrFilter = decode_request_headers_filter(
                     get_opt_element(<<"request-headers-filter">>, KVs)),
    case {valid_service(ServiceName),
          find_plugin_by_prefix(RestApiPrefix, Plugins)} of
        {true, false} ->
            ?log_info("Loaded pluggable UI specification for ~p~n",
                      [ServiceName]),
            [#plugin{name = ServiceName,
                     proxy_strategy = ProxyStrategy,
                     rest_api_prefix = RestApiPrefix,
                     doc_roots = DocRoots,
                     version_dirs = VersionDirs,
                     request_headers_filter = ReqHdrFilter} | Plugins];
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

get_opt_element(Key, KVs) ->
    case lists:keyfind(Key, 1, KVs) of
        {Key, Val} ->
            Val;
        false ->
            undefined
    end.

decode_proxy_strategy(<<"local">>) ->
    local.

%% When run from cluster_run doc-root may be a list of directories.
%% DocRoot has to be a list in order for mochiweb to be able to guess
%% the MIME type.
decode_docroots(Roots) ->
    Prefix = path_config:component_path(?DOCROOTS_DIR),
    decode_docroots(Prefix, Roots).

decode_docroots(Prefix, Roots) when is_list(Roots) ->
    [create_docroot(Prefix, Root) || Root <- Roots];
decode_docroots(Prefix, Root) ->
    [create_docroot(Prefix, Root)].

create_docroot(Prefix, Root) ->
    filename:join(Prefix, binary_to_list(Root)).

decode_version_dirs(undefined) ->
    [{?DEFAULT_UI_COMPAT_VERSION, "."}];
decode_version_dirs(VersionDirs) ->
    [{get_element(<<"version">>, VersionDir),
      binary_to_list(get_element(<<"dir">>, VersionDir))} ||
        {VersionDir} <- VersionDirs].

decode_request_headers_filter(undefined) ->
    ?DEF_REQ_HEADERS_FILTER;
decode_request_headers_filter({[{Op, BinNames}]}) ->
    Names = [string:to_lower(binary_to_list(Name)) || Name <- BinNames],
    {binary_to_existing_atom(Op, latin1), Names}.

%%% =============================================================
%%%
proxy_req(RestPrefix, Path, Plugins, Req) ->
    case find_plugin_by_prefix(RestPrefix, Plugins) of
        #plugin{name = Service, proxy_strategy = ProxyStrategy,
                request_headers_filter = HdrFilter} ->
            case address_and_port_for(Service, ProxyStrategy) of
                HostPort when is_tuple(HostPort) ->
                    Timeout = get_timeout(Service, Req),
                    AuthToken = auth_token(Service, Req),
                    Headers = AuthToken ++ convert_headers(Req, HdrFilter),
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
    lookup_port(fts_http_port, Node);

port_for(cbas, Node) ->
    lookup_port(cbas_http_port, Node);

port_for(n1ql, Node) ->
    lookup_port(query_port, Node);

port_for(views, Node) ->
    lookup_port(capi_port, Node);

port_for(eventing, Node) ->
    lookup_port(eventing_http_port, Node).

lookup_port(Name, Node) ->
    {value, Port} = ns_config:search(ns_config:latest(),
                                     {node, Node, Name}),
    Port.

get_timeout(views, Req) ->
    Params = Req:parse_qs(),
    list_to_integer(proplists:get_value("connection_timeout", Params, "30000"));
get_timeout(_Service, Req) ->
    case Req:get_header_value("ns-server-proxy-timeout") of
        undefined ->
            ?TIMEOUT;
        Val ->
            list_to_integer(Val)
    end.

auth_token(_Service, Req) ->
    case menelaus_auth:extract_ui_auth_token(Req) of
        undefined ->
            [];
        Token ->
            [{"ns-server-ui","yes"},
             {"ns-server-auth-token", Token}]
    end.

convert_headers(Req, Filter) ->
    RawHeaders = mochiweb_headers:to_list(Req:get(headers)),
    Headers = [{convert_header_name(Name), Val} || {Name, Val} <- RawHeaders],
    filter_headers(Headers, Filter).

convert_header_name(Header) when is_atom(Header) ->
    atom_to_list(Header);
convert_header_name(Header) when is_list(Header) ->
    Header.

filter_headers(Headers, {keep, Names}) ->
    [Hdr || {Name, _} = Hdr <- Headers, member(Name, Names)];
filter_headers(Headers, {drop, Names}) ->
    [Hdr || {Name, _} = Hdr <- Headers, not member(Name, Names)].

member(Name, Names) ->
    lists:member(string:to_lower(Name), Names).

do_proxy_req({Host, Port}, Path, Headers, Timeout, Req) ->
    Method = Req:get(method),
    Body = get_body(Req),
    Options = [{partial_download, [{window_size, ?WINDOW_SIZE},
                                   {part_size, ?PART_SIZE}]}],
    Resp = lhttpc:request(Host, Port, false, Path, Method, Headers,
                          Body, Timeout, Options),
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
    SendHeaders = filter_headers(RcvdHeaders, ?DEF_RESP_HEADERS_FILTER),
    Resp = menelaus_util:reply(Req, chunked, StatusCode, SendHeaders),
    stream_body(Pid, Resp);
handle_resp({ok, {{StatusCode, _ReasonPhrase}, RcvdHeaders, undefined = _Body}},
            Req) ->
    SendHeaders = filter_headers(RcvdHeaders, ?DEF_RESP_HEADERS_FILTER),
    menelaus_util:reply_text(Req, <<>>, StatusCode, SendHeaders);
handle_resp({error, timeout}, Req) ->
    menelaus_util:reply_text(Req, <<"Gateway Timeout">>, 504);
handle_resp({error, _Reason}=Error, Req) ->
    ?log_error("http client error ~p~n", [Error]),
    menelaus_util:reply_text(Req, <<"Unexpected server error">>, 500).

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
    menelaus_util:reply_text(Req, Msg, 404).

%%% =============================================================
%%%
maybe_serve_file(RestPrefix, Plugins, Path, Req) ->
    case doc_roots(RestPrefix, Plugins) of
        DocRoots when is_list(DocRoots) ->
            serve_file_multiple_roots(Req, Path, DocRoots);
        undefined ->
            menelaus_util:reply_not_found(Req)
    end.

doc_roots(RestPrefix, Plugins) ->
    case find_plugin_by_prefix(RestPrefix, Plugins) of
        #plugin{doc_roots = DocRoots} ->
            DocRoots;
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

-spec inject_head_fragments(file:filename_all(), ui_compat_version(), plugins()) -> [binary()].
inject_head_fragments(File, UiCompatVersion, Plugins) ->
    {ok, Index} = file:read_file(File),
    [Head, Tail] = split_index(Index),
    [Head, head_fragments(UiCompatVersion, Plugins), Tail].

split_index(Bin) ->
    binary:split(Bin, ?HEAD_MARKER).

head_fragments(UiCompatVersion, Plugins) ->
    [head_fragment(UiCompatVersion, P) || P <- Plugins].

head_fragment(_UiCompatVersion, #plugin{doc_roots = []}) ->
    [];
head_fragment(UiCompatVersion, #plugin{name = Service, doc_roots = DocRoots,
                                       version_dirs = VersionDirs}) ->
    VersionDir = proplists:get_value(UiCompatVersion, VersionDirs),
    create_service_block(Service, find_head_fragments(Service, DocRoots, VersionDir)).

find_head_fragments(Service, _, undefined) ->
    Msg = io_lib:format("Pluggable component for service ~p is not supported for "
                        "this UI compat version", [Service]),
    ?log_error(Msg),
    html_comment(Msg);
find_head_fragments(Service, [DocRoot|DocRoots], VersionDir) ->
    [must_get_fragment(Service, DocRoot, VersionDir)
     | maybe_get_fragments(DocRoots, VersionDir)].

maybe_get_fragments(DocRoots, VersionDir) ->
    [maybe_get_head_fragment(DocRoot, VersionDir) || DocRoot <- DocRoots].

must_get_fragment(Service, DocRoot, VersionDir) ->
    Path = filename:join([DocRoot, VersionDir, ?HEAD_FRAG_HTML]),
    handle_must_get_fragment(Service, Path, file:read_file(Path)).

handle_must_get_fragment(_Service, File, {ok, Bin}) ->
    create_fragment_block(File, Bin);
handle_must_get_fragment(Service, File, {error, Reason}) ->
    Msg = lists:flatten(io_lib:format(
                          "Failed to read ~s for service ~p, reason '~p'",
                          [File, Service, Reason])),
    ?log_error(Msg),
    html_comment(Msg).

maybe_get_head_fragment(DocRoot, VersionDir) ->
    Path = filename:join([DocRoot, VersionDir, ?HEAD_FRAG_HTML]),
    handle_maybe_get_fragment(Path, file:read_file(Path)).

handle_maybe_get_fragment(File, {ok, Bin}) ->
    create_fragment_block(File, Bin);
handle_maybe_get_fragment(_File, {error, _Reason}) ->
    [].

create_service_block(Service, Fragments) ->
    SBin = atom_to_binary(Service, latin1),
    [start_of_service_fragment(SBin),
     Fragments,
     end_of_service_fragment(SBin)].

create_fragment_block(File, Bin) ->
    [start_of_docroot_fragment(File),
     Bin,
     end_of_docroot_fragment(File)].

start_of_service_fragment(Service) ->
    html_comment([<<"Beginning of head html fragments for service ">>, Service]).

end_of_service_fragment(Service) ->
    html_comment([<<"End of head html fragments for service ">>, Service]).

start_of_docroot_fragment(File) ->
    html_comment([<<"Beginning of ">>, File]).

end_of_docroot_fragment(File) ->
    html_comment([<<"End of ">>, File]).

html_comment(Content) ->
    [<<"<!-- ">>, Content, <<" -->\n">>].
