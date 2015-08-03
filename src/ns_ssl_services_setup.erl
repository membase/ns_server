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

%% used by ssl proxy
-export([dh_params_der/0, supported_versions/0, supported_ciphers/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% state sanitization
-export([format_status/2]).

%% exported for debugging purposes
-export([low_security_ciphers/0]).

-import(couch_httpd, [make_arity_1_fun/1,
                      make_arity_2_fun/1,
                      make_arity_3_fun/1]).

-behavior(gen_server).

-record(state, {cert,
                pkey,
                compat_30,
                node}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_link_capi_service() ->
    case ns_config:search_node(ssl_capi_port) of
        {value, SSLPort} when SSLPort =/= undefined ->
            do_start_link_capi_service(SSLPort);
        _ ->
            ignore
    end.

do_start_link_capi_service(SSLPort) ->

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

%% generated using "openssl dhparam -outform DER 2048"
dh_params_der() ->
    <<48,130,1,8,2,130,1,1,0,152,202,99,248,92,201,35,238,246,
      5,77,93,120,10,118,129,36,52,111,193,167,220,49,229,106,
      105,152,133,121,157,73,158,232,153,197,197,21,171,140,
      30,207,52,165,45,8,221,162,21,199,183,66,211,247,51,224,
      102,214,190,130,96,253,218,193,35,43,139,145,89,200,250,
      145,92,50,80,134,135,188,205,254,148,122,136,237,220,
      186,147,187,104,159,36,147,217,117,74,35,163,145,249,
      175,242,18,221,124,54,140,16,246,169,84,252,45,47,99,
      136,30,60,189,203,61,86,225,117,255,4,91,46,110,167,173,
      106,51,65,10,248,94,225,223,73,40,232,140,26,11,67,170,
      118,190,67,31,127,233,39,68,88,132,171,224,62,187,207,
      160,189,209,101,74,8,205,174,146,173,80,105,144,246,25,
      153,86,36,24,178,163,64,202,221,95,184,110,244,32,226,
      217,34,55,188,230,55,16,216,247,173,246,139,76,187,66,
      211,159,17,46,20,18,48,80,27,250,96,189,29,214,234,241,
      34,69,254,147,103,220,133,40,164,84,8,44,241,61,164,151,
      9,135,41,60,75,4,202,133,173,72,6,69,167,89,112,174,40,
      229,171,2,1,2>>.

supported_versions() ->
    case application:get_env(ssl_versions) of
        {ok, Versions} ->
            Versions;
        undefined ->
            Patches = proplists:get_value(couchbase_patches,
                                          ssl:versions(), []),
            Versions0 = ['tlsv1.1', 'tlsv1.2'],

            case lists:member(tls_padding_check, Patches) of
                true ->
                    ['tlsv1' | Versions0];
                false ->
                    Versions0
            end
    end.

%% The list is obtained by running the following openssl command:
%%
%%   openssl ciphers LOW:RC4 | tr ':' '\n'
%%
low_security_ciphers_openssl() ->
    ["EDH-RSA-DES-CBC-SHA",
     "EDH-DSS-DES-CBC-SHA",
     "DH-RSA-DES-CBC-SHA",
     "DH-DSS-DES-CBC-SHA",
     "ADH-DES-CBC-SHA",
     "DES-CBC-SHA",
     "DES-CBC-MD5",
     "ECDHE-RSA-RC4-SHA",
     "ECDHE-ECDSA-RC4-SHA",
     "AECDH-RC4-SHA",
     "ADH-RC4-MD5",
     "ECDH-RSA-RC4-SHA",
     "ECDH-ECDSA-RC4-SHA",
     "RC4-SHA",
     "RC4-MD5",
     "RC4-MD5",
     "PSK-RC4-SHA",
     "EXP-ADH-RC4-MD5",
     "EXP-RC4-MD5",
     "EXP-RC4-MD5"].

openssl_cipher_to_erlang(Cipher) ->
    try ssl:suite_definition(ssl_cipher:openssl_suite(Cipher)) of
        V ->
            {ok, V}
    catch _:_ ->
            %% erlang is bad at reporting errors here; on R16B03 it just fails
            %% with function_clause error so I need to catch all here
            {error, unsupported}
    end.

low_security_ciphers() ->
    Ciphers = low_security_ciphers_openssl(),
    [EC || C <- Ciphers, {ok, EC} <- [openssl_cipher_to_erlang(C)]].

supported_ciphers() ->
    case application:get_env(ssl_ciphers) of
        {ok, Ciphers} ->
            Ciphers;
        undefined ->
            ssl:cipher_suites() -- low_security_ciphers()
    end.

ssl_server_opts() ->
    Path = ssl_cert_key_path(),
    [{keyfile, Path},
     {certfile, Path},
     {versions, supported_versions()},
     {cacertfile, ssl_cacert_key_path()},
     {dh, dh_params_der()},
     {ciphers, supported_ciphers()}].

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

build_state(CertPEM, PKeyPEM, Compat30, Node) ->
    BaseState = #state{cert = CertPEM,
                       pkey = PKeyPEM,
                       compat_30 = Compat30},
    case Compat30 of
        true ->
            BaseState#state{node = Node};
        false ->
            BaseState
    end.

init([]) ->
    ?log_info("Used ssl options:~n~p", [ssl_server_opts()]),

    Self = self(),
    ns_pubsub:subscribe_link(ns_config_events, fun config_change_detector_loop/2, Self),

    {CertPEM, PKeyPEM} = ns_server_cert:cluster_cert_and_pkey_pem(),
    Compat30 = cluster_compat_mode:is_cluster_30(),
    Node = node(),
    save_cert_pkey(CertPEM, PKeyPEM, Compat30, Node),
    proc_lib:init_ack({ok, Self}),

    %% it's possible that we crashed somehow and not passed updated
    %% cert and pkey to xdcr proxy. So we just attempt to restart it
    %% on every init
    restart_xdcr_proxy(),

    gen_server:enter_loop(?MODULE, [],
                          build_state(CertPEM, PKeyPEM, Compat30, Node)).

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

handle_info(cert_and_pkey_changed, OldState) ->
    misc:flush(cert_and_pkey_changed),
    {CertPEM, PKeyPEM} = ns_server_cert:cluster_cert_and_pkey_pem(),
    Compat30 = cluster_compat_mode:is_cluster_30(),
    Node = node(),
    NewState = build_state(CertPEM, PKeyPEM, Compat30, Node),
    case OldState =:= NewState of
        true ->
            {noreply, OldState};
        false ->
            ?log_info("Got certificate and pkey change"),
            save_cert_pkey(CertPEM, PKeyPEM, Compat30, Node),
            ?log_info("Wrote new pem file"),
            restart_ssl_services(),
            ?log_info("Restarted all ssl services"),
            {noreply, NewState}
    end;
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

    ok = clear_pem_cache().

restart_ssl_services() ->
    %% NOTE: We're going to talk to our supervisor so if we do it
    %% synchronously there's chance of deadlock if supervisor is about
    %% to shutdown us.
    %%
    %% We're not trapping exits and that makes this interaction safe.
    ok = ns_ssl_services_sup:restart_ssl_services(),
    restart_xdcr_proxy(),
    ok = ns_memcached:connect_and_send_isasl_refresh().

restart_xdcr_proxy() ->
    case (catch ns_ports_setup:restart_xdcr_proxy()) of
        ok -> ok;
        Err ->
            ?log_debug("Xdcr proxy restart failed. But that's usually normal. ~p", [Err])
    end.

clear_pem_cache() ->
    {module, ssl_manager} = code:ensure_loaded(ssl_manager),
    case erlang:function_exported(ssl_manager, clear_pem_cache, 0) of
        true ->
            ssl_manager:clear_pem_cache();
        false ->
            %% TODO: this case is here just to avoid crashes on R14 which we
            %% still want to support for some performance comparisons; not
            %% clearing caches causes "regenerate certificate" to take effect
            %% only after restart; we should remove it before the release
            ok
    end.
