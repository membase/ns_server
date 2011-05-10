-module(config_test_SUITE).
-include_lib("common_test/include/ct.hrl").

-compile(export_all).

suite() ->
    [].

init_per_suite(Config) ->
    file:set_cwd(code:lib_dir(ns_server)),
    [Master | Rest] = Nodes =
        ns_test_util:gen_cluster_conf(['n_0@127.0.0.1', 'n_1@127.0.0.1']),
    ok = ns_test_util:start_cluster(Nodes),
    ok = ns_test_util:connect_cluster(Master, Rest),
    [{nodes, Nodes} | Config].


end_per_suite(Config) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, Config),
    [ns_test_util:stop_node(Node) || Node <- Nodes],
    ok = ns_test_util:clear_data(),
    ok.

init_per_testcase(_Case, Config) ->
    Config.
end_per_testcase(_Case, _Config) ->
    ok.

all() ->
    [ns_config_sanity, ns_config_async].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
ns_config_sanity(_Config) ->
    Data = erlang:now(),
    rpc:call('n_0@127.0.0.1', ns_config, set, [sanity, Data]),
    timer:sleep(1000),
    {value, Data} = rpc:call('n_0@127.0.0.1', ns_config, search, [sanity]).

ns_config_async(_Config) ->
    Data = erlang:now(),
    rpc:call('n_0@127.0.0.1', ns_config, set, [async, Data]),
    timer:sleep(1000),
    {value, Data} = rpc:call('n_1@127.0.0.1', ns_config, search, [async]).
