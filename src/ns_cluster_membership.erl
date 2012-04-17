%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
-module(ns_cluster_membership).

-export([active_nodes/0,
         active_nodes/1,
         actual_active_nodes/0,
         get_nodes_cluster_membership/0,
         get_nodes_cluster_membership/1,
         get_cluster_membership/1,
         get_cluster_membership/2,
         activate/1,
         deactivate/1,
         failover/1,
         re_add_node/1,
         system_joinable/0,
         start_rebalance/2,
         stop_rebalance/0,
         is_stop_rebalance_safe/0,
         get_rebalance_status/0,
         is_balanced/0
        ]).

-export([ns_log_cat/1,
         ns_log_code_string/1]).

%% category critical
-define(UNUSED_MISSING_COOKIE, 0).
-define(UNUSED_MISSING_OTP_NODE, 1).
-define(UNUSED_CONNREFUSED, 2).
-define(UNUSED_NXDOMAIN, 3).
-define(UNUSED_TIMEDOUT, 4).
-define(UNUSED_REST_ERROR, 5).
-define(UNUSED_OTHER_ERROR, 6).
-define(UNUSED_REST_FAILED, 7).
%% category warn
-define(UNUSED_PREPARE_JOIN_FAILED, 32).
-define(UNUSED_AUTH_FAILED, 33).
%% categeory info. Starts from 256 - 32
-define(UNUSED_JOINED_CLUSTER, 224).

active_nodes() ->
    active_nodes(ns_config:get()).

active_nodes(Config) ->
    [Node || Node <- ns_node_disco:nodes_wanted(),
             get_cluster_membership(Node, Config) == active].

actual_active_nodes() ->
    Config = ns_config:get(),
    [Node || Node <- ns_node_disco:nodes_actual(),
             get_cluster_membership(Node, Config) == active].

get_nodes_cluster_membership() ->
    get_nodes_cluster_membership(ns_node_disco:nodes_wanted()).

get_nodes_cluster_membership(Nodes) ->
    Config = ns_config:get(),
    [{Node, get_cluster_membership(Node, Config)} || Node <- Nodes].

get_cluster_membership(Node) ->
    get_cluster_membership(Node, ns_config:get()).

get_cluster_membership(Node, Config) ->
    case ns_config:search(Config, {node, Node, membership}) of
        {value, Value} ->
             Value;
        _ ->
            inactiveAdded
    end.

system_joinable() ->
    ns_node_disco:nodes_wanted() =:= [node()].

get_rebalance_status() ->
    ns_orchestrator:rebalance_progress().

start_rebalance(KnownNodes, KnownNodes) ->
    no_active_nodes_left;
start_rebalance(KnownNodes, EjectedNodes) ->
    case {EjectedNodes -- KnownNodes,
          lists:sort(ns_node_disco:nodes_wanted()),
          lists:sort(KnownNodes)} of
        {[], X, X} ->
            MaybeKeepNodes = KnownNodes -- EjectedNodes,
            FailedNodes =
                [N || {N, State} <-
                          get_nodes_cluster_membership(KnownNodes),
                      State == inactiveFailed],
            KeepNodes = MaybeKeepNodes -- FailedNodes,
            activate(KeepNodes),
            ns_orchestrator:start_rebalance(KeepNodes, EjectedNodes -- FailedNodes,
                                            FailedNodes);
        _ -> nodes_mismatch
    end.

activate(Nodes) ->
    ns_config:set([{{node, Node, membership}, active} ||
                      Node <- Nodes]).

deactivate(Nodes) ->
    %% TODO: we should have a way to delete keys
    ns_config:set([{{node, Node, membership}, inactiveAdded}
                   || Node <- Nodes]).

is_stop_rebalance_safe() ->
    case ns_config:search(rebalancer_pid) of
        false ->
            true;
        {value, undefined} ->
            true;
        {value, Pid} ->
            PidNode = node(Pid),
            MasterNode = mb_master:master_node(),
            PidNode =:= MasterNode
    end.

stop_rebalance() ->
    ns_orchestrator:stop_rebalance().

is_balanced() ->
    not ns_orchestrator:needs_rebalance().

failover(Node) ->
    ok = ns_orchestrator:failover(Node).

re_add_node(Node) ->
    ns_config:set({node, Node, membership}, inactiveAdded).

ns_log_cat(Number) ->
    case (Number rem 256) div 32 of
        0 -> crit;
        1 -> warn;
        _ -> info
    end.

ns_log_code_string(_) ->
    "message".
