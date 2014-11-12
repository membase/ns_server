-module(ns_ports_setup).

-include("ns_common.hrl").

-export([start/0, start_memcached_force_killer/0, setup_body_tramp/0,
         restart_port_by_name/1, restart_moxi/0, restart_memcached/0,
         restart_xdcr_proxy/0, sync/0, create_erl_node_spec/4]).

%% referenced by config
-export([omit_missing_mcd_ports/2]).

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
    set_children_and_loop(Children).

%% rpc:called (2.0.2+) after any bucket is deleted
restart_moxi() ->
    {ok, _} = restart_port_by_name(moxi),
    ok.

restart_memcached() ->
    {ok, _} = restart_port_by_name(memcached),
    ok.

restart_xdcr_proxy() ->
    {ok, _} = restart_port_by_name(xdcr_proxy),
    ok.

restart_port_by_name(Name) ->
    rpc:call(ns_server:get_babysitter_node(), ns_child_ports_sup, restart_port_by_name, [Name]).

set_children_and_loop(Children) ->
    Pid = rpc:call(ns_server:get_babysitter_node(), ns_child_ports_sup, set_dynamic_children, [Children]),
    {is_pid, true, Pid} = {is_pid, erlang:is_pid(Pid), Pid},
    erlang:link(Pid),
    children_loop(Children).

children_loop(Children) ->
    proc_lib:hibernate(erlang, apply, [fun children_loop_continue/1, [Children]]).

children_loop_continue(Children) ->
    receive
        check_children_update ->
            do_children_loop_continue(Children);
        {'$gen_call', From, sync} ->
            gen_server:reply(From, ok),
            children_loop(Children);
        X ->
            erlang:error({unexpected_message, X})
    after 0 ->
            erlang:error(expected_some_message)
    end.

do_children_loop_continue(Children) ->
    %% this sets bound on frequency of checking of port_servers
    %% configuration updates. NOTE: this thing also depends on other
    %% config variables. Particularly moxi's environment variables
    %% need admin credentials. So we're forced to react on any config
    %% change
    timer:sleep(50),
    misc:flush(check_children_update),
    case dynamic_children() of
        Children ->
            children_loop(Children);
        NewChildren ->
            set_children_and_loop(NewChildren)
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

    Options0 = [use_stdio, port_server_send_eol, {env, Env}],
    Options =
        case misc:get_env_default(dont_suppress_stderr_logger, false) of
            true ->
                [ns_server_no_stderr_to_stdout | Options0];
            false ->
                Options0
        end,

    {Type, ErlPath, AllArgs, Options}.

per_bucket_moxi_specs(Config) ->
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

    {value, PortServers} = ns_config:search_node(Config, port_servers),

    MaybeSSLProxySpec = maybe_create_ssl_proxy_spec(Config),

    [expand_args(NCAO) || NCAO <- PortServers,
                          allowed_service(NCAO, Config)] ++
        kv_node_projector_spec(Config) ++
        index_node_spec(Config) ++
        query_node_spec(Config) ++
        per_bucket_moxi_specs(Config) ++ MaybeSSLProxySpec.

allowed_service({moxi, _, _, _} = _NCAO, Config) ->
    lists:member(moxi, ns_cluster_membership:node_services(Config, node()));
allowed_service(_NCAO, _Config) ->
    true.

should_run_service(Config, Service) ->
    case ns_cluster_membership:get_cluster_membership(node(), Config) =:= active  of
        false -> false;
        true ->
            Svcs = ns_cluster_membership:node_services(Config, node()),
            lists:member(Service, Svcs)
    end.

query_node_spec(Config) ->
    case should_run_service(Config, n1ql) of
        false ->
            [];
        _ ->
            RestPort = misc:node_rest_port(Config, node()),
            Command = path_config:component_path(bin, "cbq-engine"),
            DataStoreArg = "--datastore=http://127.0.0.1:" ++ integer_to_list(RestPort),
            CnfgStoreArg = "--configstore=http://127.0.0.1:" ++ integer_to_list(RestPort),
            HttpArg = "--http=:" ++ integer_to_list(ns_config:search(Config, {node, node(), query_port}, 8093)),
            Spec = {'query', Command,
                    [DataStoreArg, HttpArg, CnfgStoreArg],
                    [use_stdio, exit_status, port_server_send_eol, stderr_to_stdout, stream]},

            [Spec]
    end.

kv_node_projector_spec(Config) ->
    Svcs = ns_cluster_membership:node_services(Config, node()),
    case lists:member(kv, Svcs) of
        false ->
            [];
        _ ->
            % Projector is a component that is required by 2i
            ProjectorPort = ns_config:search(Config, {node, node(), projector_port}, 9999),
            RestPort = misc:node_rest_port(Config, node()),
            LocalMemcachedPort = ns_config:search_node_prop(node(), Config, memcached, port),
            ClusterArg = "127.0.0.1:" ++ integer_to_list(RestPort),
            KvListArg = "-kvaddrs=127.0.0.1:" ++ integer_to_list(LocalMemcachedPort),
            AdminPortArg = "-adminport=127.0.0.1:" ++ integer_to_list(ProjectorPort),
            ProjLogArg = '-debug=true',
            ProjectorCmd = path_config:component_path(bin, "projector"),

            Spec = {'projector', ProjectorCmd,
                    [ProjLogArg, KvListArg, AdminPortArg, ClusterArg],
                    [use_stdio, exit_status, stderr_to_stdout, stream]},
            [Spec]
    end.

index_node_spec(Config) ->
    Svcs = ns_cluster_membership:node_services(Config, node()),
    case lists:member(index, Svcs) of
        false ->
            [];
        _ ->
            NumVBuckets = case ns_config:search(couchbase_num_vbuckets_default) of
                              false -> misc:getenv_int("COUCHBASE_NUM_VBUCKETS", 1024);
                              {value, X} -> X
                          end,
            IndexerCmd = path_config:component_path(bin, "indexer"),
            IdxrLogArg = '-log=2',
            NumVBsArg = "-vbuckets=" ++ integer_to_list(NumVBuckets),
            ProjectorPort = ns_config:search(Config, {node, node(), projector_port}, 9999),
            ProjectorArg = "-projector=127.0.0.1:" ++ integer_to_list(ProjectorPort),

            Spec = {'indexer', IndexerCmd,
                    [NumVBsArg, ProjectorArg, IdxrLogArg],
                    [use_stdio, exit_status, stderr_to_stdout, stream]},
            [Spec]
    end.

expand_args({Name, Cmd, ArgsIn, OptsIn}) ->
    Config = ns_config:get(),
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

omit_missing_mcd_ports(Interfaces, MCDParams) ->
    ExpandedPorts = misc:rewrite(
                      fun ({port, PortName}) when is_atom(PortName) ->
                              {stop, {port, proplists:get_value(PortName, MCDParams)}};
                          (_Other) ->
                              continue
                      end, Interfaces),
    Ports = [Obj || Obj <- ExpandedPorts,
                    case Obj of
                        {PortProps} ->
                            proplists:get_value(port, PortProps) =/= undefined
                    end],
    memcached_config_mgr:expand_memcached_config(Ports, MCDParams).
