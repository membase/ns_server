%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(auto_failover_SUITE).

-include_lib("common_test/include/ct.hrl").

-compile(export_all).

-define(USERNAME, "Administrator").
-define(PASSWORD, "asdasd").

suite() ->
    [].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(two_nodes_cluster, Config) ->
    file:set_cwd(code:lib_dir(ns_server)),
    Nodes = ns_test_util:gen_cluster_conf(['n_0@127.0.0.1', 'n_1@127.0.0.1']),
    [{nodes, Nodes} | Config];

init_per_group(five_nodes_cluster, Config) ->
    file:set_cwd(code:lib_dir(ns_server)),
    Nodes = ns_test_util:gen_cluster_conf(['n_0@127.0.0.1', 'n_1@127.0.0.1',
                                           'n_2@127.0.0.1', 'n_3@127.0.0.1',
                                           'n_4@127.0.0.1']),
    [{nodes, Nodes} | Config];

init_per_group(six_nodes_cluster, Config) ->
    file:set_cwd(code:lib_dir(ns_server)),
    Nodes = ns_test_util:gen_cluster_conf(['n_0@127.0.0.1', 'n_1@127.0.0.1',
                                           'n_2@127.0.0.1', 'n_3@127.0.0.1',
                                           'n_4@127.0.0.1', 'n_5@127.0.0.1']),
    [{nodes, Nodes} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    file:set_cwd(code:lib_dir(ns_server)),
    {nodes, Nodes} = lists:keyfind(nodes, 1, Config),
    [Master | Rest] = Nodes,
    ok = ns_test_util:start_cluster(Nodes),
    ok = ns_test_util:connect_cluster(Master, Rest),
    ok = ns_test_util:create_bucket(Master, memcached, "default"),
    ok = ns_test_util:rebalance_node_done(hd(Nodes), 8),
    Config.

end_per_testcase(_Case, Config) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, Config),
    [ns_test_util:stop_node(Node) || Node <- Nodes],
    ok = ns_test_util:clear_data().

groups() -> [{two_nodes_cluster, [sequence],
              [auto_failover_enabled_cluster_too_small]},
             {five_nodes_cluster, [sequence],
              [auto_failover_enabled_one_node_down,
               auto_failover_disabled_one_node_down,
               auto_failover_enabled_no_node_down,
               enable_auto_failover_on_unhealthy_cluster,
               auto_failover_enabled_master_node_down]},
             {six_nodes_cluster, [sequence],
              [auto_failover_enabled_two_nodes_down,
               auto_failover_enabled_more_than_max_nodes_down,
               auto_failover_enabled_change_settings,
               auto_failover_enabled_failover_one_node_manually,
               auto_failover_enabled_master_node_down_preserve_count,
               auto_failover_enabled_reset_count
              ]}
            ].

all() ->
    [{group, two_nodes_cluster},
     {group, five_nodes_cluster},
     {group, six_nodes_cluster}
    ].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%% Tests for two nodes cluster

auto_failover_enabled_cluster_too_small(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Stop one node
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Node shouldn't be failovered, as the cluster is too small
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                      'n_1@127.0.0.1').


%% Tests for five nodes cluster

auto_failover_enabled_one_node_down(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Stop one node
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Now we wait until the auto-failover ticks in
    ok = ns_test_util:wait_for_failover(hd(Nodes), 20, 'n_1@127.0.0.1').

auto_failover_disabled_one_node_down(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Stop one node
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Node shouldn't be failovered, so we wait for the timeout after 20 seconds
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                      'n_1@127.0.0.1').

auto_failover_enabled_no_node_down(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % No node should be failovered, so we wait for the timeout after 20 seconds
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                      'n_1@127.0.0.1').

enable_auto_failover_on_unhealthy_cluster(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Stop one node
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Auto-failover can still be enabled
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % And will fallover that node
    ok = ns_test_util:wait_for_failover(hd(Nodes), 20, 'n_1@127.0.0.1').

auto_failover_enabled_master_node_down(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Make sure the ns_config was propagated to the other node
    ok = wait_for_ns_config('n_1@127.0.0.1', {auto_failover_cfg, enabled},
                            true),

    % Stop the node auto_failover is running on
    ok = ns_test_util:stop_node(lists:nth(1, Nodes)),

    % Now we wait until the auto-failover ticks in
    ok = ns_test_util:wait_for_failover(lists:nth(2, Nodes), 30,
                                        'n_0@127.0.0.1').


%% Tests for six nodes cluster

%% @doc auto-failovers a cluster where two nodes went down at the same time
auto_failover_enabled_two_nodes_down(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Stop two nodes
    ok = ns_test_util:stop_nodes(lists:sublist(Nodes, 2, 2)),

    % No node will be auto-fialovered. We only auto-failover if only *one*
    % node is down at the same time
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                      'n_1@127.0.0.1'),
    %% The timeout for the second check can be small, as we've already waited
    %% the time on the first check.
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 2,
                                                      'n_2@127.0.0.1').

auto_failover_enabled_more_than_max_nodes_down(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Stop one node
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Now we wait until the auto-failover ticks in
    ok = ns_test_util:wait_for_failover(hd(Nodes), 20, 'n_1@127.0.0.1'),

    % Stop another node
    ok = ns_test_util:stop_node(lists:nth(3, Nodes)),

    % Node shouldn't be failovered, as the maximum of nodes that should
    % get automatically be failovered is already reached
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                      'n_2@127.0.0.1'),

    % Stop another node
    ok = ns_test_util:stop_node(lists:nth(4, Nodes)),

    % Node shouldn't be failovered, as the maximum of nodes that should
    % get automatically be failovered is already reached
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                      'n_3@127.0.0.1').


%% @doc enable auto-failover, change settings while it is running
auto_failover_enabled_change_settings(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    % Only failover one node
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [50, 1]),

    % Stop two nodes
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Auto-failover shouldn't tick in within 20 seconds
    {error, timeout} =  ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                       'n_1@127.0.0.1'),

    % Decrease the timeout, so that auto-failover ticks in faster
    % to two
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Auto-failover should failover this node within 20 seconds (even faster)
    ok = ns_test_util:wait_for_failover(hd(Nodes), 20, 'n_1@127.0.0.1').

%% @doc enable auto-failover, but failover a node manually
auto_failover_enabled_failover_one_node_manually(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 15 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [15, 1]),

    % Stop two nodes
    ok = ns_test_util:stop_nodes(lists:sublist(Nodes, 2, 2)),

    % Failover one node manually and make sure that the other node wasn't
    % failovered
    ok = ns_test_util:failover_node(hd(Nodes), lists:nth(2, Nodes)),
    ok = ns_test_util:wait_for_failover(hd(Nodes), 10, 'n_1@127.0.0.1'),
    [{unhealthy, active}] = ns_test_util:nodes_status(hd(Nodes),
                                                      ['n_2@127.0.0.1']),

    % Now we wait until the auto-failover ticks in and failovers the other
    % node as well
    ok = ns_test_util:wait_for_failover(hd(Nodes), 40, 'n_2@127.0.0.1').

%% @doc enable auto-failover, bring node down where auto_failover runs on
%% and make sure no other node goes down as maximum number is reached.
%% This tests if the counter is persistent as it should.
auto_failover_enabled_master_node_down_preserve_count(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Make sure the ns_config was propagated to the other nodes
    ok = wait_for_ns_config('n_1@127.0.0.1', {auto_failover_cfg, enabled},
                            true),
    ok = wait_for_ns_config('n_2@127.0.0.1', {auto_failover_cfg, enabled},
                            true),

    % Stop the node auto_failover is running on
    ok = ns_test_util:stop_node(lists:nth(1, Nodes)),

    % Now we wait until the auto-failover ticks in
    ok = ns_test_util:wait_for_failover(lists:nth(3, Nodes), 30,
                                        'n_0@127.0.0.1'),

    % Stop another node that shouldn't be auto-failovered
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),
    {error, timeout} = ns_test_util:wait_for_failover(lists:nth(3, Nodes), 20,
                                                      'n_1@127.0.0.1').

%% @doc Tests if reset the count of auto-failovered nodes work.
auto_failover_enabled_reset_count(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Stop one node
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Now we wait until the auto-failover ticks in
    ok = ns_test_util:wait_for_failover(hd(Nodes), 20, 'n_1@127.0.0.1'),

    % Stop another node that shouldn't be auto-failovered as the maximum
    % is reached
    ok = ns_test_util:stop_node(lists:nth(3, Nodes)),
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                      'n_2@127.0.0.1'),

    % Reset the auto-failover count
    ok = rpc:call('n_0@127.0.0.1', auto_failover, reset_count, []),

    % Now the node should be auto-failovered
    ok = ns_test_util:wait_for_failover(hd(Nodes), 20, 'n_2@127.0.0.1').


%%
%% Internal functions
%%

wait_for_ns_config(Node, {Main, Sub}, Expected) ->
    Fun = fun() ->
              Config = rpc:call(Node, ns_config, get, []),
              rpc:call(Node, ns_config, search_prop, [Config, Main, Sub])
          end,
    ns_test_util:wait_for(Fun, Expected, 10).
