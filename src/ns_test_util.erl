-module(ns_test_util).
-export([start_cluster/1, connect_cluster/2, stop_node/1, gen_cluster_conf/1,
         rebalance_node/1, rebalance_node_done/2, nodes_status/2, wait_for/3,
         create_bucket/3, clear_data/0, stop_nodes/1, failover_node/2,
         wait_for_failover/3]).

-define(USERNAME, "Administrator").
-define(PASSWORD, "asdasd").

%% Configuration record for a node
-record(node, {
          x = 0,
          host = "127.0.0.1",
          nodename = 'node@127.0.0.1',
          username = ?USERNAME,
          password = ?PASSWORD,
          moxi_port = 12000,
          memcached_port = 12001,
          rest_port = 9000,
          couch_port = 9500,
          bucket_opts = [{num_replicas,0},
                         {auth_type,sasl},
                         {sasl_password,[]},
                         {ram_quota,268435456}]
         }).

%% @doc Status of a server (node)
-record(server_status, {
          nodename :: atom(),
          host :: string(),
          port :: integer(),
          status :: healthy|unhealthy,
          membership :: active|inactiveFailed|inactiveAdded
         }).

%% @doc Helper function to generate a set of configuration for nodes in cluster
-spec gen_cluster_conf([atom()]) -> [#node{}].
gen_cluster_conf(NodeNames) ->
    F = fun(NodeName, {N, NodeList}) ->
                Node = #node{
                  x = N,
                  nodename = NodeName,
                  moxi_port = 12001 + (N * 2),
                  memcached_port = 12000 + (N * 2),
                  rest_port = 9000 + N,
                  couch_port = 9500 + N
                 },
                {N + 1, [Node | NodeList]}
        end,
    {_N, Nodes} = lists:foldl(F, {0, []}, NodeNames),
    lists:reverse(Nodes).

%% @doc Clear any existing data for a cluster before starting
-spec clear_data() -> ok.
clear_data() ->
    misc:rm_rf(filename:join([code:lib_dir(ns_server), "data"])),
    ok.

%% @doc Start a set of nodes and initialise ns_server on them
-spec start_cluster([#node{}]) -> ok.
start_cluster(Nodes) ->
    [ok = start_node(Node) || Node <- Nodes],
    [ok = rpc:call(Node#node.nodename, ns_bootstrap, start, []) || Node <- Nodes],
    ok.


%% @doc Initalise a Master node and connects a set of nodes to it
-spec connect_cluster(#node{}, [#node{}]) -> ok.
connect_cluster(#node{host=MHost, rest_port=MPort, username=User, password=Pass}, Nodes) ->

    Root = code:lib_dir(ns_server),
    InitCmd = fmt("~s/../install/bin/membase cluster-init -c~s:~p "
                  "--cluster-init-username=~s --cluster-init-password=~s",
                  [Root, MHost, MPort, User, Pass]),
    io:format(user, "~p~n~n~p~n", [InitCmd, os:cmd(InitCmd)]),

    [begin
         Cmd = fmt("~s/../install/bin/membase server-add -c~s:~p "
                   "--server-add=~s:~p -u ~s -p ~s",
                   [Root, MHost, MPort, CHost, CPort, User, Pass]),
         io:format(user, "~p~n~n~p~n", [Cmd, os:cmd(Cmd)])
     end || #node{host=CHost, rest_port=CPort} <- Nodes],
    ok.


%% @doc Given a configuration start a node with that config
-spec start_node(#node{}) -> ok.
start_node(Conf) ->
    Cmd = fmt("~s/scripts/cluster_run_wrapper --dont-start --host=127.0.0.1 --static-cookie "
              "--start-index=~p", [code:lib_dir(ns_server), Conf#node.x]),
    io:format(user, "Starting erlang with: ~p~n", [Cmd]),
    spawn_dev_null(Cmd),
    wait_for_resp(Conf#node.nodename, pong, 5).


%% @doc Stop a node
-spec stop_node(Node::#node{}) -> ok|{error, timeout}.
stop_node(Node) ->
    rpc:call(Node#node.nodename, init, stop, []),
    wait_for_resp(Node#node.nodename, pang, 20).

%% @doc Stop multiple nodes at the same time
-spec stop_nodes(Nodes::[#node{}]) -> ok|{error, timeout}.
stop_nodes(Nodes) ->
    %lists:foreach(fun(#node{nodeNameNode) ->
    NodeNames = [Node#node.nodename || Node <- Nodes],
    [rpc:call(NodeName, init, stop, []) || NodeName <- NodeNames],
    wait_for_resp_multi(NodeNames, pang, 20).

%% @doc Returns the status of all nodes of a cluster.
-spec nodes_status(Master::#node{}) ->
                      [{healthy|unhealthy|warmup,
                        active|inactiveFailed|inactiveAdded}].
nodes_status(Master) ->
    ServerList = server_list(Master),
    [{Server#server_status.status,
      Server#server_status.membership} || Server <- ServerList].
%% @doc Returns the status of the given nodes. The result list has the same
%% order as the input list.
-spec nodes_status(Master::#node{}, Nodes::[atom()]) ->
                      [{healthy|unhealthy,
                        active|inactiveFailed|inactiveAdded}].
nodes_status(Master, Nodes) ->
    ServerList = server_list(Master),
    lists:map(fun(Node) ->
                  Status = lists:keyfind(Node, #server_status.nodename,
                                         ServerList),
                  {Status#server_status.status,
                   Status#server_status.membership}
              end, Nodes).

%% @doc Returns the a list of servers as records with the information about
%% the status of the node.
-spec server_list(#node{}) -> [#server_status{}].
server_list(#node{host=Host, rest_port=Port, username=User, password=Pass}) ->
    Root = code:lib_dir(ns_server),
    Cmd = fmt("~s/../install/bin/membase server-list -c~s:~p "
                  "-u ~s -p ~s",
                  [Root, Host, Port, User, Pass]),
    ServerList = os:cmd(Cmd),
    io:format(user, "~p~n~n~p~n", [Cmd, ServerList]),
    lists:map(fun(Server) ->
                  Tokens = string:tokens(Server, " :"),
                  #server_status{
                   nodename=list_to_atom(lists:nth(1, Tokens)),
                   host=lists:nth(2, Tokens),
                   port=list_to_integer(lists:nth(3, Tokens)),
                   status=list_to_atom(lists:nth(4, Tokens)),
                   membership=list_to_atom(lists:nth(5, Tokens))
                  }
              end, string:tokens(ServerList, "\n")).


%% @doc Create a bucket on specified node
-spec create_bucket(#node{}, atom(), string()) -> ok.
create_bucket(Node, Type, Name) ->
    rpc:call(Node#node.nodename, ns_orchestrator, create_bucket,
             [Type, Name, Node#node.bucket_opts]),
    ok.


%% @doc Rebalances the given node and returns immediately
-spec rebalance_node(Node::#node{}) -> ok.
rebalance_node(#node{host=Host, rest_port=Port, username=User,
                     password=Pass}) ->
    Root = code:lib_dir(ns_server),
    Cmd = fmt("~s/../install/bin/membase rebalance -c~s:~p "
                  "-u ~s -p ~s",
                  [Root, Host, Port, User, Pass]),
    io:format(user, "~p~n~n~p~n", [Cmd, os:cmd(Cmd)]).

%% @doc Rebalances the given node and returns when the rebalancing is done
%% and all nodes are healthy. `Time` is the number of seconds it should keep
%% trying.
-spec rebalance_node_done(Node::#node{}, Time::integer()) -> ok.
rebalance_node_done(Node, Time) ->
    rebalance_node(Node),
    ok = wait_for_balanced(Node, Time),
    % Getting to full health shouldn't take long
    ok = wait_for_health(Node, 8).

%% @doc Returns the rebalancing status of the given node
-spec rebalance_node_status(Node::#node{}) -> string().
rebalance_node_status(#node{host=Host, rest_port=Port, username=User,
                            password=Pass}) ->
    Root = code:lib_dir(ns_server),
    Cmd = fmt("~s/../install/bin/membase rebalance-status -c~s:~p "
                  "-u ~s -p ~s",
                  [Root, Host, Port, User, Pass]),
    Status = os:cmd(Cmd),
    io:format(user, "~p~n~n~p~n", [Cmd, Status]),
    Status.

%% @doc Failovers a node and returns when it is done
%% `Master` is the master node of the cluster
%% `Node` is the node that should be failovered
-spec failover_node(Master::#node{}, Node::#node{}) -> ok.
failover_node(#node{host=MHost, rest_port=MPort, username=User,
                    password=Pass}=Master,
              #node{host=CHost, rest_port=CPort, nodename=CName}) ->
    Root = code:lib_dir(ns_server),
    Cmd = fmt("~s/../install/bin/membase failover -c~s:~p "
                  "--server-failover=~s:~p -u ~s -p ~s ",
                  [Root, MHost, MPort, CHost, CPort, User, Pass]),
    io:format(user, "~p~n~n~p~n", [Cmd, os:cmd(Cmd)]),
    ok = wait_for_failover(Master, 5, CName).

%% @doc Executes Fun until a certain criteria (Expected) is reached. Returns
%% with an error if it happens within the give amount of Time (in seconds)
wait_for(_Fun, _Expected, 0) ->
    {error, timeout};
wait_for(Fun, Expected, Time) ->
    case Fun() of
        Expected ->
            ok;
        _Else ->
            timer:sleep(1000),
            wait_for(Fun, Expected, Time-1)
    end.

%% @doc Wait for a cluster to finish rebalancing by pinging it in a poll
%% `Time` is the number of seconds it should keep trying
-spec wait_for_balanced(Node::#node{}, Time::integer()) ->
                           ok | {error, timeout}.
wait_for_balanced(Node, Time) ->
    Fun = fun() -> rebalance_node_status(Node) end,
    wait_for(Fun, "(u'none', None)\n", Time).

%% @doc Wait for a node to become alive by pinging it in a poll
-spec wait_for_resp(atom(), any(), integer()) -> ok | {error, timeout}.
wait_for_resp(Node, Resp, Time) ->
    Fun = fun() -> net_adm:ping(Node) end,
    wait_for(Fun, Resp, Time).

%% @doc Wait for multiple nodes to become alive/dead by pinging it in a poll
-spec wait_for_resp_multi([atom()], any(), integer()) -> ok | {error, timeout}.
wait_for_resp_multi(Nodes, Resp, Time) ->
    Fun = fun() ->
              Pings = [net_adm:ping(Node) || Node <- Nodes],
              lists:all(fun(Elem) -> Elem =:= Resp end, Pings)
          end,
    wait_for(Fun, true, Time).

%% @doc Wait for a cluster to be completely healthy (all nodes).
%% `Time` is the number of seconds it should keep trying
wait_for_health(Node, Time) ->
    Fun = fun() ->
              {Health, _Membership} = lists:unzip(nodes_status(Node)),
              lists:all(fun(Elem) -> Elem =:= healthy end, Health)
          end,
    wait_for(Fun, true, Time).

%% @doc Wait for a node to complete the fail over.
%% `Time` is the number of seconds it should keep trying
%% `Node` is the node you want to check if it was failovered
-spec wait_for_failover(Master::#node{}, Time::integer(), Node::atom()) ->
                           ok|{error, timeout}.
wait_for_failover(Master, Time, Node) ->
    Fun = fun() ->
              [Status] = nodes_status(Master, [Node]),
              Status
          end,
    wait_for(Fun, {unhealthy, inactiveFailed}, Time).

%% @doc run a shell command and flush all of its output
spawn_dev_null(Cmd) ->
    Flush = fun(F) -> receive _ -> F(F) end end,
    spawn(fun() ->
                  open_port({spawn, Cmd}, []),
                  Flush(Flush)
          end).


fmt(Str, Args) ->
    lists:flatten(io_lib:format(Str, Args)).
