%% @author Couchbase <info@couchbase.com>
%% @copyright 2018 Couchbase, Inc.
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
-module(leader_utils).

-include("cut.hrl").

-export([is_new_orchestration_disabled/0,
         ignore_if_new_orchestraction_disabled/1,
         live_nodes/0, live_nodes/1, live_nodes/2]).

is_new_orchestration_disabled() ->
    ns_config:read_key_fast(force_disable_new_orchestration, false).

ignore_if_new_orchestraction_disabled(Body) ->
    case is_new_orchestration_disabled() of
        true ->
            ignore;
        false ->
            Body()
    end.

live_nodes() ->
    live_nodes(ns_node_disco:nodes_wanted()).

live_nodes(WantedNodes) ->
    live_nodes(ns_config:latest(), WantedNodes).

live_nodes(Config, WantedNodes) ->
    Nodes = ns_cluster_membership:get_nodes_with_status(Config,
                                                        WantedNodes,
                                                        _ =/= inactiveFailed),
    ns_node_disco:only_live_nodes(Nodes).
