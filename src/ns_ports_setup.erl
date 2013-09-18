-module(ns_ports_setup).

-include("ns_common.hrl").

-export([start/0, start_memcached_force_killer/0, setup_body_tramp/0,
         restart_port_by_name/1, restart_moxi/0, restart_memcached/0]).

start() ->
    {ok, proc_lib:spawn_link(?MODULE, setup_body_tramp, [])}.

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
    ns_pubsub:subscribe_link(ns_config_events,
                             fun (Event) ->
                                     case is_useless_event(Event) of
                                         false ->
                                             Self ! check_childs_update;
                                         _ ->
                                             []
                                     end
                             end),
    Childs = dynamic_children(),
    set_childs_and_loop(Childs).

%% rpc:called (2.0.2+) after any bucket is deleted
restart_moxi() ->
    {ok, _} = restart_port_by_name(moxi),
    ok.

restart_memcached() ->
    {ok, _} = restart_port_by_name(memcached),
    ok.

restart_port_by_name(Name) ->
    rpc:call(ns_server:get_babysitter_node(), ns_child_ports_sup, restart_port_by_name, [Name]).

set_childs_and_loop(Childs) ->
    Pid = rpc:call(ns_server:get_babysitter_node(), ns_child_ports_sup, set_dynamic_children, [Childs]),
    {is_pid, true, Pid} = {is_pid, erlang:is_pid(Pid), Pid},
    erlang:link(Pid),
    childs_loop(Childs).

childs_loop(Childs) ->
    proc_lib:hibernate(erlang, apply, [fun childs_loop_continue/1, [Childs]]).

childs_loop_continue(Childs) ->
    receive
        check_childs_update ->
            ok;
        X ->
            erlang:error({unexpected_message, X})
    after 0 ->
            erlang:error(expected_some_message)
    end,
    %% this sets bound on frequency of checking of port_servers
    %% configuration updates. NOTE: this thing also depends on other
    %% config variables. Particularly moxi's environment variables
    %% need admin credentials. So we're forced to react on any config
    %% change
    timer:sleep(50),
    misc:flush(check_childs_update),
    case dynamic_children() of
        Childs ->
            childs_loop(Childs);
        NewChilds ->
            set_childs_and_loop(NewChilds)
    end.

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
    [expand_args(NCAO) || NCAO <- PortServers] ++ per_bucket_moxi_specs(Config).

expand_args({Name, Cmd, ArgsIn, OptsIn}) ->
    Config = ns_config:get(),
    %% Expand arguments
    Args = lists:map(fun ({Format, Keys}) ->
                             format(Config, Name, Format, Keys);
                           (X) -> X
                      end,
                      ArgsIn),
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
