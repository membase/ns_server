-module(basic_test_SUITE).
-include_lib("common_test/include/ct.hrl").

-compile(export_all).

suite() ->
    [].

init_per_suite(Config) ->
    Config.
end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Config.
end_per_testcase(_Case, _Config) ->
    ok.

all() ->
    [ns_config_sanity].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

ns_config_sanity(_Config) ->
    Data = erlang:now(),
    ns_config:set(test, Data),
    [Node | Rest] = nodes(),
    {value, Data} = rpc:call(Node, ns_config, search, [test]).
