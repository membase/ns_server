-module(ns_test_util).
-export([start_cluster/1, connect_cluster/2, stop_node/1, gen_cluster_conf/1]).

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
    io:format("~p~n~n~p~n", [InitCmd, os:cmd(InitCmd)]),

    [begin
         Cmd = fmt("~s/../install/bin/membase server-add -c~s:~p "
                   "--server-add=~s:~p -u ~s -p ~s",
                   [Root, MHost, MPort, CHost, CPort, User, Pass]),
         io:format("~p~n~n~p~n", [Cmd, os:cmd(Cmd)])
     end || #node{host=CHost, rest_port=CPort} <- Nodes],
    ok.


%% @doc Given a configuration start a node with that config
-spec start_node(#node{}) -> ok.
start_node(Conf) ->
    Cmd = fmt("~s/cluster_run_wrapper --dont-start --dont-rename --static-cookie "
              "--start-index=~p", [code:lib_dir(ns_server), Conf#node.x]),
    io:format("Starting erlang with: ~p~n", [Cmd]),
    spawn_dev_null(Cmd),
    wait_for_resp(Conf#node.nodename, pong, 10).

%% @doc Stop a node
-spec stop_node(#node{}) -> ok.
stop_node(Node) ->
    rpc:call(Node#node.nodename, init, stop, []),
    wait_for_resp(Node#node.nodename, pang, 20).


%% @doc Wait for a node to become alive by pinging it in a poll
-spec wait_for_resp(atom(), any(), integer()) -> ok | {error, did_not_start}.
wait_for_resp(_Node, _Resp, 0) ->
    {error, did_not_start};

wait_for_resp(Node, Resp, N) ->
    case net_adm:ping(Node) of
        Resp ->
            ok;
        _Else ->
            timer:sleep(500),
            wait_for_resp(Node, Resp, N-1)
    end.


%% @doc run a shell command and flush all of its output
spawn_dev_null(Cmd) ->
    Flush = fun(F) -> receive _ -> F(F) end end,
    spawn(fun() ->
                  open_port({spawn, Cmd}, []),
                  Flush(Flush)
          end).


fmt(Str, Args) ->
    lists:flatten(io_lib:format(Str, Args)).
