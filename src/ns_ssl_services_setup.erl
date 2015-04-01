%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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

-module(ns_ssl_services_setup).

-include("ns_common.hrl").

-export([start_link/0,
         start_link_capi_service/0,
         start_link_rest_service/0,
         ssl_cert_key_path/0,
         ssl_cacert_key_path/0,
         memcached_cert_path/0,
         memcached_key_path/0,
         sync_local_cert_and_pkey_change/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% state sanitization
-export([format_status/2]).

-import(couch_httpd, [make_arity_1_fun/1,
                      make_arity_2_fun/1,
                      make_arity_3_fun/1]).

-behavior(gen_server).

-record(state, {cert_state,
                reload_state}).

-record(cert_state, {cert,
                     pkey,
                     compat_30,
                     node}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_link_capi_service() ->
    case ns_config:search_node(ns_node_disco:ns_server_node(),
                               ns_config:latest_config_marker(),
                               ssl_capi_port) of
        {value, SSLPort} when SSLPort =/= undefined ->
            do_start_link_capi_service(SSLPort);
        _ ->
            ignore
    end.

do_start_link_capi_service(SSLPort) ->
    ok = ssl_manager:clear_pem_cache(),

    Options = [{port, SSLPort},
               {ssl, true},
               {ssl_opts, ssl_server_opts()}],

    %% the following is copied almost verbatim from couch_httpd.  The
    %% difference is that we don't touch "ssl" key of couch config and
    %% that we don't register on config changes.
    %%
    %% Not touching ssl key is important because otherwise main capi
    %% http service will restart itself. And I decided it's better to
    %% localize capi code here for now rather than change somewhat
    %% fossilized couchdb code.
    %%
    %% Also couchdb code is reformatted for ns_server formatting
    BindAddress = couch_config:get("httpd", "bind_address", any),
    DefaultSpec = "{couch_httpd_db, handle_request}",
    DefaultFun = make_arity_1_fun(
                   couch_config:get("httpd", "default_handler", DefaultSpec)),

    UrlHandlersList =
        lists:map(
          fun({UrlKey, SpecStr}) ->
                  {list_to_binary(UrlKey), make_arity_1_fun(SpecStr)}
          end, couch_config:get("httpd_global_handlers")),

    DbUrlHandlersList =
        lists:map(
          fun({UrlKey, SpecStr}) ->
                  {list_to_binary(UrlKey), make_arity_2_fun(SpecStr)}
          end, couch_config:get("httpd_db_handlers")),

    DesignUrlHandlersList =
        lists:map(
          fun({UrlKey, SpecStr}) ->
                  {list_to_binary(UrlKey), make_arity_3_fun(SpecStr)}
          end, couch_config:get("httpd_design_handlers")),

    UrlHandlers = dict:from_list(UrlHandlersList),
    DbUrlHandlers = dict:from_list(DbUrlHandlersList),
    DesignUrlHandlers = dict:from_list(DesignUrlHandlersList),
    {ok, ServerOptions} = couch_util:parse_term(
                            couch_config:get("httpd", "server_options", "[]")),
    {ok, SocketOptions} = couch_util:parse_term(
                            couch_config:get("httpd", "socket_options", "[]")),

    DbFrontendModule = list_to_atom(couch_config:get("httpd", "db_frontend", "couch_db_frontend")),

    Loop =
        fun(Req)->
                case SocketOptions of
                    [] ->
                        ok;
                    _ ->
                        ok = mochiweb_socket:setopts(Req:get(socket), SocketOptions)
                end,
                apply(couch_httpd, handle_request,
                      [Req, DbFrontendModule, DefaultFun, UrlHandlers, DbUrlHandlers, DesignUrlHandlers])
        end,

    %% set mochiweb options
    FinalOptions = lists:append([Options, ServerOptions,
                                 [{loop, Loop},
                                  {name, https},
                                  {ip, BindAddress}]]),

    %% launch mochiweb
    {ok, _Pid} = case mochiweb_http:start(FinalOptions) of
                     {ok, MochiPid} ->
                         {ok, MochiPid};
                     {error, Reason} ->
                         io:format("Failure to start Mochiweb: ~s~n",[Reason]),
                         throw({error, Reason})
                 end.

ssl_server_opts() ->
    Path = ssl_cert_key_path(),
    [{keyfile, Path},
     {certfile, Path},
     {versions, ['tlsv1', 'tlsv1.1', 'tlsv1.2']},
     {cacertfile, ssl_cacert_key_path()}].

start_link_rest_service() ->
    Config0 = menelaus_web:webconfig(),
    Config1 = lists:keydelete(port, 1, Config0),
    Config2 = lists:keydelete(name, 1, Config1),
    case ns_config:search_node(ssl_rest_port) of
        {value, SSLPort} when SSLPort =/= undefined ->
            Config3 = [{ssl, true},
                       {name, menelaus_web_ssl},
                       {ssl_opts, ssl_server_opts()},
                       {port, SSLPort}
                       | Config2],
            menelaus_web:start_link(Config3);
        _ ->
            ignore
    end.

ssl_cert_key_path() ->
    filename:join(path_config:component_path(data, "config"), "ssl-cert-key.pem").


raw_ssl_cacert_key_path() ->
    ssl_cert_key_path() ++ "-ca".

ssl_cacert_key_path() ->
    Path = raw_ssl_cacert_key_path(),
    case filelib:is_file(Path) of
        true ->
            Path;
        false ->
            undefined
    end.

local_cert_path_prefix() ->
    filename:join(path_config:component_path(data, "config"), "local-ssl-").

memcached_cert_path() ->
    filename:join(path_config:component_path(data, "config"), "memcached-cert.pem").

memcached_key_path() ->
    filename:join(path_config:component_path(data, "config"), "memcached-key.pem").

marker_path() ->
    filename:join(path_config:component_path(data, "config"), "reload_marker").

check_local_cert_and_pkey(ClusterCertPEM, Node) ->
    true = is_binary(ClusterCertPEM),
    try
        do_check_local_cert_and_pkey(ClusterCertPEM, Node)
    catch T:E ->
            {T, E}
    end.

do_check_local_cert_and_pkey(ClusterCertPEM, Node) ->
    {ok, MetaBin} = file:read_file(local_cert_path_prefix() ++ "meta"),
    Meta = erlang:binary_to_term(MetaBin),
    {ok, LocalCert} = file:read_file(local_cert_path_prefix() ++ "cert.pem"),
    {ok, LocalPKey} = file:read_file(local_cert_path_prefix() ++ "pkey.pem"),
    Digest = erlang:md5(term_to_binary({Node, ClusterCertPEM, LocalCert, LocalPKey})),
    {proplists:get_value(digest, Meta) =:= Digest, LocalCert, LocalPKey}.

sync_local_cert_and_pkey_change() ->
    ns_config:sync_announcements(),
    ok = gen_server:call(?MODULE, ping, infinity).

build_cert_state(CertPEM, PKeyPEM, Compat30, Node) ->
    BaseState = #cert_state{cert = CertPEM,
                            pkey = PKeyPEM,
                            compat_30 = Compat30},
    case Compat30 of
        true ->
            BaseState#cert_state{node = Node};
        false ->
            BaseState
    end.

init([]) ->
    Self = self(),
    ns_pubsub:subscribe_link(ns_config_events, fun config_change_detector_loop/2, Self),

    {CertPEM, PKeyPEM} = ns_server_cert:cluster_cert_and_pkey_pem(),
    Compat30 = cluster_compat_mode:is_cluster_30(),
    Node = node(),
    save_cert_pkey(CertPEM, PKeyPEM, Compat30, Node),
    RetrySvc = case misc:marker_exists(marker_path()) of
                   true ->
                       Self ! notify_services,
                       all_services() -- [ssl_service];
                   false ->
                       []
               end,
    {ok, #state{cert_state = build_cert_state(CertPEM, PKeyPEM, Compat30, Node),
                reload_state = RetrySvc}}.

format_status(_Opt, [_PDict, _State]) ->
    {}.

config_change_detector_loop({cert_and_pkey, _}, Parent) ->
    Parent ! cert_and_pkey_changed,
    Parent;
config_change_detector_loop({cluster_compat_version, _Version}, Parent) ->
    Parent ! cert_and_pkey_changed,
    Parent;
%% we're using this key to detect change of node() name
config_change_detector_loop({{node, _Node, capi_port}, _}, Parent) ->
    Parent ! cert_and_pkey_changed,
    Parent;
config_change_detector_loop(_OtherEvent, Parent) ->
    Parent.


handle_call(ping, _From, State) ->
    {reply, ok, State};
handle_call(_, _From, State) ->
    {reply, unknown_call, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(cert_and_pkey_changed, #state{cert_state = OldCertState} = State) ->
    misc:flush(cert_and_pkey_changed),
    {CertPEM, PKeyPEM} = ns_server_cert:cluster_cert_and_pkey_pem(),
    Compat30 = cluster_compat_mode:is_cluster_30(),
    Node = node(),
    NewCertState = build_cert_state(CertPEM, PKeyPEM, Compat30, Node),
    case OldCertState =:= NewCertState of
        true ->
            {noreply, State};
        false ->
            ?log_info("Got certificate and pkey change"),
            misc:create_marker(marker_path()),
            save_cert_pkey(CertPEM, PKeyPEM, Compat30, Node),
            ?log_info("Wrote new pem file"),
            self() ! notify_services,
            {noreply, #state{cert_state = NewCertState,
                             reload_state = all_services()}}
    end;
handle_info(notify_services, #state{reload_state = []} = State) ->
    misc:flush(notify_services),
    {noreply, State};
handle_info(notify_services, #state{reload_state = Reloads} = State) ->
    misc:flush(notify_services),
    RVs = misc:parallel_map(fun notify_service/1, Reloads, 60000),
    ResultPairs = lists:zip(RVs, Reloads),
    {Good, Bad} = lists:foldl(fun ({ok, Svc}, {AccGood, AccBad}) ->
                                      {[Svc | AccGood], AccBad};
                                  (ErrorPair, {AccGood, AccBad}) ->
                                      {AccGood, [ErrorPair | AccBad]}
                              end, {[], []}, ResultPairs),
    case Good of
        [] ->
            ok;
        _ ->
            ?log_debug("Succesfully notified services ~p", [Good])
    end,
    case Bad of
        [] ->
            misc:remove_marker(marker_path()),
            ok;
        _ ->
            ?log_debug("Failed to notify some services. Will retry in 5 sec, ~p", [Bad]),
            timer:send_after(5000, notify_services)
    end,
    {noreply, State#state{reload_state = [Svc || {_, Svc} <- Bad]}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

do_generate_local_cert(CertPEM, PKeyPEM, Node) ->
    {_, Host} = misc:node_name_host(node()),
    Args = ["--generate-leaf",
            "--common-name=" ++ Host],
    Env = [{"CACERT", binary_to_list(CertPEM)},
           {"CAPKEY", binary_to_list(PKeyPEM)}],
    {LocalCert, LocalPKey} = ns_server_cert:do_generate_cert_and_pkey(Args, Env),
    ok = misc:atomic_write_file(local_cert_path_prefix() ++ "pkey.pem", LocalPKey),
    ok = misc:atomic_write_file(local_cert_path_prefix() ++ "cert.pem", LocalCert),
    Meta = [{digest, erlang:md5(term_to_binary({Node, CertPEM, LocalCert, LocalPKey}))}],
    ok = misc:atomic_write_file(local_cert_path_prefix() ++ "meta", term_to_binary(Meta)),
    ?log_info("Saved local cert for node ~p", [Node]),
    {true, LocalCert, LocalPKey} = check_local_cert_and_pkey(CertPEM, Node),
    {LocalCert, LocalPKey}.

maybe_generate_local_cert(CertPEM, PKeyPEM, Node) ->
    case check_local_cert_and_pkey(CertPEM, Node) of
        {true, LocalCert, LocalPKey} ->
            {LocalCert, LocalPKey};
        {false, _, _} ->
            ?log_info("Detected existing node certificate that did not match cluster certificate. Will re-generate"),
            do_generate_local_cert(CertPEM, PKeyPEM, Node);
        Error ->
            ?log_info("Failed to read node certificate. Perhaps it wasn't created yet. Error: ~p", [Error]),
            do_generate_local_cert(CertPEM, PKeyPEM, Node)
    end.

save_cert_pkey(CertPEM, PKeyPEM, Compat30, Node) ->
    Path = ssl_cert_key_path(),
    case Compat30 of
        true ->
            {LocalCert, LocalPKey} = maybe_generate_local_cert(CertPEM, PKeyPEM, Node),
            ok = misc:atomic_write_file(Path, [LocalCert, LocalPKey]),
            ok = misc:atomic_write_file(raw_ssl_cacert_key_path(), CertPEM),
            ok = misc:atomic_write_file(memcached_cert_path(), [LocalCert, CertPEM]),
            ok = misc:atomic_write_file(memcached_key_path(), LocalPKey);
        false ->
            _ = file:delete(raw_ssl_cacert_key_path()),
            ok = misc:atomic_write_file(Path, [CertPEM, PKeyPEM]),
            ok = misc:atomic_write_file(memcached_cert_path(), CertPEM),
            ok = misc:atomic_write_file(memcached_key_path(), PKeyPEM)
    end,

    ok = ssl_manager:clear_pem_cache().

all_services() ->
    [ssl_service, capi_ssl_service, xdcr_proxy, query_svc, memcached].

notify_service(ssl_service) ->
    %% NOTE: We're going to talk to our supervisor so if we do it
    %% synchronously there's chance of deadlock if supervisor is about
    %% to shutdown us.
    %%
    %% We're not trapping exits and that makes this interaction safe.
    case ns_ssl_services_sup:restart_ssl_service() of
        ok ->
            ok;
        {error, not_running} ->
            ?log_info("Did not restart ssl rest service because it wasn't running"),
            ok
    end;
notify_service(capi_ssl_service) ->
    case ns_couchdb_api:restart_capi_ssl_service() of
        ok ->
            ok;
        {error, not_running} ->
            ?log_info("Did not restart capi ssl service because is wasn't running"),
            ok
    end;
notify_service(xdcr_proxy) ->
    ns_ports_setup:restart_xdcr_proxy();
notify_service(query_svc) ->
    query_rest:maybe_refresh_cert();
notify_service(memcached) ->
    ns_memcached:connect_and_send_ssl_certs_refresh().
