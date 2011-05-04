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

init_per_group(three_nodes_cluster, Config) ->
    file:set_cwd(code:lib_dir(ns_server)),
    Nodes = ns_test_util:gen_cluster_conf(['n_0@127.0.0.1', 'n_1@127.0.0.1',
                                           'n_2@127.0.0.1']),
    [{nodes, Nodes} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    file:set_cwd(code:lib_dir(ns_server)),
    {nodes, Nodes} = lists:keyfind(nodes, 1, Config),
    [Master | Rest] = Nodes,
    ok = ns_test_util:start_cluster(Nodes),
    ok = ns_test_util:connect_cluster(Master, Rest),
    ok = ns_test_util:rebalance_node_done(hd(Nodes), 8),
    Config.

end_per_testcase(_Case, Config) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, Config),
    [ns_test_util:stop_node(Node) || Node <- Nodes],
    ok = ns_test_util:clear_data().

groups() -> [{two_nodes_cluster, [sequence],
              [auto_failover_enabled_one_node_down,
               auto_failover_disabled_one_node_down,
               auto_failover_enabled_no_node_down,
               enable_auto_failover_on_unhealthy_cluster]},
             {three_nodes_cluster, [sequence],
              [auto_failover_enabled_two_nodes_down,
               auto_failover_enabled_more_than_max_nodes_down,
               auto_failover_enabled_more_than_max_nodes_down_at_same_time,
               auto_failover_enabled_change_settings,
               auto_failover_enabled_failover_one_node_manually
              ]}
            ].

all() ->
    [{group, two_nodes_cluster},
     {group, three_nodes_cluster}
    ].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%% Tests for two nodes cluster

auto_failover_enabled_one_node_down(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Stop one node
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Now we wait until the auto-failover ticks in
    ok = ns_test_util:wait_for_failover(hd(Nodes), 10, 'n_1@127.0.0.1').

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

    % Try to enable auto-failover
    {error, unhealthy} = rpc:call('n_0@127.0.0.1', auto_failover, enable,
                                  [5, 1]).


%% Tests for three nodes cluster

%% @doc auto-failovers a cluster where two nodes went down at the same time
auto_failover_enabled_two_nodes_down(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 2]),

    % Stop two nodes
    ok = ns_test_util:stop_nodes(lists:sublist(Nodes, 2, 2)),

    % Both nodes should be failovered now
    ok = ns_test_util:wait_for_failover(hd(Nodes), 20, 'n_1@127.0.0.1'),
    % The timeout for the second check can be small, as we've already waited
    % the time on the first check.
    ok = ns_test_util:wait_for_failover(hd(Nodes), 2, 'n_2@127.0.0.1').

auto_failover_enabled_more_than_max_nodes_down(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Stop one node
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Now we wait until the auto-failover ticks in
    ok = ns_test_util:wait_for_failover(hd(Nodes), 10, 'n_1@127.0.0.1'),

    % Stop another node
    ok = ns_test_util:stop_node(lists:nth(3, Nodes)),

    % Node shouldn't be failovered, as the maximum of nodes that should
    % get automatically be failovered is already reached
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                      'n_2@127.0.0.1').

%% @doc simulation of a net split when may nodes go down at the same time
auto_failover_enabled_more_than_max_nodes_down_at_same_time(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Stop two nodes
    ok = ns_test_util:stop_nodes(lists:sublist(Nodes, 2, 2)),

    % No node should have been auto-failovered as too many nodes (2) went
    % down at the same time
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 20,
                                                      'n_1@127.0.0.1'),
    % The timeout for the second check can be small, as we've already waited
    % the time on the first check.
    {error, timeout} = ns_test_util:wait_for_failover(hd(Nodes), 2,
                                                      'n_2@127.0.0.1').

%% @doc enable auto-failover, change settings while it is running
auto_failover_enabled_change_settings(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 5 seconds)
    % Only failover one node
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 1]),

    % Stop two nodes
    ok = ns_test_util:stop_node(lists:nth(2, Nodes)),

    % Now we wait until the auto-failover ticks in
    ok = ns_test_util:wait_for_failover(hd(Nodes), 10, 'n_1@127.0.0.1'),

    % Increase the number of nodes that might be automatically failovered
    % to two
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [5, 2]),

    % Stop another node
    ok = ns_test_util:stop_node(lists:nth(3, Nodes)),

    % Auto-failover should failover this node
    ok = ns_test_util:wait_for_failover(hd(Nodes), 10, 'n_2@127.0.0.1').

%% @doc enable auto-failover, but failover a node manually
auto_failover_enabled_failover_one_node_manually(TestConfig) ->
    {nodes, Nodes} = lists:keyfind(nodes, 1, TestConfig),

    % Enable auto-failover (when a node is down longer than 15 seconds)
    ok = rpc:call('n_0@127.0.0.1', auto_failover, enable, [15, 3]),

    % Stop two nodes
    ok = ns_test_util:stop_nodes(lists:sublist(Nodes, 2, 2)),

    % Failover one node manually and make sure that the other node wasn't
    % failoverd
    ok = ns_test_util:failover_node(hd(Nodes), lists:nth(2, Nodes)),
    ok = ns_test_util:wait_for_failover(hd(Nodes), 10, 'n_1@127.0.0.1'),
    [{unhealthy, active}] = ns_test_util:nodes_status(hd(Nodes),
                                                      ['n_2@127.0.0.1']),

    % Now we wait until the auto-failover ticks in and failovers the other
    % node as well
    ok = ns_test_util:wait_for_failover(hd(Nodes), 40, 'n_2@127.0.0.1').
