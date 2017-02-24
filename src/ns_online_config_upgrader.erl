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
%%

-module(ns_online_config_upgrader).

-include("ns_common.hrl").

-export([upgrade_config/1]).

upgrade_config(NewVersion) ->
    true = (NewVersion =< ?LATEST_VERSION_NUM),

    ok = ns_config:upgrade_config_explicitly(
           fun (Config) ->
                   do_upgrade_config(Config, NewVersion)
           end).

do_upgrade_config(Config, FinalVersion) ->
    case ns_config:search(Config, cluster_compat_version) of
        {value, FinalVersion} ->
            [];
        %% The following two cases don't actually correspond to upgrade from
        %% pre-2.0 clusters, we don't support those anymore. Instead, it's an
        %% upgrade from pristine ns_config_default:default(). I tried setting
        %% cluster_compat_version to the most up-to-date compat version in
        %% default config, but that uncovered issues that I'm too scared to
        %% touch at the moment.
        false ->
            [{set, cluster_compat_version, ?VERSION_30}];
        {value, undefined} ->
            [{set, cluster_compat_version, ?VERSION_30}];
        {value, ?VERSION_30} ->
            [{set, cluster_compat_version, ?VERSION_40} |
             upgrade_config_from_3_0_to_4_0(Config)];
        {value, ?VERSION_40} ->
            [{set, cluster_compat_version, ?VERSION_41} |
             upgrade_config_from_4_0_to_4_1(Config)];
        {value, ?VERSION_41} ->
            [{set, cluster_compat_version, ?VERSION_45} |
             upgrade_config_from_4_1_to_4_5(Config)];
        {value, ?VERSION_45} ->
            [{set, cluster_compat_version, ?VERSION_46}];
        {value, ?VERSION_46} ->
            [{set, cluster_compat_version, ?SPOCK_VERSION_NUM} |
             upgrade_config_from_4_6_to_spock()]
    end.

upgrade_config_from_3_0_to_4_0(Config) ->
    ?log_info("Performing online config upgrade to 4.0 version"),
    goxdcr_upgrade:config_upgrade(Config) ++
        index_settings_manager:config_upgrade_to_40().

upgrade_config_from_4_0_to_4_1(Config) ->
    ?log_info("Performing online config upgrade to 4.1 version"),
    create_service_maps(Config, [n1ql, index]).

upgrade_config_from_4_1_to_4_5(Config) ->
    ?log_info("Performing online config upgrade to 4.5 version"),
    RV = create_service_maps(Config, [fts]) ++
        menelaus_users:upgrade_to_4_5(Config),
    RV1 = index_settings_manager:config_upgrade_to_45(Config) ++ RV,
    add_index_ram_alert_limit(Config) ++ RV1.

add_index_ram_alert_limit(Config) ->
    {value, Current} = ns_config:search(Config, alert_limits),
    case proplists:get_value(max_indexer_ram, Current) of
        undefined ->
            New = Current ++ [{max_indexer_ram, 75}],
            [{set, alert_limits, New}];
        _ ->
            []
    end.

create_service_maps(Config, Services) ->
    ActiveNodes = ns_cluster_membership:active_nodes(Config),
    Maps = [{S, ns_cluster_membership:service_nodes(Config, ActiveNodes, S)} ||
                S <- Services],
    [{set, {service_map, Service}, Map} || {Service, Map} <- Maps].

upgrade_config_from_4_6_to_spock() ->
    ?log_info("Performing online config upgrade to Spock version"),
    [{set, roles_definitions, menelaus_roles:preconfigured_roles()}].
