-module(ns_ports_setup).

-include("ns_common.hrl").

-export([start/0, start_memcached_force_killer/0, setup_body_tramp/0,
         restart_port_by_name/1, restart_moxi/0, restart_memcached/0,
         restart_xdcr_proxy/0, sync/0, create_erl_node_spec/4,
         create_goxdcr_upgrade_spec/1]).

start() ->
    proc_lib:start_link(?MODULE, setup_body_tramp, []).

sync() ->
    gen_server:call(?MODULE, sync, infinity).

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
    Children = dynamic_children(),
    set_children_and_loop(Children, undefined).

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
    rpc:call(ns_server:get_babysitter_node(), ns_child_ports_sup, restart_port_by_name, [Name]).

set_children_and_loop(Children, Sup) ->
    Pid = rpc:call(ns_server:get_babysitter_node(), ns_child_ports_sup, set_dynamic_children, [Children]),
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
    children_loop(Children, Pid).

children_loop(Children, Sup) ->
    proc_lib:hibernate(erlang, apply, [fun children_loop_continue/2, [Children, Sup]]).

children_loop_continue(Children, Sup) ->
    receive
        check_children_update ->
            do_children_loop_continue(Children, Sup);
        {'$gen_call', From, sync} ->
            gen_server:reply(From, ok),
            children_loop(Children, Sup);
        {remote_monitor_down, Sup, unpaused} ->
            ?log_debug("Remote monitor ~p was unpaused after node name change. Restart loop.", [Sup]),
            set_children_and_loop(dynamic_children(), undefined);
        {remote_monitor_down, Sup, Reason} ->
            ?log_debug("ns_child_ports_sup ~p died on babysitter node with ~p. Restart.", [Sup, Reason]),
            erlang:error({child_ports_sup_died, Sup, Reason});
        X ->
            erlang:error({unexpected_message, X})
    after 0 ->
            erlang:error(expected_some_message)
    end.

do_children_loop_continue(Children, Sup) ->
    %% this sets bound on frequency of checking of port_servers
    %% configuration updates. NOTE: this thing also depends on other
    %% config variables. Particularly moxi's environment variables
    %% need admin credentials. So we're forced to react on any config
    %% change
    timer:sleep(50),
    misc:flush(check_children_update),
    case dynamic_children() of
        Children ->
            children_loop(Children, Sup);
        NewChildren ->
            set_children_and_loop(NewChildren, Sup)
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
            {cacert_file, CACertPath}],

    ErlangArgs = ["-smp", "enable",
                  "+P", "327680",
                  "+K", "true",
                  "-kernel", "error_logger", "false",
                  "-sasl", "sasl_error_logger", "false",
                  "-nouser",
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
      fun ({"default", _}, Acc) ->
              Acc;
          ({BucketName, BucketConfig}, Acc) ->
              case proplists:get_value(moxi_port, BucketConfig) of
                  undefined ->
                      Acc;
                  Port ->
                      LittleZ =
                          lists:flatten(
                            io_lib:format(
                              "url=http://127.0.0.1:~B/pools/default/"
                              "bucketsStreaming/~s",
                              [RestPort, BucketName])),
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
                                     {"MOXI_SASL_PLAIN_PWD", Passwd}]}],
                      [{{moxi, BucketName}, Command, Args, Opts}|Acc]
              end
      end, [], BucketConfigs).

dynamic_children() ->
    Config = ns_config:get(),

    Specs = [memcached_spec(Config),
             moxi_spec(Config),
             run_via_goport(kv_node_projector_spec(Config)),
             run_via_goport(index_node_spec(Config)),
             run_via_goport(query_node_spec(Config)),
             saslauthd_port_spec(Config),
             run_via_goport(goxdcr_spec(Config)),
             per_bucket_moxi_specs(Config),
             maybe_create_ssl_proxy_spec(Config)],

    lists:flatten(Specs).

query_node_spec(Config) ->
    case ns_cluster_membership:should_run_service(Config, n1ql, node()) of
        false ->
            [];
        _ ->
            RestPort = misc:node_rest_port(Config, node()),
            Command = path_config:component_path(bin, "cbq-engine"),
            DataStoreArg = "--datastore=http://127.0.0.1:" ++ integer_to_list(RestPort),
            CnfgStoreArg = "--configstore=http://127.0.0.1:" ++ integer_to_list(RestPort),
            HttpArg = "--http=:" ++ integer_to_list(query_rest:get_query_port(Config, node())),

            HttpsArgs = case query_rest:get_ssl_query_port(Config, node()) of
                            undefined ->
                                [];
                            Port ->
                                ["--https=:" ++ integer_to_list(Port),
                                 "--certfile=" ++ ns_ssl_services_setup:ssl_cert_key_path(),
                                 "--keyfile=" ++ ns_ssl_services_setup:ssl_cert_key_path()]
                        end,
            Spec = {'query', Command,
                    [DataStoreArg, HttpArg, CnfgStoreArg] ++ HttpsArgs,
                    [use_stdio, exit_status, stderr_to_stdout, stream,
                     {env, build_go_env_vars(Config, 'cbq-engine')},
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
            ClusterArg = "127.0.0.1:" ++ integer_to_list(RestPort),
            KvListArg = "-kvaddrs=127.0.0.1:" ++ integer_to_list(LocalMemcachedPort),
            AdminPortArg = "-adminport=:" ++ integer_to_list(ProjectorPort),
            ProjLogArg = "-debug=true",

            Spec = {'projector', ProjectorCmd,
                    [ProjLogArg, KvListArg, AdminPortArg, ClusterArg],
                    [use_stdio, exit_status, stderr_to_stdout, stream,
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
      [use_stdio, exit_status, stderr_to_stdout, stream,
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

            Spec = {'indexer', IndexerCmd,
                    [
                         "-log=2",
                         "-vbuckets=" ++ integer_to_list(NumVBuckets),
                         "-cluster=127.0.0.1:" ++ integer_to_list(RestPort),
                         "-adminPort=" ++ integer_to_list(AdminPort),
                         "-scanPort=" ++ integer_to_list(ScanPort),
                         "-httpPort=" ++ integer_to_list(HttpPort),
                         "-streamInitPort=" ++ integer_to_list(StInitPort),
                         "-streamCatchupPort=" ++ integer_to_list(StCatchupPort),
                         "-streamMaintPort=" ++ integer_to_list(StMaintPort),
                         "-storageDir=" ++ IdxDir2
                     ],
                    [use_stdio, exit_status, stderr_to_stdout, stream,
                     {log, ?INDEXER_LOG_FILENAME},
                     {env, build_go_env_vars(Config, index)}]},
            [Spec]
    end.

build_go_env_vars(Config, RPCService) ->
    GoTraceBack =
        case os:getenv("GOTRACEBACK") of
            false ->
                "crash";
            V ->
                V
        end,

    [{"GOTRACEBACK", GoTraceBack} | build_cbauth_env_vars(Config, RPCService)].

build_cbauth_env_vars(Config, RPCService) ->
    true = (RPCService =/= undefined),
    RestPort = misc:node_rest_port(Config, node()),
    User = mochiweb_util:quote_plus(ns_config_auth:get_user(special)),
    Password = mochiweb_util:quote_plus(ns_config_auth:get_password(special)),

    URL0 = io_lib:format("http://~s:~s@127.0.0.1:~b/~s",
                         [User, Password, RestPort, RPCService]),
    URL = lists:flatten(URL0),

    [{"CBAUTH_REVRPC_URL", URL}].

saslauthd_port_spec(Config) ->
    Cmd = find_executable("saslauthd-port"),
    case Cmd =/= false of
        true ->
            [{saslauthd_port, Cmd, [],
              [use_stdio, exit_status, stderr_to_stdout, stream,
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

start_memcached_force_killer() ->
    misc:start_event_link(
      fun () ->
              CurrentMembership = ns_cluster_membership:get_cluster_membership(node()),
              ns_pubsub:subscribe_link(ns_config_events, fun memcached_force_killer_fn/2, CurrentMembership)
      end).

memcached_force_killer_fn({{node, Node, membership}, NewMembership}, PrevMembership) when Node =:= node() ->
    case NewMembership =:= inactiveFailed andalso PrevMembership =/= inactiveFailed of
        false ->
            ok;
        _ ->
            RV = rpc:call(ns_server:get_babysitter_node(),
                          ns_child_ports_sup, send_command, [memcached, <<"die!\n">>]),
            ?log_info("Sent force death command to own memcached: ~p", [RV])
    end,
    NewMembership;

memcached_force_killer_fn(_, State) ->
    State.

run_via_goport(Specs) ->
    lists:map(fun do_run_via_goport/1, Specs).

do_run_via_goport({Name, Cmd, Args, Opts}) ->
    GoportName =
        case erlang:system_info(system_architecture) of
            "win32" ->
                "goport.exe";
            _ ->
                "goport"
        end,

    GoportPath = path_config:component_path(bin, GoportName),
    GoportArgsEnv = binary_to_list(ejson:encode([list_to_binary(L) || L <- [Cmd | Args]])),

    Env = proplists:get_value(env, Opts, []),
    Env1 = [{"GOPORT_ARGS", GoportArgsEnv} | Env],

    Opts1 = lists:keystore(env, 1, Opts, {env, Env1}),
    {Name, GoportPath, [], Opts1}.

moxi_spec(Config) ->
    case ns_cluster_membership:should_run_service(Config, kv, node()) of
        true ->
            do_moxi_spec(Config);
        false ->
            []
    end.

do_moxi_spec(Config) ->
    Spec = {moxi, path_config:component_path(bin, "moxi"),
            ["-Z", {"port_listen=~B,default_bucket_name=default,downstream_max=1024,downstream_conn_max=4,"
                    "connect_max_errors=5,connect_retry_interval=30000,"
                    "connect_timeout=400,"
                    "auth_timeout=100,cycle=200,"
                    "downstream_conn_queue_timeout=200,"
                    "downstream_timeout=5000,wait_queue_timeout=200",
                    [port]},
             "-z", {"url=http://127.0.0.1:~B/pools/default/saslBucketsStreaming",
                    [{misc, this_node_rest_port, []}]},
             "-p", "0",
             "-Y", "y",
             "-O", "stderr",
             {"~s", [verbosity]}
            ],
            [{env, [{"EVENT_NOSELECT", "1"},
                    {"MOXI_SASL_PLAIN_USR", {"~s", [{ns_moxi_sup, rest_user, []}]}},
                    {"MOXI_SASL_PLAIN_PWD", {"~s", [{ns_moxi_sup, rest_pass, []}]}}
                   ]},
             use_stdio, exit_status,
             stderr_to_stdout,
             stream]
           },

    [expand_args(Spec, Config)].

memcached_spec(Config) ->
    Spec = {memcached, path_config:component_path(bin, "memcached"),
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
                    {"ISASL_PWFILE", {"~s", [{isasl, path}]}}]},
             use_stdio,
             stderr_to_stdout, exit_status,
             port_server_dont_start,
             stream]
           },

    [expand_args(Spec, Config)].
