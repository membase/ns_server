%% @author Couchbase <info@couchbase.com>
%% @copyright 2012-2018 Couchbase, Inc.
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

-include("cut.hrl").
-include("ns_common.hrl").

-export([upgrade_config/1]).

upgrade_config(NewVersion) ->
    true = (NewVersion =< ?LATEST_VERSION_NUM),

    ok = ns_config:upgrade_config_explicitly(
           do_upgrade_config(_, NewVersion)).

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
            upgrade_compat_version(?VERSION_40);
        {value, undefined} ->
            upgrade_compat_version(?VERSION_40);
        {value, Ver} ->
            {NewVersion, Upgrade} = upgrade(Ver, Config),
            ?log_info("Performing online config upgrade to ~p", [NewVersion]),
            upgrade_compat_version(NewVersion) ++
                maybe_final_upgrade(NewVersion) ++ Upgrade
    end.

upgrade_compat_version(NewVersion) ->
    [{set, cluster_compat_version, NewVersion}].

maybe_final_upgrade(?LATEST_VERSION_NUM) ->
    ns_audit_cfg:upgrade_descriptors();
maybe_final_upgrade(_) ->
    [].

upgrade(?VERSION_40, Config) ->
    {?VERSION_41,
     create_service_maps(Config, [n1ql, index])};

upgrade(?VERSION_41, Config) ->
    {?VERSION_45,
     create_service_maps(Config, [fts]) ++
         menelaus_users:upgrade_to_4_5(Config) ++
         index_settings_manager:config_upgrade_to_45(Config) ++
         add_index_ram_alert_limit(Config)};

upgrade(?VERSION_45, _Config) ->
    {?VERSION_46, []};

upgrade(?VERSION_46, Config) ->
    {?VERSION_50,
     [{delete, roles_definitions} | menelaus_users:config_upgrade() ++
          ns_bucket:config_upgrade_to_50(Config)]};

upgrade(?VERSION_50, Config) ->
    {?VERSION_51,
     ns_ssl_services_setup:upgrade_client_cert_auth_to_51(Config) ++
         ns_bucket:config_upgrade_to_51(Config)};

upgrade(?VERSION_51, Config) ->
    {?VULCAN_VERSION_NUM,
     menelaus_web_auto_failover:config_upgrade_to_vulcan(Config) ++
         query_settings_manager:config_upgrade_to_vulcan() ++
         eventing_settings_manager:config_upgrade_to_vulcan() ++
         ns_bucket:config_upgrade_to_vulcan(Config) ++
         ns_audit_cfg:upgrade_to_vulcan(Config)}.

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
