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
-module(ns_config_default).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([default/0, upgrade_config/1, get_current_version/0]).

-define(ISASL_PW, "isasl.pw").
-define(NS_LOG, "ns_log").

get_current_version() ->
    {4, 0}.

ensure_data_dir() ->
    RawDir = path_config:component_path(data),
    ok = misc:mkdir_p(RawDir),
    RawDir.

get_data_dir() ->
    RawDir = path_config:component_path(data),
    case misc:realpath(RawDir, "/") of
        {ok, X} -> X;
        _ -> RawDir
    end.

detect_enterprise_version(NsServerVersion) ->
    case re:run(NsServerVersion, <<"-enterprise$">>) of
        nomatch ->
            false;
        _ ->
            true
    end.

%% dialyzer proves that statically and complains about impossible code
%% path if I use ?assert... Sucker
detect_enterprise_version_test() ->
    true = detect_enterprise_version(<<"1.8.0r-9-ga083a1e-enterprise">>),
    true = not detect_enterprise_version(<<"1.8.0r-9-ga083a1e-comm">>).

is_forced(EnvVar) ->
    case os:getenv(EnvVar) of
        false ->
            false;
        "0" ->
            false;
        _ ->
            true
    end.

init_is_enterprise() ->
    MaybeNsServerVersion =
        [V || {ns_server, _, V} <- application:loaded_applications()],
    case lists:any(fun (V) -> detect_enterprise_version(V) end, MaybeNsServerVersion) of
        true ->
            true;
        _ ->
            is_forced("FORCE_ENTERPRISE")
    end.

init_ldap_enabled() ->
    IsForced = is_forced("FORCE_LDAP"),
    IsLinux = os:type() =:= {unix, linux},

    IsForced orelse IsLinux.

default() ->
    ensure_data_dir(),
    DataDir = get_data_dir(),
    InitQuota = case memsup:get_memory_data() of
                    {_, _, _} = MemData ->
                        ns_storage_conf:default_memory_quota(MemData);
                    _ -> undefined
                end,

    PortMeta = case application:get_env(rest_port) of
                   {ok, _Port} -> local;
                   undefined -> global
               end,

    RawLogDir = path_config:component_path(data, "logs"),
    ok = misc:mkdir_p(RawLogDir),

    BreakpadMinidumpDir = path_config:component_path(data, "crash"),
    ok = misc:mkdir_p(BreakpadMinidumpDir),

    IsEnterprise = init_is_enterprise(),
    LdapEnabled = init_ldap_enabled(),

    {AuditGlobalLogs, AuditLocalLogs} =
        case misc:get_env_default(path_audit_log, []) of
            [] ->
                {[{log_path, RawLogDir}], []};
            Path ->
                {[], [{log_path, Path}]}
        end,

    [{{node, node(), config_version}, get_current_version()},
     {directory, path_config:component_path(data, "config")},
     {{node, node(), is_enterprise}, IsEnterprise},
     {{node, node(), ldap_enabled}, LdapEnabled},
     {index_aware_rebalance_disabled, false},
     {max_bucket_count, 10},
     {autocompaction, [{database_fragmentation_threshold, {30, undefined}},
                       {view_fragmentation_threshold, {30, undefined}}]},
     {set_view_update_daemon,
      [{update_interval, 5000},
       {update_min_changes, 5000},
       {replica_update_min_changes, 5000}]},
     {{node, node(), compaction_daemon}, [{check_interval, 30},
                                          {min_file_size, 131072}]},
     {nodes_wanted, [node()]},
     {{node, node(), membership}, active},
     %% In general, the value in these key-value pairs are property lists,
     %% like [{prop_atom1, value1}, {prop_atom2, value2}].
     %%
     %% See the proplists erlang module.
     %%
     %% A change to any of these rest properties probably means a restart of
     %% mochiweb is needed.
     %%
     %% Modifiers: menelaus REST API
     %% Listeners: some menelaus module that configures/reconfigures mochiweb
     {rest,
      [{port, 8091}]},

     {{couchdb, max_parallel_indexers}, 4},
     {{couchdb, max_parallel_replica_indexers}, 2},

     {{node, node(), rest},
      [{port, misc:get_env_default(rest_port, 8091)}, % Port number of the REST admin API and UI.
       {port_meta, PortMeta}]},

     {{node, node(), ssl_rest_port},
      case IsEnterprise of
          true -> misc:get_env_default(ssl_rest_port, 18091);
          _ -> undefined
      end},

     {{node, node(), capi_port},
      misc:get_env_default(capi_port, 8092)},

     {{node, node(), ssl_capi_port},
      case IsEnterprise of
          true -> misc:get_env_default(ssl_capi_port, 18092);
          _ -> undefined
      end},

     {{node, node(), query_port},
      misc:get_env_default(query_port, 8093)},

     {{node, node(), ssl_query_port},
      case IsEnterprise of
          true -> misc:get_env_default(ssl_query_port, 18093);
          _ -> undefined
      end},

     {{node, node(), projector_port},
      misc:get_env_default(projector_port, 9999)},

     {{node, node(), xdcr_rest_port},
      misc:get_env_default(xdcr_rest_port, 9998)},

     {{node, node(), indexer_admin_port},
      misc:get_env_default(indexer_admin_port, 9100)},

     {{node, node(), indexer_scan_port},
      misc:get_env_default(indexer_scan_port, 9101)},

     {{node, node(), indexer_http_port},
      misc:get_env_default(indexer_http_port, 9102)},

     {{node, node(), indexer_stinit_port},
      misc:get_env_default(indexer_stinit_port, 9103)},

     {{node, node(), indexer_stcatchup_port},
      misc:get_env_default(indexer_stcatchup_port, 9104)},

     {{node, node(), indexer_stmaint_port},
      misc:get_env_default(indexer_stmaint_port, 9105)},

     {{node, node(), ssl_proxy_downstream_port},
      case IsEnterprise of
          true -> misc:get_env_default(ssl_proxy_downstream_port, 11214);
          _ -> undefined
      end},

     {{node, node(), ssl_proxy_upstream_port},
      case IsEnterprise of
          true -> misc:get_env_default(ssl_proxy_upstream_port, 11215);
          _ -> undefined
      end},

     %% pre 3.0 format:
     %% {rest_creds, [{creds, [{"user", [{password, "password"}]},
     %%                        {"admin", [{password, "admin"}]}]}
     %% An empty list means no login/password auth check.

     %% for 3.0 clusters:
     %% {rest_creds, {User, {password, {Salt, Mac}}}}
     %% {rest_creds, null} means no login/password auth check.
     %% read_only_user_creds has the same format
     {rest_creds, [{creds, []}
                  ]},
     {remote_clusters, []},
     {{node, node(), isasl}, [{path, filename:join(DataDir, ?ISASL_PW)}]},

     {audit,
      [{auditd_enabled, false},
       {rotate_interval, 86400},
       {rotate_size, 20*1024*1024},
       {disabled, []},
       {sync, []}] ++ AuditGlobalLogs},

     {{node, node(), audit}, AuditLocalLogs},

     {memcached, []},

     {{node, node(), memcached_defaults},
      [{maxconn, 30000},
       {dedicated_port_maxconn, 5000},
       {verbosity, 0},
       {breakpad_enabled, true},
       %% Location that Breakpad should write minidumps upon memcached crash.
       {breakpad_minidump_dir_path, BreakpadMinidumpDir}]},

     %% Memcached config
     {{node, node(), memcached},
      [{port, misc:get_env_default(memcached_port, 11210)},
       {dedicated_port, misc:get_env_default(memcached_dedicated_port, 11209)},
       {ssl_port, case IsEnterprise of
                      true -> misc:get_env_default(memcached_ssl_port, 11207);
                      _ -> undefined
                  end},
       {admin_user, "_admin"},
       %% Note that this is not actually the password that is being used; as
       %% part of upgrading config from 2.2 to 2.3 version it's replaced by
       %% unique per-node password. I didn't put it here because default()
       %% supposed to be a pure function.
       {admin_pass, ""},
       {bucket_engine, path_config:component_path(lib, "memcached/bucket_engine.so")},
       {engines,
        [{membase,
          [{engine, path_config:component_path(lib, "memcached/ep.so")},
           {static_config_string,
            "failpartialwarmup=false"}]},
         {memcached,
          [{engine,
            path_config:component_path(lib, "memcached/default_engine.so")},
           {static_config_string, "vb0=true"}]}]},
       {config_path, path_config:default_memcached_config_path()},
       {audit_file, ns_audit_cfg:default_audit_json_path()},
       {log_path, path_config:component_path(data, "logs")},
       %% Prefix of the log files within the log path that should be rotated.
       {log_prefix, "memcached.log"},
       %% Number of recent log files to retain.
       {log_generations, 20},
       %% how big log file needs to grow before memcached starts using
       %% next file
       {log_cyclesize, 1024*1024*10},
       %% flush interval of memcached's logger in seconds
       {log_sleeptime, 19},
       %% Milliseconds between log rotation runs.
       {log_rotation_period, 39003}]},

     {{node, node(), memcached_config},
      {[
        {interfaces,
         {memcached_config_mgr, omit_missing_mcd_ports,
          [
           {[{host, <<"*">>},
             {port, port},
             {maxconn, maxconn}]},

           {[{host, <<"*">>},
             {port, dedicated_port},
             {maxconn, dedicated_port_maxconn}]},

           {[{host, <<"*">>},
             {port, ssl_port},
             {maxconn, maxconn},
             {ssl, {[{key, list_to_binary(ns_ssl_services_setup:memcached_key_path())},
                     {cert, list_to_binary(ns_ssl_services_setup:memcached_cert_path())}]}}]}
          ]}},

        {breakpad,
         {[{enabled, breakpad_enabled},
           {minidump_dir, {memcached_config_mgr, get_minidump_dir, []}}]}},

        {extensions,
         [
          {[{module, list_to_binary(
                       path_config:component_path(lib,
                                                  "memcached/stdin_term_handler.so"))},
            {config, <<"">>}]},

          {[{module, list_to_binary(
                       path_config:component_path(lib, "memcached/file_logger.so"))},
            {config, {"cyclesize=~B;sleeptime=~B;filename=~s/~s",
                      [log_cyclesize, log_sleeptime, log_path, log_prefix]}}]}
         ]},

        {engine,
         {[{module, list_to_binary(
                      path_config:component_path(lib, "memcached/bucket_engine.so"))},
           {config, {"admin=~s;default_bucket_name=default;auto_create=false",
                     [admin_user]}}]}},

        {verbosity, verbosity},
        {audit_file, {"~s", [audit_file]}}
       ]}},

     {memory_quota, InitQuota},

     {buckets, [{configs, []}]},

     %% Moxi config. This is
     %% per-node so command
     %% line override
     %% doesn't propagate
     {{node, node(), moxi}, [{port, misc:get_env_default(moxi_port, 11211)},
                             {verbosity, ""}
                            ]},

     %% removed since 4.0
     {{node, node(), port_servers}, []},

     {{node, node(), ns_log}, [{filename, filename:join(DataDir, ?NS_LOG)}]},

                                                % Modifiers: menelaus
                                                % Listeners: ? possibly ns_log
     {email_alerts,
      [{recipients, ["root@localhost"]},
       {sender, "couchbase@localhost"},
       {enabled, false},
       {email_server, [{user, ""},
                       {pass, ""},
                       {host, "localhost"},
                       {port, 25},
                       {encrypt, false}]},
       {alerts, [auto_failover_node,auto_failover_maximum_reached,
                 auto_failover_other_nodes_down,auto_failover_cluster_too_small,ip,
                 disk,overhead,ep_oom_errors,ep_item_commit_failed, audit_dropped_events]}
      ]},
     {alert_limits, [
       %% Maximum percentage of overhead compared to max bucket size (%)
       {max_overhead_perc, 50},
       %% Maximum disk usage before warning (%)
       {max_disk_used, 90}
      ]},
     {replication, [{enabled, true}]},
     {auto_failover_cfg, [{enabled, false},
                          % timeout is the time (in seconds) a node needs to be
                          % down before it is automatically faileovered
                          {timeout, 120},
                          % max_nodes is the maximum number of nodes that may be
                          % automatically failovered
                          {max_nodes, 1},
                          % count is the number of nodes that were auto-failovered
                          {count, 0}]},

     %% everything is unlimited by default
     {{request_limit, rest}, undefined},
     {{request_limit, capi}, undefined},
     {drop_request_memory_threshold_mib, undefined}].

%% Recursively replace all strings in a hierarchy that start
%% with a given Prefix with a ReplacementPrefix.  For example,
%% use it like: prefix_replace("/opt/membase/bin", "/opt/couchbase/bin", ConfigKVItem).
prefix_replace(Prefix, ReplacementPrefix, L) when is_list(L) ->
    case lists:prefix(Prefix, L) of
         true  -> ReplacementPrefix ++ lists:nthtail(length(Prefix), L);
         false -> lists:map(fun (X) ->
                                prefix_replace(Prefix, ReplacementPrefix, X)
                            end,
                            L)
    end;
prefix_replace(Prefix, ReplacementPrefix, T) when is_tuple(T) ->
    list_to_tuple(prefix_replace(Prefix, ReplacementPrefix, tuple_to_list(T)));
prefix_replace(_Prefix, _ReplacementPrefix, X) -> X.

%% returns list of changes to config to upgrade it to current version.
%% This will be invoked repeatedly by ns_config until list is empty.
%%
%% NOTE: API-wise we could return new config but that would require us
%% to handle vclock updates
-spec upgrade_config([[{term(), term()}]]) -> [{set, term(), term()}].
upgrade_config(Config) ->
    CurrentVersion = get_current_version(),
    case ns_config:search_node(node(), Config, config_version) of
        {value, CurrentVersion} ->
            [];
        {value, {2,3,0}} ->
            [{set, {node, node(), config_version}, {3,0}} |
             upgrade_config_from_2_3_0_to_3_0(Config)];
        {value, {3,0}} ->
            [{set, {node, node(), config_version}, {3,0,2}} |
             upgrade_config_from_3_0_to_3_0_2(Config)];
        {value, {3,0,2}} ->
            [{set, {node, node(), config_version}, {3,0,99}} |
             upgrade_config_from_3_0_2_to_3_0_99(Config)];
        {value, {3,0,99}} ->
            [{set, {node, node(), config_version}, {4,0}} |
             upgrade_config_from_3_0_99_to_4_0(Config)];
        V0 ->
            OldVersion =
                case V0 of
                    false ->
                        {1, 7};
                    {value, V1} ->
                        V1
                end,

            ?log_error("Detected an attempt to offline upgrade "
                       "from unsupported version ~p. Terminating.", [OldVersion]),
            catch ale:sync_all_sinks(),
            misc:halt(1)
    end.

upgrade_config_from_2_3_0_to_3_0(Config) ->
    ?log_info("Upgrading config from 2.3.0 to 3.0"),
    DefaultConfig = default(),
    do_upgrade_config_from_2_3_0_to_3_0(Config, DefaultConfig).

do_upgrade_config_from_2_3_0_to_3_0(Config, DefaultConfig) ->
    PortServersKey = {node, node(), port_servers},
    {value, DefaultPortServers} = ns_config:search([DefaultConfig], PortServersKey),

    McdConfigKey = {node, node(), memcached_config},
    {value, DefaultMcdConfig} = ns_config:search([DefaultConfig], McdConfigKey),

    upgrade_memcached_ssl_port_and_verbosity(Config, DefaultConfig) ++
        [{set, PortServersKey, DefaultPortServers},
         {set, McdConfigKey, DefaultMcdConfig}].

%% NOTE: verbosity part actually doesn't work anymore because default
%% memcached config doesn't have verbosity field anymore
upgrade_memcached_ssl_port_and_verbosity(Config, DefaultConfig) ->
    McdKey = {node, node(), memcached},

    {value, McdConfig} = ns_config:search(Config, McdKey),
    {value, DefaultMcdConfig} = ns_config:search([DefaultConfig], McdKey),

    NewOrUpdatedParams =
        lists:filter(
          fun ({Key, _Value}) ->
                  lists:member(Key, [ssl_port, verbosity])
          end, DefaultMcdConfig),

    StrippedMcdConfig =
        lists:filter(
          fun ({Key, _Value}) ->
                  not lists:keymember(Key, 1, NewOrUpdatedParams)
          end, McdConfig),

    [{set, McdKey, NewOrUpdatedParams ++ StrippedMcdConfig}].

upgrade_config_from_3_0_to_3_0_2(Config) ->
    ?log_info("Upgrading config from 3.0 to 3.0.2"),
    DefaultConfig = default(),
    do_upgrade_config_from_3_0_to_3_0_2(Config, DefaultConfig).

do_upgrade_config_from_3_0_to_3_0_2(Config, DefaultConfig) ->
    McdKey = {node, node(), memcached},
    {value, DefaultMcdConfig} = ns_config:search([DefaultConfig], McdKey),
    {value, CurrentMcdConfig} = ns_config:search(Config, McdKey),
    EnginesTuple = {engines, _} = lists:keyfind(engines, 1, DefaultMcdConfig),
    NewMcdConfig = lists:keystore(engines, 1, CurrentMcdConfig, EnginesTuple),

    %% MB-12655: we 'upgrade' all per node keys of this node to include vclock.
    %%
    %% NOTE: that on brand new installations of 3.0+ we already force
    %% all per-node keys to have vclocks as part of work on
    %% MB-10254. At the time of this writing it is done as part of
    %% ns_config initialization
    PerNodeKeyTouchings = [{set, K, V}
                           || {{node, N, KN} = K, V} <- ns_config:get_kv_list_with_config(Config),
                              N =:= node(),
                              KN =/= config_version,
                              KN =/= memcached],

    [{set, McdKey, NewMcdConfig} | PerNodeKeyTouchings].

upgrade_config_from_3_0_2_to_3_0_99(Config) ->
    ?log_info("Upgrading config from 3.0.2 to 3.0.99"),
    DefaultConfig = default(),
    do_upgrade_config_from_3_0_2_to_3_0_99(Config, DefaultConfig).

do_upgrade_config_from_3_0_2_to_3_0_99(Config, DefaultConfig) ->
    McdKey = {node, node(), memcached},
    JTKey = {node, node(), memcached_config},
    PortServersKey = {node, node(), port_servers},
    {value, DefaultMcdConfig} = ns_config:search([DefaultConfig], McdKey),
    {value, DefaultJsonTemplateConfig} = ns_config:search([DefaultConfig], JTKey),
    {value, DefaultPortServers} = ns_config:search([DefaultConfig], PortServersKey),
    {value, CurrentMcdConfig} = ns_config:search(Config, McdKey),
    EnginesTuple = {engines, _} = lists:keyfind(engines, 1, DefaultMcdConfig),
    ConfigPathTuple = {config_path, _} = lists:keyfind(config_path, 1, DefaultMcdConfig),
    NewMcdConfig0 = lists:keystore(engines, 1, CurrentMcdConfig, EnginesTuple),
    NewMcdConfig1 = lists:keystore(config_path, 1, NewMcdConfig0, ConfigPathTuple),
    NewMcdConfig2 = lists:keydelete(verbosity, 1, NewMcdConfig1),
    [{set, McdKey, NewMcdConfig2},
     {set, JTKey, DefaultJsonTemplateConfig},
     {set, PortServersKey, DefaultPortServers}].

upgrade_config_from_3_0_99_to_4_0(Config) ->
    ?log_info("Upgrading config from 3.0.99 to 4.0"),
    do_upgrade_config_from_3_0_99_to_4_0(Config, default()).

do_upgrade_config_from_3_0_99_to_4_0(Config, DefaultConfig) ->
    MCDefaultsK = {node, node(), memcached_defaults},
    {value, NewMCDefaults} = ns_config:search([DefaultConfig], MCDefaultsK),

    PortServersK = {node, node(), port_servers},
    {value, NewPSDefaults} = ns_config:search([DefaultConfig], PortServersK),

    McdKey = {node, node(), memcached},
    {value, DefaultMcdConfig} = ns_config:search([DefaultConfig], McdKey),
    AuditFileTupleMcd = {audit_file, _} = lists:keyfind(audit_file, 1, DefaultMcdConfig),
    {value, CurrentMcdConfig} = ns_config:search(Config, McdKey),
    NewMcdConfig = lists:keystore(audit_file, 1, CurrentMcdConfig, AuditFileTupleMcd),

    JTKey = {node, node(), memcached_config},
    {value, {DefaultJsonTemplateConfig}} = ns_config:search([DefaultConfig], JTKey),
    AuditFileTupleJT = {audit_file, _} = lists:keyfind(audit_file, 1, DefaultJsonTemplateConfig),
    {value, {CurrentJsonTemplateConfig}} = ns_config:search(Config, JTKey),
    NewJsonTemplateConfig = lists:keystore(audit_file, 1, CurrentJsonTemplateConfig, AuditFileTupleJT),

    [{set, MCDefaultsK, NewMCDefaults},
     {set, PortServersK, NewPSDefaults},
     {set, McdKey, NewMcdConfig},
     {set, JTKey, {NewJsonTemplateConfig}}].

upgrade_2_3_0_to_3_0_test() ->
    Cfg = [[{some_key, some_value},
            {{node, node(), memcached},
             [{ssl_port, 1}, {verbosity, "-v"}, {port, 3}]},
            {{node, node(), memcached_config}, memcached_config}]],
    Default = [{{node, node(), port_servers}, port_servers_cfg},
               {{node, node(), memcached}, [{ssl_port, 1}, {verbosity, 2}]},
               {{node, node(), memcached_config}, memcached_config}],

    ?assertMatch([{set, {node, _, memcached}, [{ssl_port, 1},
                                               {verbosity, 2}, {port, 3}]},
                  {set, {node, _, port_servers}, _},
                  {set, {node, _, memcached_config}, _}],
                 do_upgrade_config_from_2_3_0_to_3_0(Cfg, Default)).

upgrade_3_0_to_3_0_2_test() ->
    Cfg = [[{some_key, some_value},
            {{node, node(), memcached},
             [{engines, old_value},
              {ssl_port, 1},
              {verbosity, 2},
              {port, 3}]},
            {{node, node(), memcached_config}, memcached_config}]],
    Default = [{{node, node(), port_servers}, port_servers_cfg},
               {{node, node(), memcached}, [{ssl_port, 1}, {verbosity, 3},
                                            {engines, [something]}]},
               {{node, node(), memcached_config}, memcached_config}],

    ?assertMatch([{set, {node, _, memcached}, [{engines, [something]},
                                               {ssl_port, 1}, {verbosity, 2},
                                               {port, 3}]},
                  {set, {node, _, memcached_config}, memcached_config}],
                 do_upgrade_config_from_3_0_to_3_0_2(Cfg, Default)).

upgrade_3_0_2_to_3_0_99_test() ->
    Cfg = [[{some_key, some_value},
            {{node, node(), memcached},
             [{engines, old_value},
              {ssl_port, 1},
              {verbosity, 2},
              {port, 3}]},
            {{node, node(), memcached_config}, memcached_config}]],
    Default = [{{node, node(), port_servers}, port_servers_cfg},
               {{node, node(), memcached}, [{ssl_port, 1},
                                            {config_path, cfg_path},
                                            {engines, [something]}]},
               {{node, node(), memcached_config}, memcached_config},
               {{node, node(), port_servers}, port_servers_cfg}],

    ?assertMatch([{set, {node, _, memcached}, [{engines, [something]},
                                               {ssl_port, 1},
                                               {port, 3},
                                               {config_path, cfg_path}]},
                  {set, {node, _, memcached_config}, memcached_config},
                  {set, {node, _, port_servers}, port_servers_cfg}],
                 do_upgrade_config_from_3_0_2_to_3_0_99(Cfg, Default)).

upgrade_3_0_99_to_4_0_test() ->
    Cfg = [[{some_key, some_value},
            {{node, node(), memcached},
             [{some_key, some_value}]},
            {{node, node(), port_servers}, old_port_servers},
            {{node, node(), memcached_config},
             {[{some_key, some_value}]}}
           ]],
    Default = [{{node, node(), memcached_defaults},
                [{some, stuff}]},
               {{node, node(), port_servers}, new_port_servers},
               {{node, node(), memcached},
                [{audit_file, audit_file_path}]},
               {{node, node(), memcached_config},
                {[{audit_file, audit_file}]}}],
    ?assertMatch([{set, {node, _, memcached_defaults}, [{some, stuff}]},
                  {set, {node, _, port_servers}, new_port_servers},
                  {set, {node, _, memcached}, [{some_key, some_value},
                                               {audit_file, audit_file_path}]},
                  {set, {node, _, memcached_config}, {[{some_key, some_value},
                                                       {audit_file, audit_file}]}}],
                 do_upgrade_config_from_3_0_99_to_4_0(Cfg, Default)).

no_upgrade_on_current_version_test() ->
    ?assertEqual([], upgrade_config([[{{node, node(), config_version}, get_current_version()}]])).

prefix_replace_test() ->
    ?assertEqual("", prefix_replace("/foo", "/bar", "")),
    ?assertEqual(foo, prefix_replace("/foo", "/bar", foo)),
    ?assertEqual([], prefix_replace("/foo", "/bar", [])),
    ?assertEqual([foo], prefix_replace("/foo", "/bar", [foo])),
    ?assertEqual("/bar/x", prefix_replace("/foo", "/bar", "/foo/x")),
    ?assertEqual([1, "/bar/x", 2], prefix_replace("/foo", "/bar", [1, "/foo/x", 2])),
    ?assertEqual({1, "/bar/x", 2}, prefix_replace("/foo", "/bar", {1, "/foo/x", 2})),
    ?assertEqual([1, "/bar/x", {"/bar/x"}],
                 prefix_replace("/foo", "/bar", [1, "/foo/x", {"/foo/x"}])).
