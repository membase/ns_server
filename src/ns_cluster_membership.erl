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
         start_rebalance/3,
         stop_rebalance/0,
         stop_rebalance_if_safe/0,
         is_stop_rebalance_safe/0,
         get_rebalance_status/0,
         is_balanced/0,
         get_recovery_type/2,
         update_recovery_type/2
        ]).

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

start_rebalance(KnownNodes, EjectedNodes, RequireDeltaRecovery) ->
    ns_orchestrator:start_rebalance(KnownNodes, EjectedNodes, RequireDeltaRecovery).

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

re_add_node(Node) ->
    KVList0 = [{{node, Node, membership}, inactiveAdded}],

    KVList = case cluster_compat_mode:is_cluster_30() of
                 true ->
                     [{{node, Node, recovery_type}, full} | KVList0];
                 false ->
                     KVList0
             end,

    ns_config:set(KVList).

get_recovery_type(Config, Node) ->
    ns_config:search(Config, {node, Node, recovery_type}, none).

-spec update_recovery_type(node(), delta | full) -> ok | bad_node | conflict.
update_recovery_type(Node, NewType) ->
    RV = ns_config:run_txn(
           fun (Config, Set) ->
                   Membership = ns_config:search(Config, {node, Node, membership}),
                   CurrentType = get_recovery_type(Config, Node),

                   case Membership =:= {value, inactiveAdded} andalso
                       CurrentType =/= none of

                       true ->
                           case CurrentType =:= NewType of
                               true ->
                                   {abort, not_needed};
                               false ->
                                   {commit,
                                    Set({node, Node, recovery_type}, NewType, Config)}
                           end;
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
