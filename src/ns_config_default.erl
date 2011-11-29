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
-include("ns_config.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([default/0, mergable/1, upgrade_config/1]).

% Allow all keys to be mergable.

mergable(ListOfKVLists) ->
    lists:usort(lists:flatmap(fun keys/1, ListOfKVLists)).

keys(KVLists) ->
    lists:flatmap(fun (KVList) ->
                          [K || {K,_} <- KVList]
                  end, KVLists).

default() ->
    RawDbDir = path_config:component_path(data),
    filelib:ensure_dir(RawDbDir),
    file:make_dir(RawDbDir),
    DbDir0 = case misc:realpath(RawDbDir, "/") of
                 {ok, X} -> X;
                 _ -> RawDbDir
             end,
    DbDir = filename:join(DbDir0, "data"),
    InitQuota = case memsup:get_memory_data() of
                    {_, _, _} = MemData ->
                        element(2, ns_storage_conf:allowed_node_quota_range(MemData));
                    _ -> undefined
                end,
    PortMeta = case application:get_env(rest_port) of
                   {ok, _Port} -> local;
                   undefined -> global
               end,
    [{directory, path_config:component_path(data, "config")},
     {nodes_wanted, [node()]},
     {{node, node(), membership}, active},
                                                % In general, the value in these key-value pairs are property lists,
                                                % like [{prop_atom1, value1}, {prop_atom2, value2}].
                                                %
                                                % See the proplists erlang module.
                                                %
                                                % A change to any of these rest properties probably means a restart of
                                                % mochiweb is needed.
                                                %
                                                % Modifiers: menelaus REST API
                                                % Listeners: some menelaus module that configures/reconfigures mochiweb
     {rest,
      [{port, 8091}]},

     {{node, node(), rest},
      [{port, misc:get_env_default(rest_port, 8091)},
       {port_meta, PortMeta}]},

                                                % In 1.0, only the first entry in the creds list is displayed in the UI
                                                % and accessible through the UI.
                                                %
                                                % Modifiers: menelaus REST API
                                                % Listeners: some menelaus module that configures/reconfigures mochiweb??
     {rest_creds, [{creds, []}
                  ]}, % An empty list means no login/password auth check.

                                                % Example rest_cred when a login/password is setup.
                                                %
                                                % {rest_creds, [{creds, [{"user", [{password, "password"}]},
                                                %                        {"admin", [{password, "admin"}]}]}
                                                %              ]}, % An empty list means no login/password auth check.

                                                % This is also a parameter to memcached ports below.
     {{node, node(), isasl}, [{path, filename:join(DbDir, "isasl.pw")}]},

                                                % Memcached config
     {{node, node(), memcached},
      [{port, misc:get_env_default(memcached_port, 11210)},
       {dbdir, DbDir},
       {admin_user, "_admin"},
       {admin_pass, "_admin"},
       {bucket_engine, path_config:component_path(lib, "memcached/bucket_engine.so")},
       {engines,
        [{membase,
          [{engine, path_config:component_path(lib, "memcached/ep.so")},
           {initfile, path_config:component_path(etc, "init.sql")},
           {static_config_string,
            "vb0=false;waitforwarmup=false;failpartialwarmup=false;"
            "shardpattern=%d/%b-%i.mb;db_strategy=multiMTVBDB"}]},
         {memcached,
          [{engine,
            path_config:component_path(lib, "memcached/default_engine.so")},
           {static_config_string, "vb0=true"}]}]},
       {verbosity, ""}]},

     {memory_quota, InitQuota},

     {buckets, [{configs, []}]},

                                                % Moxi config. This is
                                                % per-node so command
                                                % line override
                                                % doesn't propagate
     {{node, node(), moxi}, [{port, misc:get_env_default(moxi_port, 11211)},
                             {verbosity, ""}
                            ]},

                                                % Note that we currently assume the ports are available
                                                % across all servers in the cluster.
                                                %
                                                % This is a classic "should" key, where ns_port_sup needs
                                                % to try to start child processes.  If it fails, it should ns_log errors.
     {port_servers,
      [{moxi, path_config:component_path(bin, "moxi"),
        ["-Z", {"port_listen=~B,default_bucket_name=default,downstream_max=1024,downstream_conn_max=4,"
                "connect_max_errors=5,connect_retry_interval=30000,"
                "connect_timeout=400,"
                "auth_timeout=100,cycle=200,"
                "downstream_conn_queue_timeout=200,"
                "downstream_timeout=5000,wait_queue_timeout=200",
                [port]},
         "-z", {"url=http://127.0.0.1:~B/pools/default/saslBucketsStreaming",
                [{rest, port}]},
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
        ["-X", path_config:component_path(lib, "memcached/stdin_term_handler.so"),
         "-p", {"~B", [port]},
         "-E", path_config:component_path(lib, "memcached/bucket_engine.so"),
         "-B", "binary",
         "-r",
         "-c", "10000",
         "-e", {"admin=~s;default_bucket_name=default;auto_create=false",
                [admin_user]},
         {"~s", [verbosity]}
        ],
        [{env, [{"EVENT_NOSELECT", "1"},
                {"MEMCACHED_TOP_KEYS", "100"},
                {"ISASL_PWFILE", {"~s", [{isasl, path}]}},
                {"ISASL_DB_CHECK_TIME", "1"}]},
         use_stdio,
         stderr_to_stdout, exit_status,
         port_server_send_eol,
         stream]
       }]
     },

     {{node, node(), ns_log}, [{filename, filename:join(DbDir, "ns_log")}]},

                                                % Modifiers: menelaus
                                                % Listeners: ? possibly ns_log
     {email_alerts,
      [{recipients, ["root@localhost"]},
       {sender, "membase@localhost"},
       {enabled, true},
       {email_server, [{user, ""},
                       {pass, ""},
                       {host, "localhost"},
                       {port, 25},
                       {encrypt, false}]},
       {alerts, [auto_failover_node,
                 auto_failover_maximum_reached,
                 auto_failover_other_nodes_down,
                 auto_failover_cluster_too_small]}
      ]},
     {replication, [{enabled, true}]},
     {auto_failover_cfg, [{enabled, false},
                          % timeout is the time (in seconds) a node needs to be
                          % down before it is automatically faileovered
                          {timeout, 30},
                          % max_nodes is the maximum number of nodes that may be
                          % automatically failovered
                          {max_nodes, 1},
                          % count is the number of nodes that were auto-failovered
                          {count, 0}]}
    ].

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
    case ns_config:search_node(node(), Config, config_version) of
        false ->
            [{set, {node, node(), config_version}, {1,7}} |
             upgrade_config_from_1_6_to_1_7(Config)];
        {value, {1,7}} ->
            [{set, {node, node(), config_version}, {1,7,1}} |
             upgrade_config_from_1_7_to_1_7_1()];
        {value, {1,7,1}} ->
            [{set, {node, node(), config_version}, {1,7,2}} |
             upgrade_config_from_1_7_1_to_1_7_2(Config)];
        {value, {1,7,2}} ->
            [{set, {node, node(), config_version}, {1,8,0}} |
             upgrade_config_from_1_7_2_to_1_8_0(Config)];
        {value, {1,8,0}} ->
            []
    end.

upgrade_config_from_1_6_to_1_7(Config) ->
    ?log_info("Upgrading config from 1.6 to 1.7", []),
    DefaultConfig = default(),
    do_upgrade_config_from_1_6_to_1_7(Config, DefaultConfig).

do_upgrade_config_from_1_6_to_1_7(Config, DefaultConfig) ->
    {value, MemcachedCfg} = ns_config:search_node(Config, memcached),
    {_, DefaultMemcachedCfg} = lists:keyfind({node, node(), memcached}, 1, DefaultConfig),
    {bucket_engine, _} = BucketEnCfg = lists:keyfind(bucket_engine, 1, DefaultMemcachedCfg),
    {engines, _} = EnginesCfg = lists:keyfind(engines, 1, DefaultMemcachedCfg),
    NewMemcachedCfg = lists:foldl(fun (T, Acc) ->
                                          lists:keyreplace(element(1, T), 1, Acc, T)
                                  end, MemcachedCfg, [BucketEnCfg,
                                                      EnginesCfg]),

    VClock = vclock:increment(node(), vclock:fresh()),
    AddVClock = fun (Value) ->
                        [{?METADATA_VCLOCK, VClock} | Value]
                end,

    [{set, {node, node(), memcached}, AddVClock(NewMemcachedCfg)}] ++
        lists:foldl(fun (K, Acc) ->
                            {K,V} = lists:keyfind(K, 1, DefaultConfig),
                            V1 = case K of
                                     {node, Node, _K} when node() =:= Node ->
                                         AddVClock(V);
                                     _Otherwise ->
                                         V
                                 end,
                            [{set, K, V1} | Acc]
                    end, [],
                    [directory,
                     {node, node(), isasl},
                     port_servers,
                     {node, node(), ns_log}]).

upgrade_config_from_1_7_to_1_7_1() ->
    ?log_info("Upgrading config from 1.7 to 1.7.1", []),
    DefaultConfig = default(),
    do_upgrade_config_from_1_7_to_1_7_1(DefaultConfig).

do_upgrade_config_from_1_7_to_1_7_1(DefaultConfig) ->
    {email_alerts, Alerts} = lists:keyfind(email_alerts, 1, DefaultConfig),
    {auto_failover_cfg, AutoFailover} = lists:keyfind(auto_failover_cfg, 1, DefaultConfig),
    [{set, email_alerts, Alerts},
     {set, auto_failover_cfg, AutoFailover}].

upgrade_config_from_1_7_1_to_1_7_2(Config) ->
    ?log_info("Upgrading config from 1.7.1 to 1.7.2", []),
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
                ?log_info("Setting global and node rest port to default", []),
                {DefaultRest, DefaultNodeRest};
            [Port] ->
                ?log_info("Setting global and per-node rest port to ~p", [Port]),
                {[{port, Port}], [{port, Port}, {port_meta, global}]};
            _ ->
                ?log_info("Setting global rest port to default "
                          "but keeping per node value ", []),
                OurPort = ns_config:search_node_prop(Node, Config, rest, port),
                {DefaultRest, [{port, OurPort}, {port_meta, local}]}
        end,

    RestChange = [{set, rest, RestChangeValue}],
    NodeRestChange = [{set, {node, Node, rest}, NodeRestChangeValue}],

    RestChange ++ NodeRestChange.

upgrade_config_from_1_7_2_to_1_8_0(Config) ->
    ?log_info("Upgrading config from 1.7.2 to 1.8.0", []),
    DefaultConfig = default(),
    do_upgrade_config_from_1_7_2_to_1_8_0(Config, DefaultConfig).

do_upgrade_config_from_1_7_2_to_1_8_0(Config, _DefaultConfig) ->
    lists:foldl(
      fun ({_K, false}, Acc) -> Acc;
          ({K, {value, V}}, Acc) ->
              V2 = prefix_replace("/opt/membase/bin/", "/opt/couchbase/bin/", V),
              V3 = prefix_replace("/opt/membase/lib/", "/opt/couchbase/lib/", V2),
              V4 = prefix_replace("/opt/membase/etc/", "/opt/couchbase/etc/", V3),
              case V =:= V4 of
                  true -> Acc;
                  false -> [{set, K, V4} | Acc]
              end
      end,
      [],
      [{port_servers,              ns_config:search(Config, port_servers)},
       {{node, node(), memcached}, ns_config:search_node(Config, memcached)}]).

upgrade_1_6_to_1_7_test() ->
    DefaultCfg = [{directory, default_directory},
                  {{node, node(), isasl}, [{path, default_isasl}]},
                  {some_random, value},
                  {{node, node(), memcached},
                   [{bucket_engine, "new-be"},
                    {engines, "new-engines"}]},
                  {port_servers,
                   [{moxi, "moxi something"},
                    {memcached, "memcached something"}]},
                  {{node, node(), ns_log}, default_log}],
    OldCfg = [{{node, node(), memcached},
               [{dbdir, "dbdir"},
                {bucket_engine, "old-be"},
                {engines, "old-engines"}]}],

    StripValue = fun ([{?METADATA_VCLOCK, _V} | Rest]) ->
                         Rest;
                     (Other) ->
                         Other
                 end,
    Strip = fun (Config) ->
                    lists:map(
                      fun ({set, K, V}) ->
                              {set, K, StripValue(V)};
                          (Other) ->
                              Other
                      end,
                      Config)
            end,

    Res = do_upgrade_config_from_1_6_to_1_7([OldCfg], DefaultCfg),

    ?assertEqual(lists:sort([{set, directory, default_directory},
                             {set, {node, node(), isasl},
                              [{path, default_isasl}]},
                             {set, {node, node(), memcached},
                              [{dbdir, "dbdir"},
                               {bucket_engine, "new-be"},
                               {engines, "new-engines"}]},
                             {set, port_servers,
                              [{moxi, "moxi something"},
                               {memcached, "memcached something"}]},
                             {set, {node, node(), ns_log}, default_log}]),
                 lists:sort(Strip(Res))).

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
    OldCfg0 = [{nodes_wanted, [node()]},
               {{node, node(), rest}, [{port, 9000}]}],
    Res0 = do_upgrade_config_from_1_7_2_to_1_8_0([OldCfg0], []),
    ?assertEqual([], lists:sort(Res0)),

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
               {directory,"/opt/membase/var/lib/membase/config"}],
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
                 {verbosity,[]}]}],
    Res1 = do_upgrade_config_from_1_7_2_to_1_8_0([OldCfg1], []),
    ?assertEqual(lists:sort(RefCfg1), lists:sort(Res1)),
    ok.

no_upgrade_on_1_8_0_test() ->
    ?assertEqual([], upgrade_config([[{{node, node(), config_version},
                                       {1,8,0}}]])).

fuller_1_6_test_() ->
    {spawn,
     fun () ->
             Cfg = [[{directory, old_directory},
                     {{node, node(), isasl}, [{path, old_isasl}]},
                     {some_random, value},
                     {{node, node(), memcached},
                      [{dbdir, "dbdir"},
                       {bucket_engine, "old-be"},
                       {engines, "old-engines"}]},
                     {port_servers,
                      [{moxi, "moxi old something"},
                       {memcached, "memcached old something"}]},
                     {{node, node(), ns_log}, default_log}]],
             ets:new(path_config_override, [public, named_table, {read_concurrency, true}]),
             [ets:insert(path_config_override, {K, "."}) || K <- [path_config_tmpdir, path_config_datadir,
                                                                  path_config_bindir, path_config_libdir,
                                                                  path_config_etcdir]],
             Changes = upgrade_config(Cfg),
             ?assertMatch([{set, {node, _, config_version}, {1,7}}],
                          [X || {set, {node, N, config_version}, _} = X <- Changes, N =:= node()]),

             ?assertEqual([], Changes -- [X || {set, _, _} = X <- Changes]),

             DefaultConfig = default(),

             {directory, Dir} = lists:keyfind(directory, 1, DefaultConfig),

             ?assertEqual([{set, directory, Dir}],
                          [X || {set, directory, _} = X <- Changes]),

             {set, _, NewMemcached} = lists:keyfind({node, node(), memcached}, 2, Changes),
             ?assertEqual({dbdir, "dbdir"}, lists:keyfind(dbdir, 1, NewMemcached)),

             ?assertMatch({set, {node, Node, memcached},
                           [{?METADATA_VCLOCK, _VClock} | _]} when Node =:= node(),
                          lists:keyfind({node, node(), memcached}, 2, Changes)),
             ?assertMatch({set, {node, Node, isasl},
                           [{?METADATA_VCLOCK, _VClock} | _]} when Node =:= node(),
                          lists:keyfind({node, node(), isasl}, 2, Changes)),
             ?assertMatch({set, {node, Node, ns_log},
                           [{?METADATA_VCLOCK, _VClock} | _]} when Node =:= node(),
                          lists:keyfind({node, node(), ns_log}, 2, Changes))
     end}.

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
