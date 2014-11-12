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
    {3,0,99}.

ensure_data_dir() ->
    RawDir = path_config:component_path(data),
    filelib:ensure_dir(RawDir),
    file:make_dir(RawDir),
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

is_forced_enterprise() ->
    case os:getenv("FORCE_ENTERPRISE") of
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
            is_forced_enterprise()
    end.

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
    filelib:ensure_dir(RawLogDir),
    file:make_dir(RawLogDir),

    IsEnterprise = init_is_enterprise(),

    [{directory, path_config:component_path(data, "config")},
     {{node, node(), is_enterprise}, IsEnterprise},
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

     {{node, node(), projector_port},
      misc:get_env_default(projector_port, 9999)},

     {{node, node(), indexer_port},
      misc:get_env_default(indexer_port, 9102)},

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

     {memcached,
      [{maxconn, 30000},
       {dedicated_port_maxconn, 5000},
       {verbosity, 0}]},

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
         {ns_ports_setup, omit_missing_mcd_ports,
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

        {verbosity, verbosity}
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

     %% Note that we currently assume the ports are available
     %% across all servers in the cluster.
     %%
     %% This is a classic "should" key, where ns_port_sup needs
     %% to try to start child processes.  If it fails, it should ns_log errors.
     {{node, node(), port_servers},
      [{moxi, path_config:component_path(bin, "moxi"),
        ["-Z", {"port_listen=~B,default_bucket_name=default,downstream_max=1024,downstream_conn_max=4,"
                "connect_max_errors=5,connect_retry_interval=30000,"
                "connect_timeout=400,"
                "auth_timeout=100,cycle=200,"
                "downstream_conn_queue_timeout=200,"
                "downstream_timeout=5000,wait_queue_timeout=200",
                [port]},
         "-z", {"url=http://127.0.0.1:~B/pools/default/saslBucketsStreaming",
                [{misc, this_node_rest_port, []}]},
         "-p", "0",
         "-Y", "y",
         "-O", "stderr",
         {"~s", [verbosity]}
        ],
        [{env, [{"EVENT_NOSELECT", "1"},
                {"MOXI_SASL_PLAIN_USR", {"~s", [{ns_moxi_sup, rest_user, []}]}},
                {"MOXI_SASL_PLAIN_PWD", {"~s", [{ns_moxi_sup, rest_pass, []}]}}
               ]},
         use_stdio, exit_status,
         port_server_send_eol,
         stderr_to_stdout,
         stream]
       },
       {memcached, path_config:component_path(bin, "memcached"),
        ["-C", {"~s", [{memcached, config_path}]}],
        [{env, [{"EVENT_NOSELECT", "1"},
                %% NOTE: bucket engine keeps this number of top keys
                %% per top-keys-shard. And number of shards is hard-coded to 8
                %%
                %% So with previous setting of 100 we actually got 800
                %% top keys every time. Even if we need just 10.
                %%
                %% See hot_keys_keeper.erl TOP_KEYS_NUMBER constant
                %%
                %% Because of that heavy sharding we cannot ask for
                %% very small number, which would defeat usefulness
                %% LRU-based top-key maintenance in memcached. 5 seems
                %% not too small number which means that we'll deal
                %% with 40 top keys.
                {"MEMCACHED_TOP_KEYS", "5"},
                {"ISASL_PWFILE", {"~s", [{isasl, path}]}}]},
         use_stdio,
         stderr_to_stdout, exit_status,
         port_server_send_eol,
         port_server_dont_start,
         stream]
       }]
     },

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
                 disk,overhead,ep_oom_errors,ep_item_commit_failed]}
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
     {drop_request_memory_threshold_mib, undefined},
     {replication_topology, star}].

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
        false ->
            [{set, {node, node(), config_version}, {1,7,1}} |
             upgrade_config_from_1_7_to_1_7_1()];
        {value, {1,7,1}} ->
            [{set, {node, node(), config_version}, {1,7,2}} |
             upgrade_config_from_1_7_1_to_1_7_2(Config)];
        {value, {1,7,2}} ->
            [{set, {node, node(), config_version}, {1,8,0}} |
             upgrade_config_from_1_7_2_to_1_8_0(Config)];
        {value, {1,8,0}} ->
            [{set, {node, node(), config_version}, {1,8,1}} |
             upgrade_config_from_1_8_0_to_1_8_1(Config)];
        {value, {1,8,1}} ->
            [{set, {node, node(), config_version}, {2,0}} |
             upgrade_config_from_1_8_1_to_2_0(Config)];
        {value, {2,0}} ->
            [{set, {node, node(), config_version}, {2,2,0}} |
             upgrade_config_from_2_0_to_2_2_0(Config)];
        {value, {2,2,0}} ->
            [{set, {node, node(), config_version}, {2,3,0}} |
             upgrade_config_from_2_2_0_to_2_3_0(Config)];
        {value, {2,3,0}} ->
            [{set, {node, node(), config_version}, {3,0}} |
             upgrade_config_from_2_3_0_to_3_0(Config)];
        {value, {3,0}} ->
            [{set, {node, node(), config_version}, {3,0,2}} |
             upgrade_config_from_3_0_to_3_0_2(Config)];
        {value, {3,0,2}} ->
            [{set, {node, node(), config_version}, {3,0,99}} |
             upgrade_config_from_3_0_2_to_3_0_99(Config)]
    end.

upgrade_config_from_1_7_to_1_7_1() ->
    ?log_info("Upgrading config from 1.7 to 1.7.1"),
    DefaultConfig = default(),
    do_upgrade_config_from_1_7_to_1_7_1(DefaultConfig).

do_upgrade_config_from_1_7_to_1_7_1(DefaultConfig) ->
    {email_alerts, Alerts} = lists:keyfind(email_alerts, 1, DefaultConfig),
    {auto_failover_cfg, AutoFailover} = lists:keyfind(auto_failover_cfg, 1, DefaultConfig),
    [{set, email_alerts, Alerts},
     {set, auto_failover_cfg, AutoFailover}].

upgrade_config_from_1_7_1_to_1_7_2(Config) ->
    ?log_info("Upgrading config from 1.7.1 to 1.7.2"),
    DefaultConfig = default(),
    do_upgrade_config_from_1_7_1_to_1_7_2(Config, DefaultConfig).

do_upgrade_config_from_1_7_1_to_1_7_2(Config, DefaultConfig) ->
    RestConfig = case ns_config:search_node(Config, rest) of
                     false -> [];
                     {value, RestConfigX} -> RestConfigX
                 end,

    NeedRestUpgrade = lists:keysearch(port_meta, 1, RestConfig) =:= false,
    case NeedRestUpgrade of
        true -> do_upgrade_rest_port_config_from_1_7_1_to_1_7_2(Config, DefaultConfig);
        _ -> []
    end.

do_upgrade_rest_port_config_from_1_7_1_to_1_7_2(Config, DefaultConfig) ->
    Node = node(),
    NodesWanted = case ns_config:search(Config, nodes_wanted) of
                      {value, Nodes} -> lists:usort(Nodes);
                      false -> []
                  end,

    RestPorts = lists:map(
                  fun (N) ->
                          misc:node_rest_port(Config, N)
                  end,
                  NodesWanted),

    {rest, DefaultRest} = lists:keyfind(rest, 1, DefaultConfig),
    {{node, Node, rest}, DefaultNodeRest} =
        lists:keyfind({node, node(), rest}, 1, DefaultConfig),

    {RestChangeValue, NodeRestChangeValue} =
        case lists:usort(RestPorts) of
            [] ->
                ?log_debug("Setting global and node rest port to default"),
                {DefaultRest, DefaultNodeRest};
            [Port] ->
                ?log_debug("Setting global and per-node rest port to ~p", [Port]),
                {[{port, Port}], [{port, Port}, {port_meta, global}]};
            _ ->
                ?log_debug("Setting global rest port to default "
                           "but keeping per node value "),
                OurPort = ns_config:search_node_prop(Node, Config, rest, port),
                {DefaultRest, [{port, OurPort}, {port_meta, local}]}
        end,

    RestChange = [{set, rest, RestChangeValue}],
    NodeRestChange = [{set, {node, Node, rest}, NodeRestChangeValue}],

    RestChange ++ NodeRestChange.

upgrade_config_from_1_7_2_to_1_8_0(Config) ->
    ?log_info("Upgrading config from 1.7.2 to 1.8.0"),
    DefaultConfig = default(),
    do_upgrade_config_from_1_7_2_to_1_8_0(Config, DefaultConfig).

do_upgrade_config_from_1_7_2_to_1_8_0(Config, DefaultConfig) ->
    ReplaceAllPrefixes =
        fun (V) ->
                V2 = prefix_replace("/opt/membase/bin/",
                                    "/opt/couchbase/bin/", V),
                V3 = prefix_replace("/opt/membase/lib/",
                                    "/opt/couchbase/lib/", V2),
                prefix_replace("/opt/membase/etc/", "/opt/couchbase/etc/", V3)
        end,

    %% Note that port_servers value does not contain prefixes that we *don't*
    %% want to replace. This means that we can just take the value from
    %% default config.
    %%
    %% Additionally this enables moxi rest_port fix for the nodes being
    %% updated from previous versions.
    Key = {node, node(), port_servers},
    {Key, DefaultPortServers} = lists:keyfind(Key, 1, DefaultConfig),
    Results = [{set, Key, DefaultPortServers}],

    lists:foldl(
      fun ({_K, false}, Acc) -> Acc;
          ({K, {value, V}}, Acc) ->
              V1 = ReplaceAllPrefixes(V),
              case V =:= V1 of
                  true -> Acc;
                  false -> [{set, K, V1} | Acc]
              end
      end,
      Results,
      [{{node, node(), memcached}, ns_config:search_node(Config, memcached)}]).

upgrade_config_from_1_8_0_to_1_8_1(Config) ->
    ?log_info("Upgrading config from 1.8.0 to 1.8.1"),

    DefaultConfig = default(),
    do_upgrade_config_from_1_8_0_to_1_8_1(Config, DefaultConfig).

do_upgrade_config_from_1_8_0_to_1_8_1(Config, DefaultConfig) ->
    update_binaries_cfg_pathes_and_add_dedicated_port(Config, DefaultConfig).

update_binaries_cfg_pathes_and_add_dedicated_port(Config, DefaultConfig) ->
    FullReplacements =
        [{set, FullK, V} || {{node, N, K} = FullK, V} <- DefaultConfig,
                        N =:= node(),
                        lists:member(K, [port_servers, isasl, ns_log])],
    McdKey = {node, node(), memcached},
    {value, McdConfig} = ns_config:search_node(Config, memcached),
    StrippedMcdConfig = [Pair || {K, _} = Pair <- McdConfig,
                                 not lists:member(K, [bucket_engine, engines])],
    DedicatedPort = ns_config:search_node_prop(node(), [DefaultConfig], memcached, dedicated_port),
    true = (DedicatedPort =/= undefined),
    {_, DefaultMcdConfig} = lists:keyfind(McdKey, 1, DefaultConfig),
    {_,_} = BucketEnginePair = lists:keyfind(bucket_engine, 1, DefaultMcdConfig),
    {_,_} = EnginesPair = lists:keyfind(engines, 1, DefaultMcdConfig),
    [{set, McdKey, [{dedicated_port, DedicatedPort},
                    BucketEnginePair,
                    EnginesPair
                    | StrippedMcdConfig]}
     | FullReplacements].

upgrade_config_from_1_8_1_to_2_0(Config) ->
    ?log_info("Upgrading config from 1.8.1 to 2.0", []),
    DefaultConfig = default(),
    do_upgrade_config_from_1_8_1_to_2_0(Config, DefaultConfig).

do_upgrade_config_from_1_8_1_to_2_0(Config, DefaultConfig) ->
    MaybeCapiPort = case ns_config:search(Config, {node, node(), capi_port}) of
                        false ->
                            {_, DefaultCapiPort} = lists:keyfind({node, node(), capi_port}, 1, DefaultConfig),
                            [{set, {node, node(), capi_port}, DefaultCapiPort}];
                        _ ->
                            []
                    end,
    MaybeAutoCompaction = case ns_config:search(Config, autocompaction) of
                              {value, _} -> [];
                              false ->
                                  {_, AutoCompactionV} = lists:keyfind(autocompaction, 1, DefaultConfig),
                                  [{set, autocompaction, AutoCompactionV}]
                          end,
    MaybeRemoteClusters = case ns_config:search(Config, remote_clusters) of
                              {value, _} -> [];
                              false ->
                                  {_, RemoteClustersV} = lists:keyfind(remote_clusters, 1, DefaultConfig),
                                  [{set, remote_clusters, RemoteClustersV}]
                          end,

    MaybeCompactionDaemon = case ns_config:search(Config, {node, node(), compaction_daemon}) of
                                {value, _} ->
                                    [];
                                false ->
                                    {_, CompactionDaemonSettings} = lists:keyfind({node, node(), compaction_daemon},
                                                                                  1, DefaultConfig),
                                    [{set, {node, node(), compaction_daemon}, CompactionDaemonSettings}]
                            end,

    MaybeCapiPort ++
        MaybeAutoCompaction ++
        MaybeRemoteClusters ++
        MaybeCompactionDaemon ++
        maybe_upgrade_engines_add_mccouch_port_log_params(Config, DefaultConfig).

maybe_upgrade_engines_add_mccouch_port_log_params(Config, DefaultConfig) ->
    McdKey = {node, node(), memcached},

    {value, McdConfig} = ns_config:search(Config, McdKey),
    {value, DefaultMcdConfig} = ns_config:search([DefaultConfig], McdKey),

    NewOrUpdatedParams =
        lists:filter(
          fun ({Key, _Value}) ->
                  lists:member(Key, [log_path, log_prefix, log_generations,
                                     log_cyclesize, log_sleeptime,
                                     log_rotation_period,
                                     engines])
          end, DefaultMcdConfig),

    StrippedMcdConfig =
        lists:filter(
          fun ({Key, _Value}) ->
                  not lists:keymember(Key, 1, NewOrUpdatedParams)
          end, McdConfig),

    PortServersKey = {node, node(), port_servers},
    {value, DefaultPortServers} = ns_config:search([DefaultConfig], PortServersKey),

    [{set, McdKey, NewOrUpdatedParams ++ StrippedMcdConfig},
     {set, PortServersKey, DefaultPortServers}].

upgrade_config_from_2_0_to_2_2_0(Config) ->
    ?log_info("Upgrading config from 2.0 to 2.2.0", []),
    DefaultConfig = default(),
    DataDir = get_data_dir(),
    do_upgrade_files_from_2_0_to_2_2_0(DataDir),
    do_upgrade_config_from_2_0_to_2_2_0(Config, DefaultConfig, DataDir).

upgrade_config_from_2_2_0_to_2_3_0(Config) ->
    ?log_info("Upgrading config from 2.2.0 to 2.3.0"),
    {value, MemcachedConfig} = ns_config:search(Config, {node, node(), memcached}),
    MemcachedConfig1 = lists:keystore(log_generations, 1, MemcachedConfig,
                                      {log_generations, 20}),
    MemcachedConfig2 = lists:keystore(log_cyclesize, 1, MemcachedConfig1,
                                      {log_cyclesize, 1024*1024*10}),

    UUID = binary_to_list(couch_uuids:random()),
    MemcachedConfig3 = lists:keystore(admin_pass, 1, MemcachedConfig2,
                                      {admin_pass, UUID}),

    [{set, {node, node(), memcached}, MemcachedConfig3}].

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

search_sub_key(Config, Key, Subkey) ->
    case ns_config:search(Config, Key) of
        false ->
            false;
        {value, List} ->
            case lists:keyfind(Subkey, 1, List) of
                false ->
                    false;
                {Subkey, X} ->
                    X
            end
    end.

upgrade_if_equals(Config, DefaultConfig, Key, Subkey, Value) ->
    Upgrade = case search_sub_key(Config, Key, Subkey) of
                  false ->
                      true;
                  X ->
                      X =:= Value
              end,
    case Upgrade of
        true ->
            {_, UpgradeValue} = lists:keyfind(Key, 1, DefaultConfig),
            [{set, Key, UpgradeValue}];
        false ->
            []
    end.

do_upgrade_config_from_2_0_to_2_2_0(Config, DefaultConfig, DataDir) ->
    OldDataDir = filename:join(DataDir, "data"),

    OldVersionPwFile = filename:join(OldDataDir, ?ISASL_PW),
    OldVersionNsLog = filename:join(OldDataDir, ?NS_LOG),

    MayBePwFile = upgrade_if_equals(Config, DefaultConfig, {node, node(), isasl}, path,
                                    OldVersionPwFile),
    MayBeNsLog = upgrade_if_equals(Config, DefaultConfig, {node, node(), ns_log}, filename,
                                   OldVersionNsLog),

    MayBePwFile ++ MayBeNsLog.

delete_file(Filename) ->
    case file:delete(Filename) of
        {error,enoent} ->
            ok;
        ok ->
            ok;
        Err ->
            ?log_error("Cannot delete file ~p. Error: ~p", [Filename, Err]),
            Err
    end.

rename_file(Source, Dest) ->
    case file:rename(Source, Dest) of
        {error,enoent} ->
            ok;
        ok ->
            ok;
        Err ->
            ?log_error("Cannot rename file from ~p to ~p. Error: ~p", [Source, Dest, Err]),
            Err
    end.

do_upgrade_files_from_2_0_to_2_2_0(DataDir) ->
    OldDataDir = filename:join(DataDir, "data"),

    %% this file will be regenerated, so just delete it
    %% from the old location if it is there
    OldVersionPwFile = filename:join(OldDataDir, ?ISASL_PW),
    delete_file(OldVersionPwFile),

    OldVersionNsLog = filename:join(OldDataDir, ?NS_LOG),
    NsLog = filename:join(DataDir, ?NS_LOG),

    case filelib:is_file(NsLog) of
        true ->
            delete_file(OldVersionNsLog);
        false ->
            rename_file(OldVersionNsLog, NsLog)
    end.

upgrade_1_7_1_to_1_7_2_test() ->
    DefaultCfg = [{rest, [{port, 8091}]},
                  {{node, node(), rest},
                   [{port, 8091},
                    {port_meta, global}]}],

    OldCfg0 = [{nodes_wanted, [node()]},
               {{node, node(), rest}, [{port, 9000}]}],
    Ref0 = [{set, rest, [{port, 9000}]},
            {set, {node, node(), rest},
             [{port, 9000},
              {port_meta, global}]}],

    Res0 = do_upgrade_config_from_1_7_1_to_1_7_2([OldCfg0], DefaultCfg),
    ?assertEqual(lists:sort(Ref0), lists:sort(Res0)),


    OldCfg1 = [],
    Ref1 = [{set, rest, [{port, 8091}]},
            {set, {node, node(), rest},
             [{port, 8091},
              {port_meta, global}]}],

    Res1 = do_upgrade_config_from_1_7_1_to_1_7_2([OldCfg1], DefaultCfg),
    ?assertEqual(lists:sort(Ref1), lists:sort(Res1)),

    OldCfg2 = [{nodes_wanted, [node(), other_node]},
               {{node, node(), rest}, [{port, 9000}]},
               {{node, other_node, rest}, [{port, 9001}]}],
    Ref2 = [{set, rest, [{port, 8091}]},
            {set, {node, node(), rest},
             [{port, 9000}, {port_meta, local}]}],

    Res2 = do_upgrade_config_from_1_7_1_to_1_7_2([OldCfg2], DefaultCfg),
    ?assertEqual(lists:sort(Ref2), lists:sort(Res2)),

    OldCfg3 = [{nodes_wanted, [node(), other_node]},
               {{node, node(), rest}, [{port, 9000}]},
               {{node, other_node, rest}, [{port, 9000}]}],
    Ref3 = [{set, rest, [{port, 9000}]},
            {set, {node, node(), rest},
             [{port, 9000},
              {port_meta, global}]}],

    Res3 = do_upgrade_config_from_1_7_1_to_1_7_2([OldCfg3], DefaultCfg),
    ?assertEqual(lists:sort(Ref3), lists:sort(Res3)),

    OldCfg4 = [{nodes_wanted, [node(), other_node]},
               {rest, [{port, 9000}]},
               {{node, node(), rest}, [{port, 9000}]},
               {{node, other_node, rest},
                [{port, 9000}, {port_meta, global}]}],
    Ref4 = [{set, rest, [{port, 9000}]},
            {set, {node, node(), rest},
             [{port, 9000},
              {port_meta, global}]}],

    Res4 = do_upgrade_config_from_1_7_1_to_1_7_2([OldCfg4], DefaultCfg),
    ?assertEqual(lists:sort(Ref4), lists:sort(Res4)).

upgrade_1_7_2_to_1_8_0_test() ->
    DefaultCfg = [{{node, node(), port_servers},
                   [{moxi, "/opt/couchbase/bin/moxi something"},
                    {memcached, "/opt/couchbase/bin/memcached something"}]}],

    OldCfg0 = [{nodes_wanted, [node()]},
               {{node, node(), rest}, [{port, 9000}]},
               {port_servers, [{moxi, "moxi something"},
                               {memcached, "memcached something"}]}],
    Res0 = do_upgrade_config_from_1_7_2_to_1_8_0([OldCfg0], DefaultCfg),
    ?assertEqual([{set, {node, node(), port_servers},
                   [{moxi, "/opt/couchbase/bin/moxi something"},
                    {memcached, "/opt/couchbase/bin/memcached something"}]}],
                   lists:sort(Res0)),

    OldCfg1 = [{{node,node(),memcached},
                [{dbdir,"/opt/membase/var/lib/membase/data"},
                 {port,11210},
                 {bucket_engine,"/opt/membase/lib/memcached/bucket_engine.so"},
                 {engines,
                  [{membase,
                    [{engine,"/opt/membase/lib/memcached/ep.so"},
                     {initfile,"/opt/membase/etc/membase/init.sql"},
                     {static_config_string,"foo"}]},
                   {memcached,
                    [{engine,"/opt/membase/lib/memcached/default_engine.so"},
                     {static_config_string,"bar"}]}]},
                 {verbosity,[]}]},
               {otp,[{cookie,shouldnotbechanged}]},
               {directory,"/opt/membase/var/lib/membase/config"},
               {port_servers, [{moxi, "/opt/membase/bin/moxi something"},
                               {memcached,
                                "/opt/membase/bin/memcached something"}]}],
    RefCfg1 = [{set, {node,node(),memcached},
                [{dbdir,"/opt/membase/var/lib/membase/data"},
                 {port,11210},
                 {bucket_engine,"/opt/couchbase/lib/memcached/bucket_engine.so"},
                 {engines,
                  [{membase,
                    [{engine,"/opt/couchbase/lib/memcached/ep.so"},
                     {initfile,"/opt/couchbase/etc/membase/init.sql"},
                     {static_config_string,"foo"}]},
                   {memcached,
                    [{engine,"/opt/couchbase/lib/memcached/default_engine.so"},
                     {static_config_string,"bar"}]}]},
                 {verbosity,[]}]},
               {set, {node, node(), port_servers},
                [{moxi, "/opt/couchbase/bin/moxi something"},
                 {memcached, "/opt/couchbase/bin/memcached something"}]}],
    Res1 = do_upgrade_config_from_1_7_2_to_1_8_0([OldCfg1], DefaultCfg),
    ?assertEqual(lists:sort(RefCfg1), lists:sort(Res1)),

    OldCfg2 = [{nodes_wanted, [node()]},
               {{node, node(), rest}, [{port, 9000}]}],
    Res2 = do_upgrade_config_from_1_7_2_to_1_8_0([OldCfg2], DefaultCfg),
    ?assertEqual([{set, {node, node(), port_servers},
                   [{moxi, "/opt/couchbase/bin/moxi something"},
                    {memcached, "/opt/couchbase/bin/memcached something"}]}],
                 lists:sort(Res2)),
    ok.

update_binaries_cfg_pathes_and_add_dedicated_port_test() ->
    DefaultCfg = [{{node, node(), port_servers}, default_port_servers},
                  {{node, node(), isasl}, default_isasl},
                  {{node, node(), ns_log}, ns_log_default},
                  {something_else, else_something},
                  {{node, node(), memcached},
                   [{dedicated_port, 1234},
                    {port, 1235},
                    {other_crap, crap},
                    {bucket_engine, new_bucketen_cfg},
                    {engines, new_engines_cfg}]}],
    OldCfg1 = [[{memcached, [{bucket_engine, old_bucketen_cfg},
                             {some_field, field_some},
                             {engines, old_engines_cfg}]}]],
    RV = lists:sort(update_binaries_cfg_pathes_and_add_dedicated_port(OldCfg1, DefaultCfg)),
    ?assertEqual(lists:sort(
                   [{set, {node, node(), port_servers}, default_port_servers},
                    {set, {node, node(), isasl}, default_isasl},
                    {set, {node, node(), ns_log}, ns_log_default},
                    {set, {node, node(), memcached}, [{dedicated_port, 1234},
                                                      {bucket_engine, new_bucketen_cfg},
                                                      {engines, new_engines_cfg},
                                                      {some_field, field_some}]}]),
                 RV),
    ok.

upgrade_1_8_1_to_2_0_test() ->
    Cfg = [[{{node, node(), capi_port}, something},
            {remote_clusters, foobar},
            {{node, node(), memcached}, [{engines, old_engines},
                                         {something, something}]},
            {{node, node(), port_servers}, old_port_servers}]],
    DefaultCfg = [{{node, node(), capi_port}, somethingelse},
                  {remote_clusters, foobar_2},
                  {autocompaction, compaction_something},
                  {{node, node(), compaction_daemon}, compaction_daemon_settings},
                  {{node, node(), memcached},
                   [{log_path, log_path},
                    {log_prefix, log_prefix},
                    {log_generations, log_generations},
                    {log_rotation_period, log_rotation_period},
                    {engines, new_engines},
                    {something_else, something_else}]},
                  {{node, node(), port_servers}, new_port_servers}],
    Result = do_upgrade_config_from_1_8_1_to_2_0(Cfg, DefaultCfg),
    ?assertEqual([{set, autocompaction, compaction_something},
                  {set, {node, node(), compaction_daemon}, compaction_daemon_settings},
                  {set, {node, node(), memcached},
                   [{log_path, log_path},
                    {log_prefix, log_prefix},
                    {log_generations, log_generations},
                    {log_rotation_period, log_rotation_period},
                    {engines, new_engines},
                    {something, something}]},
                  {set, {node, node(), port_servers}, new_port_servers}],
                 Result),
    Cfg2 = [[{remote_clusters, foobar},
             {{node, node(), compaction_daemon}, compaction_daemon_existing},
             {{node, node(), memcached}, [{something, something}]}]],
    Result2 = do_upgrade_config_from_1_8_1_to_2_0(Cfg2, DefaultCfg),
    ?assertEqual([{set, {node, node(), capi_port}, somethingelse},
                  {set, autocompaction, compaction_something},
                  {set, {node, node(), memcached},
                   [{log_path, log_path},
                    {log_prefix, log_prefix},
                    {log_generations, log_generations},
                    {log_rotation_period, log_rotation_period},
                    {engines, new_engines},
                    {something, something}]},
                  {set, {node, node(), port_servers}, new_port_servers}],
                 Result2).

upgrade_2_0_to_2_2_0_test() ->
    DataDir = "/data/n_0",
    OldDataDir = filename:join(DataDir, "data"),
    DefaultCfg = [{{node, node(), ns_log}, default_ns_log},
                  {{node, node(), isasl}, default_isasl}],
    Cfg1 = [[{{node, node(), ns_log}, [{filename, filename:join("/somewhere/else", ?NS_LOG)}]},
             {{node, node(), isasl}, [{path, filename:join("/somewhere/else", ?ISASL_PW)}]}
            ]],
    Result1 = do_upgrade_config_from_2_0_to_2_2_0(Cfg1, DefaultCfg, DataDir),
    ?assertEqual([], Result1),

    Cfg2 = [[{{node, node(), ns_log}, [{filename, filename:join(OldDataDir, ?NS_LOG)}]},
             {{node, node(), isasl}, [{path, filename:join(OldDataDir, ?ISASL_PW)}]}
            ]],
    Result2 = do_upgrade_config_from_2_0_to_2_2_0(Cfg2, DefaultCfg, DataDir),
    ?assertEqual([
                  {set, {node, node(), isasl}, default_isasl},
                  {set, {node, node(), ns_log}, default_ns_log}
                 ], Result2).

upgrade_2_2_0_to_2_3_0_test() ->
    Key = {node, node(), memcached},
    Cfg = [[{Key,
           [{log_generations, 10},
            {log_cyclesize, 1024*1024*100}]}]],
    UpgradedCfg = upgrade_config_from_2_2_0_to_2_3_0(Cfg),
    ?assertMatch([{set, Key,
                   [{log_generations, 20},
                    {log_cyclesize, 1024*1024*10},
                    {admin_pass, _}]}], UpgradedCfg).

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
