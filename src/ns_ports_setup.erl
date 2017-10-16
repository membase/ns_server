-module(ns_ports_setup).

-include("ns_common.hrl").

-export([start/0, setup_body_tramp/0,
         restart_port_by_name/1, restart_moxi/0, restart_memcached/0,
         restart_xdcr_proxy/0, sync/0, create_erl_node_spec/4,
         create_goxdcr_upgrade_spec/1, shutdown_ports/0]).

-export([run_cbsasladm/1]).

start() ->
    proc_lib:start_link(?MODULE, setup_body_tramp, []).

sync() ->
    gen_server:call(?MODULE, sync, infinity).

shutdown_ports() ->
    gen_server:call(?MODULE, shutdown_ports, infinity).

%% ns_config announces full list as well which we don't need
is_useless_event(List) when is_list(List) ->
    true;
%% config changes for other nodes is quite obviously irrelevant
is_useless_event({{node, N, _}, _}) when N =/= node() ->
    true;
is_useless_event(_) ->
    false.

setup_body_tramp() ->
    misc:delaying_crash(1000, fun setup_body/0).

setup_body() ->
    Self = self(),
    erlang:register(?MODULE, Self),
    proc_lib:init_ack({ok, Self}),
    ns_pubsub:subscribe_link(ns_config_events,
                             fun (Event) ->
                                     case is_useless_event(Event) of
                                         false ->
                                             Self ! check_children_update;
                                         _ ->
                                             []
                                     end
                             end),
    ns_pubsub:subscribe_link(user_storage_events,
                             fun (_) ->
                                     Self ! check_children_update
                             end),
    Children = dynamic_children(normal),
    set_children_and_loop(Children, undefined, normal).

%% rpc:called (2.0.2+) after any bucket is deleted
restart_moxi() ->
    {ok, _} = restart_port_by_name(moxi),
    ok.

restart_memcached() ->
    {ok, _} = restart_port_by_name(memcached),
    ok.

restart_xdcr_proxy() ->
    case restart_port_by_name(xdcr_proxy) of
        {ok, _} ->
            ok;
        Error ->
            Error
    end.

restart_port_by_name(Name) ->
    ns_ports_manager:restart_port_by_name(ns_server:get_babysitter_node(), Name).

set_children(Children, Sup) ->
    Pid = ns_ports_manager:set_dynamic_children(ns_server:get_babysitter_node(), Children),
    case Sup of
        undefined ->
            {is_pid, true, Pid} = {is_pid, erlang:is_pid(Pid), Pid},
            ?log_debug("Monitor ns_child_ports_sup ~p", [Pid]),
            remote_monitors:monitor(Pid);
        Pid ->
            ok;
        _ ->
            ?log_debug("ns_child_ports_sup was restarted on babysitter node. Exit. Old pid = ~p, new pid = ~p",
                       [Sup, Pid]),
            erlang:error(child_ports_sup_died)
    end,
    Pid.

set_children_and_loop(Children, Sup, Status) ->
    NewSup = set_children(Children, Sup),
    children_loop(Children, NewSup, Status).

children_loop(Children, Sup, Status) ->
    proc_lib:hibernate(erlang, apply, [fun children_loop_continue/3, [Children, Sup, Status]]).

children_loop_continue(Children, Sup, Status) ->
    receive
        {'$gen_call', From, shutdown_ports} ->
            ?log_debug("Send shutdown to all go ports"),
            NewStatus = shutdown,
            NewChildren = dynamic_children(NewStatus),
            NewSup = set_children(NewChildren, Sup),
            gen_server:reply(From, ok),
            children_loop(NewChildren, NewSup, NewStatus);
        check_children_update ->
            do_children_loop_continue(Children, Sup, Status);
        {'$gen_call', From, sync} ->
            gen_server:reply(From, ok),
            children_loop(Children, Sup, Status);
        {remote_monitor_down, Sup, unpaused} ->
            ?log_debug("Remote monitor ~p was unpaused after node name change. Restart loop.", [Sup]),
            set_children_and_loop(dynamic_children(Status), undefined, Status);
        {remote_monitor_down, Sup, Reason} ->
            ?log_debug("ns_child_ports_sup ~p died on babysitter node with ~p. Restart.", [Sup, Reason]),
            erlang:error({child_ports_sup_died, Sup, Reason});
        X ->
            erlang:error({unexpected_message, X})
    after 0 ->
            erlang:error(expected_some_message)
    end.

do_children_loop_continue(Children, Sup, Status) ->
    %% this sets bound on frequency of checking of port_servers
    %% configuration updates. NOTE: this thing also depends on other
    %% config variables. Particularly moxi's environment variables
    %% need admin credentials. So we're forced to react on any config
    %% change
    timer:sleep(50),
    misc:flush(check_children_update),
    case dynamic_children(Status) of
        Children ->
            children_loop(Children, Sup, Status);
        NewChildren ->
            set_children_and_loop(NewChildren, Sup, Status)
    end.

maybe_create_ssl_proxy_spec(Config) ->
    UpstreamPort = ns_config:search(Config, {node, node(), ssl_proxy_upstream_port}, undefined),
    DownstreamPort = ns_config:search(Config, {node, node(), ssl_proxy_downstream_port}, undefined),
    LocalMemcachedPort = ns_config:search_node_prop(node(), Config, memcached, port),
    case UpstreamPort =/= undefined andalso DownstreamPort =/= undefined of
        true ->
            [create_ssl_proxy_spec(UpstreamPort, DownstreamPort, LocalMemcachedPort)];
        _ ->
            []
    end.

create_ssl_proxy_spec(UpstreamPort, DownstreamPort, LocalMemcachedPort) ->
    Path = ns_ssl_services_setup:ssl_cert_key_path(),
    CACertPath = ns_ssl_services_setup:ssl_cacert_key_path(),

    Args = [{upstream_port, UpstreamPort},
            {downstream_port, DownstreamPort},
            {local_memcached_port, LocalMemcachedPort},
            {cert_file, Path},
            {private_key_file, Path},
            {cacert_file, CACertPath},
            {ssl_minimum_protocol, ns_ssl_services_setup:ssl_minimum_protocol()}],

    ErlangArgs = ["-smp", "enable",
                  "+P", "327680",
                  "+K", "true",
                  "-kernel", "error_logger", "false",
                  "-sasl", "sasl_error_logger", "false",
                  "-nouser",
                  "-proto_dist", misc:get_proto_dist_type(),
                  "-run", "child_erlang", "child_start", "ns_ssl_proxy"],

    create_erl_node_spec(xdcr_proxy, Args, "NS_SSL_PROXY_ENV_ARGS", ErlangArgs).

create_erl_node_spec(Type, Args, EnvArgsVar, ErlangArgs) ->
    PathArgs = ["-pa"] ++ lists:reverse(code:get_path()),
    EnvArgsTail = [{K, V}
                   || {K, V} <- application:get_all_env(ns_server),
                      case atom_to_list(K) of
                          "error_logger" ++ _ -> true;
                          "path_config" ++ _ -> true;
                          "dont_suppress_stderr_logger" -> true;
                          "loglevel_" ++ _ -> true;
                          "disk_sink_opts" -> true;
                          "ssl_ciphers" -> true;
                          "net_kernel_verbosity" -> true;
                          "ipv6" -> true;
                          _ -> false
                      end],
    EnvArgs = Args ++ EnvArgsTail,

    AllArgs = PathArgs ++ ErlangArgs,

    ErlPath = filename:join([hd(proplists:get_value(root, init:get_arguments())),
                             "bin", "erl"]),

    Env0 = case os:getenv("ERL_CRASH_DUMP_BASE") of
               false ->
                   [];
               Base ->
                   [{"ERL_CRASH_DUMP", Base ++ "." ++ atom_to_list(Type)}]
           end,

    Env = [{EnvArgsVar, misc:inspect_term(EnvArgs)} | Env0],

    Options0 = [use_stdio, {env, Env}],
    Options =
        case misc:get_env_default(dont_suppress_stderr_logger, false) of
            true ->
                [ns_server_no_stderr_to_stdout | Options0];
            false ->
                Options0
        end,

    {Type, ErlPath, AllArgs, Options}.

per_bucket_moxi_specs(Config) ->
    case ns_cluster_membership:should_run_service(Config, kv, node()) of
        true ->
            do_per_bucket_moxi_specs(Config);
        false ->
            []
    end.

do_per_bucket_moxi_specs(Config) ->
    BucketConfigs = ns_bucket:get_buckets(Config),
    RestPort = ns_config:search_node_prop(Config, rest, port),
    Command = path_config:component_path(bin, "moxi"),
    lists:foldl(
      fun ({BucketName, BucketConfig}, Acc) ->
              case proplists:get_value(moxi_port, BucketConfig) of
                  undefined ->
                      Acc;
                  Port ->
                      Path = "/pools/default/bucketsStreaming/" ++ BucketName,
                      LittleZ = misc:local_url(RestPort, Path, []),
                      BigZ =
                          lists:flatten(
                            io_lib:format(
                              "port_listen=~B,downstream_max=1024,downstream_conn_max=4,"
                              "connect_max_errors=5,connect_retry_interval=30000,"
                              "connect_timeout=400,"
                              "auth_timeout=100,cycle=200,"
                              "downstream_conn_queue_timeout=200,"
                              "downstream_timeout=5000,wait_queue_timeout=200",
                              [Port])),
                      Args = ["-B", "auto", "-z", LittleZ, "-Z", BigZ,
                              "-p", "0", "-Y", "y", "-O", "stderr"],
                      Passwd = proplists:get_value(sasl_password, BucketConfig,
                                                   ""),
                      Opts = [use_stdio, stderr_to_stdout,
                              {env, [{"MOXI_SASL_PLAIN_USR", BucketName},
                                     {"MOXI_SASL_PLAIN_PWD", Passwd},
                                     {"http_proxy", ""}]}],
                      [{{moxi, BucketName}, Command, Args, Opts}|Acc]
              end
      end, [], BucketConfigs).

dynamic_children(Mode) ->
    Config = ns_config:get(),

    Specs = do_dynamic_children(Mode, Config),
    expand_specs(lists:flatten(Specs), Config).

do_dynamic_children(shutdown, Config) ->
    [memcached_spec(),
     moxi_spec(Config),
     saslauthd_port_spec(Config),
     per_bucket_moxi_specs(Config),
     maybe_create_ssl_proxy_spec(Config)];
do_dynamic_children(normal, Config) ->
    [memcached_spec(),
     moxi_spec(Config),
     kv_node_projector_spec(Config),
     index_node_spec(Config),
     query_node_spec(Config),
     saslauthd_port_spec(Config),
     goxdcr_spec(Config),
     per_bucket_moxi_specs(Config),
     maybe_create_ssl_proxy_spec(Config),
     fts_spec(Config),
     eventing_spec(Config),
     example_service_spec(Config)].

expand_specs(Specs, Config) ->
    [expand_args(S, Config) || S <- Specs].

query_node_spec(Config) ->
    case ns_cluster_membership:should_run_service(Config, n1ql, node()) of
        false ->
            [];
        _ ->
            RestPort = misc:node_rest_port(Config, node()),
            Command = path_config:component_path(bin, "cbq-engine"),
            DataStoreArg = "--datastore=" ++ misc:local_url(RestPort, []),
            CnfgStoreArg = "--configstore=" ++ misc:local_url(RestPort, []),
            HttpArg = "--http=:" ++ integer_to_list(query_rest:get_query_port(Config, node())),
            EntArg = "--enterprise=" ++ atom_to_list(cluster_compat_mode:is_enterprise()),

            HttpsArgs = case query_rest:get_ssl_query_port(Config, node()) of
                            undefined ->
                                [];
                            Port ->
                                ["--https=:" ++ integer_to_list(Port),
                                 "--certfile=" ++ ns_ssl_services_setup:memcached_cert_path(),
                                 "--keyfile=" ++ ns_ssl_services_setup:memcached_key_path(),
                                 "--ssl_minimum_protocol=" ++
                                     atom_to_list(ns_ssl_services_setup:ssl_minimum_protocol())]
                        end,
            Spec = {'query', Command,
                    [DataStoreArg, HttpArg, CnfgStoreArg, EntArg] ++ HttpsArgs,
                    [via_goport, exit_status, stderr_to_stdout,
                     {env, build_go_env_vars(Config, 'cbq-engine') ++
                          build_tls_config_env_var(Config)},
                     {log, ?QUERY_LOG_FILENAME}]},

            [Spec]
    end.

find_executable(Name) ->
    K = list_to_atom("ns_ports_setup-" ++ Name ++ "-available"),
    case erlang:get(K) of
        undefined ->
            Cmd = path_config:component_path(bin, Name),
            RV = os:find_executable(Cmd),
            erlang:put(K, RV),
            RV;
        V ->
            V
    end.

kv_node_projector_spec(Config) ->
    ProjectorCmd = find_executable("projector"),
    case ProjectorCmd =/= false andalso
        ns_cluster_membership:should_run_service(Config, kv, node()) of
        false ->
            [];
        _ ->
            % Projector is a component that is required by 2i
            ProjectorPort = ns_config:search(Config, {node, node(), projector_port}, 9999),
            RestPort = misc:node_rest_port(Config, node()),
            LocalMemcachedPort = ns_config:search_node_prop(node(), Config, memcached, port),
            MinidumpDir = path_config:minidump_dir(),

            Args = ["-kvaddrs=" ++ misc:local_url(LocalMemcachedPort, [no_scheme]),
                    "-adminport=:" ++ integer_to_list(ProjectorPort),
                    "-diagDir=" ++ MinidumpDir,
                    misc:local_url(RestPort, [no_scheme])],

            Spec = {'projector', ProjectorCmd, Args,
                    [via_goport, exit_status, stderr_to_stdout,
                     {log, ?PROJECTOR_LOG_FILENAME},
                     {env, build_go_env_vars(Config, projector)}]},
            [Spec]
    end.

goxdcr_spec(Config) ->
    Cmd = find_executable("goxdcr"),

    case cluster_compat_mode:is_goxdcr_enabled(Config) andalso
        Cmd =/= false of
        false ->
            [];
        true ->
            create_goxdcr_spec(Config, Cmd, false)
    end.

create_goxdcr_spec(Config, Cmd, Upgrade) ->
    AdminPort = "-sourceKVAdminPort=" ++
        integer_to_list(misc:node_rest_port(Config, node())),
    XdcrRestPort = "-xdcrRestPort=" ++
        integer_to_list(ns_config:search(Config, {node, node(), xdcr_rest_port}, 9998)),
    IsEnterprise = "-isEnterprise=" ++ atom_to_list(cluster_compat_mode:is_enterprise()),

    Args0 = [AdminPort, XdcrRestPort, IsEnterprise],

    Args1 = case Upgrade of
                true ->
                    ["-isConvert=true" | Args0];
                false ->
                    Args0
            end,

    UpstreamPort = ns_config:search(Config, {node, node(), ssl_proxy_upstream_port}, undefined),
    Args =
        case UpstreamPort of
            undefined ->
                Args1;
            _ ->
                LocalProxyPort = "-localProxyPort=" ++ integer_to_list(UpstreamPort),
                [LocalProxyPort | Args1]
        end,

    [{'goxdcr', Cmd, Args,
      [via_goport, exit_status, stderr_to_stdout,
       {log, ?GOXDCR_LOG_FILENAME},
       {env, build_go_env_vars(Config, goxdcr)}]}].

create_goxdcr_upgrade_spec(Config) ->
    Cmd = find_executable("goxdcr"),
    true = Cmd =/= false,
    [Spec] = create_goxdcr_spec(Config, Cmd, true),
    Spec.

index_node_spec(Config) ->
    case ns_cluster_membership:should_run_service(Config, index, node()) of
        false ->
            [];
        _ ->
            NumVBuckets = case ns_config:search(couchbase_num_vbuckets_default) of
                              false -> misc:getenv_int("COUCHBASE_NUM_VBUCKETS", 1024);
                              {value, X} -> X
                          end,
            IndexerCmd = path_config:component_path(bin, "indexer"),
            RestPort = misc:node_rest_port(Config, node()),
            AdminPort = ns_config:search(Config, {node, node(), indexer_admin_port}, 9100),
            ScanPort = ns_config:search(Config, {node, node(), indexer_scan_port}, 9101),
            HttpPort = ns_config:search(Config, {node, node(), indexer_http_port}, 9102),
            StInitPort = ns_config:search(Config, {node, node(), indexer_stinit_port}, 9103),
            StCatchupPort = ns_config:search(Config, {node, node(), indexer_stcatchup_port}, 9104),
            StMaintPort = ns_config:search(Config, {node, node(), indexer_stmaint_port}, 9105),
            {ok, IdxDir} = ns_storage_conf:this_node_ixdir(),
            IdxDir2 = filename:join(IdxDir, "@2i"),
            MinidumpDir = path_config:minidump_dir(),
            AddSM = case cluster_compat_mode:is_cluster_45() of
                        true ->
                            StorageMode =
                                index_settings_manager:get_from_config(Config,
                                                                       storageMode,
                                                                       undefined),
                            true = StorageMode =/= undefined,
                            ["-storageMode=" ++ binary_to_list(StorageMode)];
                        false ->
                            []
                    end,
            NodeUUID = binary_to_list(ns_config:uuid()),
            HttpsArgs = case ns_config:search(Config, {node, node(), indexer_https_port}, undefined) of
                            undefined ->
                                [];
                            Port ->
                                ["--httpsPort=" ++ integer_to_list(Port),
                                 "--certFile=" ++ ns_ssl_services_setup:memcached_cert_path(),
                                 "--keyFile=" ++ ns_ssl_services_setup:memcached_key_path()]
                        end,

            Spec = {'indexer', IndexerCmd,
                    ["-vbuckets=" ++ integer_to_list(NumVBuckets),
                     "-cluster=" ++ misc:local_url(RestPort, [no_scheme]),
                     "-adminPort=" ++ integer_to_list(AdminPort),
                     "-scanPort=" ++ integer_to_list(ScanPort),
                     "-httpPort=" ++ integer_to_list(HttpPort),
                     "-streamInitPort=" ++ integer_to_list(StInitPort),
                     "-streamCatchupPort=" ++ integer_to_list(StCatchupPort),
                     "-streamMaintPort=" ++ integer_to_list(StMaintPort),
                     "-storageDir=" ++ IdxDir2,
                     "-diagDir=" ++ MinidumpDir,
                     "-nodeUUID=" ++ NodeUUID,
                     "-isEnterprise=" ++ atom_to_list(cluster_compat_mode:is_enterprise())] ++ AddSM ++ HttpsArgs,
                    [via_goport, exit_status, stderr_to_stdout,
                     {log, ?INDEXER_LOG_FILENAME},
                     {env, build_go_env_vars(Config, index)}]},
            [Spec]
    end.

build_go_env_vars(Config, RPCService) ->
    GoTraceBack0 = ns_config:search(ns_config:latest(), gotraceback, <<"crash">>),
    GoTraceBack = binary_to_list(GoTraceBack0),
    [{"GOTRACEBACK", GoTraceBack} | build_cbauth_env_vars(Config, RPCService)].

build_tls_config_env_var(Config) ->
    [{"CBAUTH_TLS_CONFIG",
      binary_to_list(ejson:encode(
                       {[{minTLSVersion, ns_ssl_services_setup:ssl_minimum_protocol(Config)},
                         {ciphersStrength, ns_ssl_services_setup:ciphers_strength(Config)}]}))}].

build_cbauth_env_vars(Config, RPCService) ->
    true = (RPCService =/= undefined),
    RestPort = misc:node_rest_port(Config, node()),
    User = mochiweb_util:quote_plus(ns_config_auth:get_user(special)),
    Password = mochiweb_util:quote_plus(ns_config_auth:get_password(special)),
    URL = misc:local_url(RestPort, atom_to_list(RPCService), [{user_info, {User, Password}}]),
    [{"CBAUTH_REVRPC_URL", URL}].

saslauthd_port_spec(Config) ->
    Cmd = find_executable("saslauthd-port"),
    case Cmd =/= false of
        true ->
            [{saslauthd_port, Cmd, [],
              [use_stdio, exit_status, stderr_to_stdout,
               {env, build_go_env_vars(Config, saslauthd)}]}];
        _ ->
            []
    end.

expand_args({Name, Cmd, ArgsIn, OptsIn}, Config) ->
    %% Expand arguments
    Args0 = lists:map(fun ({Format, Keys}) ->
                              format(Config, Name, Format, Keys);
                          (X) -> X
                      end,
                      ArgsIn),
    Args = Args0 ++ ns_config:search(Config, {node, node(), {Name, extra_args}}, []),
    %% Expand environment variables within OptsIn
    Opts = lists:map(
             fun ({env, Env}) ->
                     {env, lists:map(
                             fun ({Var, {Format, Keys}}) ->
                                     {Var, format(Config, Name, Format, Keys)};
                                 (X) -> X
                             end, Env)};
                 (X) -> X
             end, OptsIn),
    {Name, Cmd, Args, Opts}.

format(Config, Name, Format, Keys) ->
    Values = lists:map(fun ({Module, FuncName, Args}) -> erlang:apply(Module, FuncName, Args);
                           ({Key, SubKey}) -> ns_config:search_node_prop(Config, Key, SubKey);
                           (Key) -> ns_config:search_node_prop(Config, Name, Key)
                       end, Keys),
    lists:flatten(io_lib:format(Format, Values)).

default_is_passwordless(Config) ->
    lists:member({"default", local}, menelaus_users:get_passwordless()) andalso
        lists:keymember("default", 1, ns_bucket:get_buckets(Config)).

should_run_moxi(Config) ->
    ns_cluster_membership:should_run_service(Config, kv, node())
        andalso
          ((not cluster_compat_mode:is_cluster_50(Config)) orelse
           default_is_passwordless(Config)).

moxi_spec(Config) ->
    case should_run_moxi(Config) of
        true ->
            do_moxi_spec();
        false ->
            []
    end.

do_moxi_spec() ->
    {moxi, path_config:component_path(bin, "moxi"),
     ["-Z", {"port_listen=~B,default_bucket_name=default,downstream_max=1024,downstream_conn_max=4,"
             "connect_max_errors=5,connect_retry_interval=30000,"
             "connect_timeout=400,"
             "auth_timeout=100,cycle=200,"
             "downstream_conn_queue_timeout=200,"
             "downstream_timeout=5000,wait_queue_timeout=200",
             [port]},
      "-z", "url=" ++ misc:local_url(misc:this_node_rest_port(),
                                     "/pools/default/saslBucketsStreaming?moxi=1", []),
      "-p", "0",
      "-Y", "y",
      "-O", "stderr",
      {"~s", [verbosity]}
     ],
     [{env, [{"EVENT_NOSELECT", "1"},
             {"MOXI_SASL_PLAIN_USR", {"~s", [{ns_moxi_sup, rest_user, []}]}},
             {"MOXI_SASL_PLAIN_PWD", {"~s", [{ns_moxi_sup, rest_pass, []}]}},
             {"http_proxy", ""}
            ]},
      use_stdio, exit_status,
      stderr_to_stdout,
      stream]
    }.

memcached_spec() ->
    {memcached, path_config:component_path(bin, "memcached"),
     ["-C", {"~s", [{memcached, config_path}]}],
     [{env, [{"EVENT_NOSELECT", "1"},
             %% NOTE: bucket engine keeps this number of top keys
             %% per top-keys-shard. And number of shards is hard-coded to 8
             %%
             %% So with previous setting of 100 we actually got 800
             %% top keys every time. Even if we need just 10.
             %%
             %% See hot_keys_keeper.erl TOP_KEYS_NUMBER constant
             %%
             %% Because of that heavy sharding we cannot ask for
             %% very small number, which would defeat usefulness
             %% LRU-based top-key maintenance in memcached. 5 seems
             %% not too small number which means that we'll deal
             %% with 40 top keys.
             {"MEMCACHED_TOP_KEYS", "5"},
             {"CBSASL_PWFILE", {"~s", [{isasl, path}]}}]},
      use_stdio,
      stderr_to_stdout, exit_status,
      port_server_dont_start,
      stream]
    }.

fts_spec(Config) ->
    FtCmd = find_executable("cbft"),
    NodeUUID = ns_config:search(Config, {node, node(), uuid}, false),
    case FtCmd =/= false andalso
        NodeUUID =/= false andalso
        ns_cluster_membership:should_run_service(Config, fts, node()) of
        false ->
            [];
        _ ->
            NsRestPort = misc:node_rest_port(Config, node()),
            FtRestPort = ns_config:search(Config, {node, node(), fts_http_port}, 8094),
            {ok, IdxDir} = ns_storage_conf:this_node_ixdir(),
            FTSIdxDir = filename:join(IdxDir, "@fts"),
            ok = misc:ensure_writable_dir(FTSIdxDir),
            {_, Host} = misc:node_name_host(node()),
            BindHttp = io_lib:format("~s:~b,~s:~b", [misc:maybe_add_brackets(Host), FtRestPort,
                                                     misc:inaddr_any([url]),
                                                     FtRestPort]),
            BindHttps = case ns_config:search(Config, {node, node(), fts_ssl_port}, undefined) of
                            undefined ->
                                [];
                            Port ->
                                ["-bindHttps=:" ++ integer_to_list(Port),
                                 "-tlsCertFile=" ++ ns_ssl_services_setup:memcached_cert_path(),
                                 "-tlsKeyFile=" ++ ns_ssl_services_setup:memcached_key_path()]
                        end,
            {ok, FTSMemoryQuota} = ns_storage_conf:get_memory_quota(Config, fts),
            MaxReplicasAllowed = case cluster_compat_mode:is_enterprise() of
                                     true -> 3;
                                     false -> 0
                                 end,
            BucketTypesAllowed = case cluster_compat_mode:is_enterprise() of
                                     true -> "membase:ephemeral";
                                     false -> "membase"
                                 end,
            Options = "startCheckServer=skip," ++
                      "slowQueryLogTimeout=5s," ++
                      "defaultMaxPartitionsPerPIndex=171," ++
                      "bleveMaxResultWindow=10000," ++
                      "failoverAssignAllPrimaries=false," ++
                      "hideUI=true," ++
                      "cbaudit=" ++ atom_to_list(cluster_compat_mode:is_enterprise()) ++ "," ++
                      "ftsMemoryQuota=" ++ integer_to_list(FTSMemoryQuota * 1024000) ++ "," ++
                      "maxReplicasAllowed=" ++ integer_to_list(MaxReplicasAllowed) ++ "," ++
                      "bucketTypesAllowed=" ++ BucketTypesAllowed,
            Spec = {fts, FtCmd,
                    [
                     "-cfg=metakv",
                     "-uuid=" ++ NodeUUID,
                     "-server=" ++ misc:local_url(NsRestPort, []),
                     "-bindHttp=" ++ BindHttp,
                     "-dataDir=" ++ FTSIdxDir,
                     "-tags=feed,janitor,pindex,queryer,cbauth_service",
                     "-auth=cbauth",
                     "-extra=" ++ io_lib:format("~s:~b", [Host, NsRestPort]),
                     "-options=" ++ Options
                    ] ++ BindHttps,
                    [via_goport, exit_status, stderr_to_stdout,
                     {log, ?FTS_LOG_FILENAME},
                     {env, build_go_env_vars(Config, fts) ++ build_tls_config_env_var(Config)}]},
            [Spec]
    end.

eventing_spec(Config) ->
    Command = path_config:component_path(bin, "eventing-producer"),
    NodeUUID = ns_config:search(Config, {node, node(), uuid}, false),

    case Command =/= false andalso
        NodeUUID =/= false andalso
        ns_cluster_membership:should_run_service(Config, eventing, node()) of
        true ->
            EventingAdminPort = ns_config:search(Config, {node, node(), eventing_http_port}, 8095),
            LocalMemcachedPort = ns_config:search_node_prop(node(), Config, memcached, port),
            RestPort = misc:node_rest_port(Config, node()),

            {ok, IdxDir} = ns_storage_conf:this_node_ixdir(),
            EventingDir = filename:join(IdxDir, "@eventing"),

            EventingAdminArg = "-adminport=" ++ integer_to_list(EventingAdminPort),
            EventingDirArg = "-dir=" ++ EventingDir,
            KVAddrArg = "-kvport=" ++ integer_to_list(LocalMemcachedPort),
            RestArg = "-restport=" ++ integer_to_list(RestPort),
            UUIDArg = "-uuid=" ++ binary_to_list(NodeUUID),

            Spec = {eventing, Command,
                    [EventingAdminArg, EventingDirArg, KVAddrArg, RestArg, UUIDArg],
                    [via_goport, exit_status, stderr_to_stdout,
                     {env, build_go_env_vars(Config, eventing)},
                     {log, ?EVENTING_LOG_FILENAME}]},
            [Spec];
        false ->
            []
    end.


example_service_spec(Config) ->
    CacheCmd = find_executable("cache-service"),
    NodeUUID = ns_config:search(Config, {node, node(), uuid}, false),

    case CacheCmd =/= false andalso
        NodeUUID =/= false andalso
        ns_cluster_membership:should_run_service(Config, example, node()) of
        true ->
            Port = misc:node_rest_port(Config, node()) + 20000,
            {_, Host} = misc:node_name_host(node()),
            Args = ["-node-id", binary_to_list(NodeUUID),
                    "-host", Host ++ ":" ++ integer_to_list(Port)],
            Spec = {example, CacheCmd, Args,
                    [via_goport, exit_status, stderr_to_stdout,
                     {env, build_go_env_vars(Config, example)}]},
            [Spec];
        false ->
            []
    end.

run_cbsasladm(Iterations) ->
    Args = ["-i", integer_to_list(Iterations), "pwconv", "-", "-"],

    {ok, P} =
        goport:start_link(find_executable("cbsasladm"),
                          [exit_status, graceful_shutdown, stderr_to_stdout,
                           stream, binary,
                           {args, Args},
                           {name, false}]),
    P.
