%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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

-module(cluster_compat_mode).

-include("ns_common.hrl").

-export([get_compat_version/0, is_enabled/1, is_enabled_at/2,
         is_cluster_20/0,
         force_compat_version/1, un_force_compat_version/0,
         consider_switching_compat_mode/0,
         is_index_aware_rebalance_on/0,
         is_index_pausing_on/0,
         rebalance_ignore_view_compactions/0,
         check_is_progress_tracking_supported/0]).

%% NOTE: this is rpc:call-ed by mb_master
-export([supported_compat_version/0, mb_master_advertised_version/0]).

-export([pre_force_compat_version/0, post_force_compat_version/0]).


get_compat_version() ->
    ns_config_ets_dup:unreliable_read_key(cluster_compat_version, undefined).

%% NOTE: this is rpc:call-ed by mb_master of 2.0.0
supported_compat_version() ->
    [2, 0].

%% NOTE: this is rpc:call-ed by mb_master of 2.0.1+
%%
%% I.e. we want later version to be able to take over mastership even
%% without requiring compat mode upgrade
mb_master_advertised_version() ->
    [2, 2, 0].

%% TODO: in 2.1 reimplement as compat_version 2.1 to make things
%% simpler. For 2.0.2 I don't want to prevent rolling downgrades yet.
check_is_progress_tracking_supported() ->
    is_cluster_20() andalso
        case rpc:multicall(ns_node_disco:nodes_wanted(), cluster_compat_mode, mb_master_advertised_version, [], 30000) of
            {Replies, []} ->
                [R || R <- Replies,
                      R < [2, 0, 2]] =:= [];
            _ ->
                false
        end.

is_enabled_at(undefined = _ClusterVersion, _FeatureVersion) ->
    false;
is_enabled_at(ClusterVersion, FeatureVersion) ->
    ClusterVersion >= FeatureVersion.

is_enabled(FeatureVersion) ->
    is_enabled_at(get_compat_version(), FeatureVersion).

is_cluster_20() ->
    is_enabled([2, 0]).

is_index_aware_rebalance_on() ->
    Disabled = ns_config_ets_dup:unreliable_read_key(index_aware_rebalance_disabled, false),
    (not Disabled) andalso is_enabled([2, 0]).

is_index_pausing_on() ->
    is_index_aware_rebalance_on() andalso
        (not ns_config_ets_dup:unreliable_read_key(index_pausing_disabled, false)).

rebalance_ignore_view_compactions() ->
    ns_config_ets_dup:unreliable_read_key(rebalance_ignore_view_compactions, false).

consider_switching_compat_mode() ->
    Config = ns_config:get(),
    CurrentVersion = ns_config:search(Config, cluster_compat_version, undefined),
    case CurrentVersion =:= supported_compat_version() of
        true ->
            ok;
        false ->
            case ns_config:search(Config, forced_cluster_compat_version, false) of
                true ->
                    ok;
                false ->
                    do_consider_switching_compat_mode(Config, CurrentVersion)
            end
    end.

do_consider_switching_compat_mode(Config, CurrentVersion) ->
    NodesWanted = lists:sort(ns_config:search(Config, nodes_wanted, undefined)),
    NodesUp = lists:sort([node() | nodes()]),
    case ordsets:is_subset(NodesWanted, NodesUp) of
        true ->
            NodeInfos = ns_doctor:get_nodes(),
            case consider_switching_compat_mode_loop(NodeInfos, NodesWanted, supported_compat_version()) of
                CurrentVersion ->
                    ok;
                AnotherVersion ->
                    ns_config:set(cluster_compat_version, AnotherVersion),
                    try
                        %% NOTE: this sync through ns_config_events
                        %% also ensures that ns_config_ets_dup sees new value
                        ns_config:sync_announcements(),
                        case ns_config_rep:synchronize_remote(NodesWanted) of
                            ok -> ok;
                            {error, BadNodes} ->
                                ale:error(?USER_LOGGER, "Was unable to sync cluster_compat_version update to some nodes: ~p", [BadNodes]),
                                ok
                        end
                    catch T:E ->
                            ale:error(?USER_LOGGER, "Got problems trying to replicate cluster_compat_version update~n~p", [{T,E,erlang:get_stacktrace()}])
                    end,
                    changed
            end;
        false ->
            ok
    end.

consider_switching_compat_mode_loop(_NodeInfos, _NodesWanted, _Version = undefined) ->
    undefined;
consider_switching_compat_mode_loop(_NodeInfos, [], Version) ->
    Version;
consider_switching_compat_mode_loop(NodeInfos, [Node | RestNodesWanted], Version) ->
    case dict:find(Node, NodeInfos) of
        {ok, Info} ->
            NodeVersion = proplists:get_value(supported_compat_version, Info, undefined),
            AgreedVersion = case is_enabled_at(NodeVersion, Version) of
                                true ->
                                    Version;
                                false ->
                                    NodeVersion
                            end,
            consider_switching_compat_mode_loop(NodeInfos, RestNodesWanted, AgreedVersion);
        _ ->
            undefined
    end.

force_compat_version(ClusterVersion) ->
    RV0 = rpc:multicall([node() | nodes()], supervisor, terminate_child, [ns_server_sup, mb_master], 15000),
    ale:warn(?USER_LOGGER, "force_compat_version: termination of mb_master results: ~p", [RV0]),
    RV1 = rpc:multicall([node() | nodes()], cluster_compat_mode, pre_force_compat_version, [], 15000),
    ale:warn(?USER_LOGGER, "force_compat_version: pre_force_compat_version results: ~p", [RV1]),
    try
        ns_config:set(cluster_compat_version, ClusterVersion),
        ns_config:set(forced_cluster_compat_version, true),
        ns_config:sync_announcements(),
        ok = ns_config_rep:synchronize_remote(ns_node_disco:nodes_wanted())
    after
        RV2 = (catch rpc:multicall([node() | nodes()], supervisor, restart_child, [ns_server_sup, mb_master], 15000)),
        (catch ale:warn(?USER_LOGGER, "force_compat_version: restart of mb_master results: ~p", [RV2])),
        RV3 = (catch rpc:multicall([node() | nodes()], cluster_compat_mode, post_force_compat_version, [], 15000)),
        (catch ale:warn(?USER_LOGGER, "force_compat_version: post_force_compat_version results: ~p", [RV3]))
    end.

un_force_compat_version() ->
    ns_config:set(forced_cluster_compat_version, false).

pre_force_compat_version() ->
    ok.

post_force_compat_version() ->
    Names = [atom_to_list(Name) || Name <- registered()],
    [erlang:exit(whereis(list_to_atom(Name)), diepls)
     || ("ns_memcached-" ++ _) = Name <- Names],
    ok.
