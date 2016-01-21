%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
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
-module(service_janitor).

-include("ns_common.hrl").

-export([cleanup/0]).

-define(INITIAL_REBALANCE_TIMEOUT, ns_config:get_timeout(initial_rebalance, 120000)).

cleanup() ->
    Config = ns_config:get(),
    case ns_config_auth:is_system_provisioned(Config) of
        true ->
            do_cleanup(Config);
        false ->
            ok
    end.

do_cleanup(Config) ->
    maybe_init_services(Config).

maybe_init_services(Config) ->
    ActiveNodes = ns_cluster_membership:active_nodes(Config),
    case ActiveNodes of
        [Node] when Node =:= node() ->
            Services = ns_cluster_membership:node_services(Config, Node),
            RVs = [maybe_init_service(Config, S) || S <- Services],
            NotOKs = [R || R <- RVs, R =/= ok],

            case NotOKs of
                [] ->
                    ok;
                _ ->
                    failed
            end;
        _ ->
            ok
    end.

maybe_init_service(_Config, kv) ->
    ok;
maybe_init_service(Config, Service) ->
    case lists:member(Service, ns_cluster_membership:topology_aware_services()) of
        true ->
            maybe_init_topology_aware_service(Config, Service);
        false ->
            maybe_init_simple_service(Config, Service)
    end.

maybe_init_simple_service(Config, Service) ->
    case ns_cluster_membership:get_service_map(Config, Service) of
        [] ->
            ns_cluster_membership:set_service_map(Service, [node()]),
            ?log_debug("Created initial service map for service `~p'", [Service]),
            ok;
        _ ->
            ok
    end.

maybe_init_topology_aware_service(Config, Service) ->
    case ns_cluster_membership:get_service_map(Config, Service) of
        [] ->
            ?log_debug("Doing initial topology change for service `~p'", [Service]),
            case orchestrate_initial_rebalance(Service) of
                ok ->
                    ?log_debug("Initial rebalance for `~p` finished successfully",
                               [Service]),
                    ok;
                Error ->
                    ?log_error("Initial rebalance for `~p` failed: ~p",
                               [Service, Error]),
                    Error
            end;
        _ ->
            ok
    end.

orchestrate_initial_rebalance(Service) ->
    ProgressCallback =
        fun (Progress) ->
                ?log_debug("Initial rebalance progress for `~p': ~p",
                           [Service, dict:to_list(Progress)])
        end,

    KeepNodes = [node()],
    EjectNodes = [],
    DeltaNodes = [],

    {Pid, MRef} = service_rebalancer:spawn_monitor_rebalance(
                    Service, KeepNodes, EjectNodes, DeltaNodes, ProgressCallback),
    receive
        {'DOWN', MRef, _, Pid, Reason} ->
            case Reason of
                normal ->
                    ns_cluster_membership:set_service_map(Service, KeepNodes),
                    ok;
                _ ->
                    {error, {initial_rebalance_failed, Service, Reason}}
            end;
        {'EXIT', _, Reason} = Exit ->
            ?log_debug("Received exit message ~p. Terminating initial rebalance",
                       [Exit]),
            misc:terminate_and_wait(Reason, Pid),
            exit(Reason)
    after
        ?INITIAL_REBALANCE_TIMEOUT ->
            ?log_error("Initial rebalance of service `~p` takes too long (timeout ~p)",
                       [Service, ?INITIAL_REBALANCE_TIMEOUT]),
            misc:terminate_and_wait(shutdown, Pid),
            {error, {initial_rebalance_timeout, Service}}
    end.
