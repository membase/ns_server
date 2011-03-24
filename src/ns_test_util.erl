-module(ns_test_util).
-export([start_cluster/1, start_node/5, stop_node/1]).

start_cluster(NodeNames) ->
    {ok, Nodes} = start_cluster(NodeNames, 0, []),

    % Attempt to create a cluster out of started nodes, should redo with
    % erlang api
    _Cmd = os:cmd(code:lib_dir(ns_server) ++ "/cluster_connect -n 2"),

    {ok, Nodes}.

start_cluster([], _N, Acc) ->
    {ok, Acc};

start_cluster([Node | Nodes], N, Acc) ->

    {MemcPort, MoxiPort, RestPort, CouchPort} = gen_ports(N),

    ok = start_node(Node, MemcPort, MoxiPort, RestPort, CouchPort),
    ok = rpc:call(Node, ns_bootstrap, start, []),

    start_cluster(Nodes, N + 1, [Node | Acc]).


start_node(Name, MemcPort, MoxiPort, RestPort, CouchPort) ->

    {ok, [Paths]} = init:get_argument(pa),

    {SName, _Host} = misc:node_name_host(Name),
    LogDir = "'\"logs/" ++ SName ++ "\"'",

    filelib:ensure_dir("logs/" ++ SName ++ "/"),

    MkCouch = os:cmd(string:join(["./mkcouch.sh", SName, i2l(CouchPort)], " ")),
    io:format("mkcouch: ~p~n", [MkCouch]),

    Cmd = ["erl"
           , "-name", atom_to_list(Name)
           , "-setcookie", erlang:get_cookie()
           , "-detached "
           , "-couch_ini"
           , "lib/couchdb/etc/couchdb/default.ini"
           , "couch/" ++ SName ++ "_conf.ini"
           , "-ns_server"
           , "error_logger_mf_dir", LogDir
           , "error_logger_mf_maxbytes", 10485760
           , "error_logger_mf_maxfiles", 10
           , "dont_reset_cooke true"
           , "path_prefix", "'\"" ++ SName ++ "\"'"
           , "rest_port", RestPort
           , "memcached_port", MemcPort
           , "moxi_port ", MoxiPort
           , "-pa", string:join(Paths, " ")],

    Command = string:join([to_str(X) || X <- Cmd], " "),
    io:format("Starting erlang with:~n~s~n", [Command]),
    spawn(fun() -> os:cmd(Command) end),
    wait_for_pong(Name, 10).


stop_node(Node) ->
    rpc:call(Node, init, stop, []).


gen_ports(N) ->
    {12000 + (N * 2), 12001 + (N * 2), 9000 + N, 9500 + N}.


wait_for_pong(_Node, 0) ->
    {error, did_not_start};

wait_for_pong(Node, N) ->
    case net_adm:ping(Node) of
        pang ->
            timer:sleep(500),
            wait_for_pong(Node, N-1);
        pong ->
            ok
    end.


to_str(X) when is_list(X) ->
    X;
to_str(X) when is_integer(X) ->
    i2l(X);
to_str(X) when is_atom(X) ->
    atom_to_list(X).


i2l(X) ->
    integer_to_list(X).
