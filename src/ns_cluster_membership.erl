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
         actual_active_nodes/1,
         get_nodes_cluster_membership/0,
         get_nodes_cluster_membership/1,
         get_cluster_membership/1,
         get_cluster_membership/2,
         activate/1,
         deactivate/1,
         failover/1,
         re_failover/1,
         system_joinable/0,
         start_rebalance/3,
         stop_rebalance/0,
         stop_rebalance_if_safe/0,
         is_stop_rebalance_safe/0,
         get_rebalance_status/0,
         is_balanced/0,
         get_recovery_type/2,
         update_recovery_type/2
        ]).

-export([supported_services/0,
         default_services/0,
         node_services/2,
         node_services_with_rev/2,
         filter_out_non_kv_nodes/1,
         filter_out_non_kv_nodes/2]).

active_nodes() ->
    active_nodes(ns_config:get()).

active_nodes(Config) ->
    [Node || Node <- ns_node_disco:nodes_wanted(),
             get_cluster_membership(Node, Config) == active].

actual_active_nodes() ->
    actual_active_nodes(ns_config:get()).

actual_active_nodes(Config) ->
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

start_rebalance(KnownNodes, EjectedNodes, DeltaRecoveryBuckets) ->
    ns_orchestrator:start_rebalance(KnownNodes, EjectedNodes, DeltaRecoveryBuckets).

activate(Nodes) ->
    ns_config:set([{{node, Node, membership}, active} ||
                      Node <- Nodes]).

deactivate(Nodes) ->
    ns_config:set([{{node, Node, membership}, inactiveFailed}
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

stop_rebalance_if_safe() ->
    %% NOTE: this is inherently raceful. But race is tiny and largely
    %% harmless. So we KISS instead.
    case is_stop_rebalance_safe() of
        false ->
            unsafe;
        _ ->
            stop_rebalance()
    end.

is_balanced() ->
    not ns_orchestrator:needs_rebalance().

failover(Node) ->
    ns_orchestrator:failover(Node).

re_failover_possible(NodeString) ->
    case (catch list_to_existing_atom(NodeString)) of
        Node when is_atom(Node) ->
            RecoveryType = ns_config:search('latest-config-marker', {node, Node, recovery_type}, none),
            Membership = ns_config:search('latest-config-marker', {node, Node, membership}),
            Ok = (lists:member(Node, ns_node_disco:nodes_wanted())
                  andalso RecoveryType =/= none
                  andalso Membership =:= {value, inactiveAdded}),
            case Ok of
                true ->
                    {ok, Node};
                _ ->
                    not_possible
            end;
        _ ->
            not_possible
    end.

%% moves node from pending-recovery state to failed over state
%% used when users hits Cancel for pending-recovery node on UI
re_failover(NodeString) ->
    true = is_list(NodeString),
    case re_failover_possible(NodeString) of
        {ok, Node} ->
            KVList0 = [{{node, Node, membership}, inactiveFailed}],

            KVList = case cluster_compat_mode:is_cluster_30() of
                         true ->
                             [{{node, Node, recovery_type}, none} | KVList0];
                         false ->
                             KVList0
                     end,

            ns_config:set(KVList),
            ok;
        not_possible ->
            not_possible
    end.

get_recovery_type(Config, Node) ->
    ns_config:search(Config, {node, Node, recovery_type}, none).

-spec update_recovery_type(node(), delta | full) -> ok | bad_node | conflict.
update_recovery_type(Node, NewType) ->
    RV = ns_config:run_txn(
           fun (Config, Set) ->
                   Membership = ns_config:search(Config, {node, Node, membership}),

                   case ((Membership =:= {value, inactiveAdded}
                          andalso get_recovery_type(Config, Node) =/= none)
                         orelse Membership =:= {value, inactiveFailed}) of

                       true ->
                           Config1 = Set({node, Node, membership}, inactiveAdded, Config),
                           {commit,
                            Set({node, Node, recovery_type}, NewType, Config1)};
                       false ->
                           {abort, {error, bad_node}}
                   end
           end),

    case RV of
        {commit, _} ->
            ok;
        {abort, not_needed} ->
            ok;
        {abort, {error, Error}} ->
            Error;
        retry_needed ->
            erlang:error(exceeded_retries)
    end.

supported_services() ->
    [kv, moxi, n1ql, index].

default_services() ->
    [kv, moxi].

node_services(Config, Node) ->
    case ns_config:search(Config, {node, Node, services}) of
        false ->
            default_services();
        {value, Value} ->
            Value
    end.

node_services_with_rev(Config, Node) ->
    case ns_config:search_with_vclock(Config, {node, Node, services}) of
        false ->
            {default_services(), 0};
        {value, Value, VClock} ->
            {Value, vclock:count_changes(VClock)}
    end.

filter_out_non_kv_nodes(Nodes) ->
    filter_out_non_kv_nodes(Nodes, ns_config:latest_config_marker()).

filter_out_non_kv_nodes(Nodes, Config) ->
    [N || N <- Nodes,
          kv <- ns_cluster_membership:node_services(Config, N)].
