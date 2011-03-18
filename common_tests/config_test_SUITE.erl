-module(config_test_SUITE).
-include_lib("common_test/include/ct.hrl").

-compile(export_all).

suite() ->
    [].

init_per_suite(Config) ->
    file:set_cwd("../.."),
    {ok, Nodes} = ns_test_util:start_cluster(['n_0@127.0.0.1', 'n_1@127.0.0.1']),
    [{nodes, Nodes} | Config].


end_per_suite(Config) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, Config),
    [ns_test_util:stop_node(Node) || Node <- Nodes],
    ok.

init_per_testcase(_Case, Config) ->
    Config.
end_per_testcase(_Case, _Config) ->
    ok.

all() ->
    [ns_config_sanity, ns_config_async, ns_config_sync].

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

ns_config_sync(_Config) ->
    Data = erlang:now(),
    rpc:call('n_0@127.0.0.1', ns_config, set, [sync, Data]),
    {value, Data} = rpc:call('n_1@127.0.0.1', ns_config, search, [sync]).
