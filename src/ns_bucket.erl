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
-module(ns_bucket).

-include("ns_common.hrl").
-include("ns_config.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([auth_type/1,
         bucket_nodes/1,
         bucket_type/1,
         replication_type/1,
         config_string/1,
         create_bucket/3,
         credentials/1,
         delete_bucket/1,
         delete_bucket_returning_config/1,
         failover_warnings/0,
         get_bucket/1,
         get_bucket_with_vclock/1,
         get_bucket_with_vclock/2,
         get_bucket/2,
         get_bucket_names/0,
         get_bucket_names/1,
         get_bucket_names/2,
         couchbase_bucket_exists/1,
         get_buckets/0,
         get_buckets/1,
         is_persistent/1,
         is_port_free/1,
         is_port_free/2,
         is_valid_bucket_name/1,
         json_map_from_config/2,
         json_map_with_full_config/3,
         live_bucket_nodes/1,
         live_bucket_nodes_from_config/1,
         map_to_replicas/1,
         replicated_vbuckets/3,
         maybe_get_bucket/2,
         moxi_port/1,
         name_conflict/1,
         name_conflict/2,
         names_conflict/2,
         node_locator/1,
         num_replicas/1,
         ram_quota/1,
         raw_ram_quota/1,
         sasl_password/1,
         set_bucket_config/2,
         set_fast_forward_map/2,
         set_map/2,
         set_map_opts/2,
         set_servers/2,
         filter_ready_buckets/1,
         update_bucket_props/2,
         update_bucket_props/3,
         node_bucket_names/1,
         node_bucket_names/2,
         node_bucket_names_of_type/2,
         node_bucket_names_of_type/3,
         all_node_vbuckets/1,
         update_vbucket_map_history/2,
         past_vbucket_maps/0,
         past_vbucket_maps/1,
         config_to_map_options/1,
         needs_upgrade_to_dcp/1,
         needs_rebalance/2,
         bucket_view_nodes/1,
         bucket_view_nodes/2,
         bucket_config_view_nodes/1,
         bucket_config_view_nodes/2]).


%%%===================================================================
%%% API
%%%===================================================================

%% @doc Configuration parameters to start up the bucket on a node.
config_string(BucketName) ->
    Config = ns_config:get(),
    BucketConfigs = ns_config:search_prop(Config, buckets, configs),
    BucketConfig = proplists:get_value(BucketName, BucketConfigs),
    Engines = ns_config:search_node_prop(Config, memcached, engines),
    MemQuota = proplists:get_value(ram_quota, BucketConfig),
    BucketType =  proplists:get_value(type, BucketConfig),
    EngineConfig = proplists:get_value(BucketType, Engines),
    Engine = proplists:get_value(engine, EngineConfig),
    BucketUUID = proplists:get_value(uuid, BucketConfig),
    StaticConfigString =
        proplists:get_value(
          static_config_string, BucketConfig,
          proplists:get_value(static_config_string, EngineConfig)),
    ExtraConfigString =
        proplists:get_value(
          extra_config_string, BucketConfig,
          proplists:get_value(extra_config_string, EngineConfig, "")),
    {DynamicConfigString, ExtraParams, ReturnDBDir} =
        case BucketType of
            membase ->
                {ok, DBSubDir} = ns_storage_conf:this_node_bucket_dbdir(BucketName),
                AccessLog = filename:join(DBSubDir, "access.log"),
                NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),
                NumThreads = proplists:get_value(num_threads, BucketConfig, 3),
                EvictionPolicy = proplists:get_value(eviction_policy, BucketConfig, value_only),
                %% MemQuota is our per-node bucket memory limit
                CFG =
                    io_lib:format(
                      "ht_size=~B;ht_locks=~B;"
                      "tap_noop_interval=~B;"
                      "max_size=~B;"
                      "tap_keepalive=~B;dbname=~s;"
                      "allow_data_loss_during_shutdown=true;"
                      "backend=couchdb;couch_bucket=~s;max_vbuckets=~B;"
                      "alog_path=~s;data_traffic_enabled=false;max_num_workers=~B;"
                      "uuid=~s;item_eviction_policy=~s",
                      [proplists:get_value(
                         ht_size, BucketConfig,
                         misc:getenv_int("MEMBASE_HT_SIZE", 3079)),
                       proplists:get_value(
                         ht_locks, BucketConfig,
                         misc:getenv_int("MEMBASE_HT_LOCKS", 47)),
                       proplists:get_value(
                         tap_noop_interval, BucketConfig,
                         misc:getenv_int("MEMBASE_TAP_NOOP_INTERVAL", 20)),
                       MemQuota,
                       %% Five minutes, should be enough time for
                       %% ebucketmigrator to restart.
                       proplists:get_value(
                         tap_keepalive, BucketConfig,
                         misc:getenv_int("MEMBASE_TAP_KEEPALIVE", 300)),
                       DBSubDir,
                       BucketName,
                       NumVBuckets,
                       AccessLog,
                       NumThreads,
                       BucketUUID,
                       EvictionPolicy]),
                {CFG, {MemQuota, DBSubDir, NumThreads, EvictionPolicy}, DBSubDir};
            memcached ->
                {io_lib:format("cache_size=~B;uuid=~s", [MemQuota, BucketUUID]),
                 MemQuota, undefined}
        end,
    ConfigString = lists:flatten([DynamicConfigString, $;, StaticConfigString,
                                  $;, ExtraConfigString]),
    {Engine, ConfigString, BucketType, ExtraParams, ReturnDBDir}.

%% @doc Return {Username, Password} for a bucket.
-spec credentials(nonempty_string()) ->
                         {nonempty_string(), string()}.
credentials(Bucket) ->
    {ok, BucketConfig} = get_bucket(Bucket),
    {Bucket, proplists:get_value(sasl_password, BucketConfig, "")}.

-spec couchbase_bucket_exists(binary()) -> boolean().
couchbase_bucket_exists(Bucket) ->
    case get_bucket(binary_to_list(Bucket)) of
        {ok, Config} ->
            case proplists:get_value(type, Config) of
                membase -> true;
                _ -> false
            end;
        not_present ->
            false
    end.

get_bucket(Bucket) ->
    get_bucket(Bucket, ns_config:latest_config_marker()).

get_bucket_with_vclock(Bucket, Config) ->
    {value, [{configs, AllBuckets}], BucketVC} = ns_config:search_with_vclock(Config, buckets),
    case lists:keyfind(Bucket, 1, AllBuckets) of
        {_, BucketConfig} ->
            {ok, BucketConfig, BucketVC};
        false ->
            not_present
    end.

get_bucket_with_vclock(Bucket) ->
    RV = ns_config:eval(
           fun (Cfg) ->
                   get_bucket_with_vclock(Bucket, Cfg)
           end),
    case RV of
        not_present ->
            RV;
        {ok, _, _} ->
            RV;
        _ ->
            erlang:error({get_bucket_failed, RV})
    end.


get_bucket(Bucket, Config) ->
    BucketConfigs = get_buckets(Config),
    case lists:keysearch(Bucket, 1, BucketConfigs) of
        {value, {_, BucketConfig}} ->
            {ok, BucketConfig};
        false -> not_present
    end.

maybe_get_bucket(BucketName, undefined) ->
    get_bucket(BucketName);
maybe_get_bucket(_, BucketConfig) ->
    {ok, BucketConfig}.

get_bucket_names() ->
    BucketConfigs = get_buckets(),
    proplists:get_keys(BucketConfigs).

get_bucket_names(Type) ->
    get_bucket_names(Type, get_buckets()).

get_bucket_names(Type, BucketConfigs) ->
    [Name || {Name, Config} <- BucketConfigs,
             proplists:get_value(type, Config) == Type].

get_buckets() ->
    get_buckets(ns_config:latest_config_marker()).

get_buckets(Config) ->
    ns_config:search_prop(Config, buckets, configs, []).

live_bucket_nodes(Bucket) ->
    {ok, BucketConfig} = get_bucket(Bucket),
    live_bucket_nodes_from_config(BucketConfig).

live_bucket_nodes_from_config(BucketConfig) ->
    Servers = proplists:get_value(servers, BucketConfig),
    LiveNodes = [node()|nodes()],
    [Node || Node <- Servers, lists:member(Node, LiveNodes) ].

%% returns bucket ram quota multiplied by number of nodes this bucket
%% resides on. I.e. gives amount of ram quota that will be used by
%% across the cluster for this bucket.
-spec ram_quota([{_,_}]) -> integer().
ram_quota(Bucket) ->
    case proplists:get_value(ram_quota, Bucket) of
        X when is_integer(X) ->
            X * length(proplists:get_value(servers, Bucket, []))
    end.

%% returns bucket ram quota for _single_ node. Each node will subtract
%% this much from it's node quota.
-spec raw_ram_quota([{_,_}]) -> integer().
raw_ram_quota(Bucket) ->
    case proplists:get_value(ram_quota, Bucket) of
        X when is_integer(X) ->
            X
    end.

-define(FS_HARD_NODES_NEEDED, 4).
-define(FS_FAILOVER_NEEDED, 3).
-define(FS_REBALANCE_NEEDED, 2).
-define(FS_SOFT_REBALANCE_NEEDED, 1).
-define(FS_OK, 0).

bucket_failover_safety(BucketConfig, ActiveNodes, LiveNodes) ->
    ReplicaNum = ns_bucket:num_replicas(BucketConfig),
    case ReplicaNum of
        %% if replica count for bucket is 0 we cannot failover at all
        0 -> {?FS_OK, ok};
        _ ->
            MinLiveCopies = min_live_copies(LiveNodes, BucketConfig),
            BucketNodes = proplists:get_value(servers, BucketConfig),
            BaseSafety =
                if
                    MinLiveCopies =:= undefined -> % janitor run pending
                        case LiveNodes of
                            [_,_|_] -> ?FS_OK;
                            _ -> ?FS_HARD_NODES_NEEDED
                        end;
                    MinLiveCopies =< 1 ->
                        %% we cannot failover without losing data
                        %% is some of chain nodes are down ?
                        DownBucketNodes = lists:any(fun (N) -> not lists:member(N, LiveNodes) end,
                                                    BucketNodes),
                        if
                            DownBucketNodes ->
                                %% yes. User should bring them back or failover/replace them (and possibly add more)
                                ?FS_FAILOVER_NEEDED;
                            %% Can we replace missing chain nodes with other live nodes ?
                            LiveNodes =/= [] andalso tl(LiveNodes) =/= [] -> % length(LiveNodes) > 1, but more efficent
                                %% we're generally fault tolerant, just not balanced enough
                                ?FS_REBALANCE_NEEDED;
                            true ->
                                %% we have one (or 0) of live nodes, need at least one more to be fault tolerant
                                ?FS_HARD_NODES_NEEDED
                        end;
                    true ->
                        case needs_rebalance(BucketConfig, ActiveNodes) of
                            true ->
                                ?FS_SOFT_REBALANCE_NEEDED;
                            false ->
                                ?FS_OK
                        end
                end,
            ExtraSafety =
                if
                    length(LiveNodes) =< ReplicaNum andalso BaseSafety =/= ?FS_HARD_NODES_NEEDED ->
                        %% if we don't have enough nodes to put all replicas on
                        softNodesNeeded;
                    true ->
                        ok
                end,
            {BaseSafety, ExtraSafety}
    end.

failover_safety_rec(?FS_HARD_NODES_NEEDED, _ExtraSafety, _, _ActiveNodes, _LiveNodes) ->
    {?FS_HARD_NODES_NEEDED, ok};
failover_safety_rec(BaseSafety, ExtraSafety, [], _ActiveNodes, _LiveNodes) ->
    {BaseSafety, ExtraSafety};
failover_safety_rec(BaseSafety, ExtraSafety, [BucketConfig | RestConfigs], ActiveNodes, LiveNodes) ->
    {ThisBaseSafety, ThisExtraSafety} = bucket_failover_safety(BucketConfig, ActiveNodes, LiveNodes),
    NewBaseSafety = case BaseSafety < ThisBaseSafety of
                        true -> ThisBaseSafety;
                        _ -> BaseSafety
                    end,
    NewExtraSafety = if ThisExtraSafety =:= softNodesNeeded
                        orelse ExtraSafety =:= softNodesNeeded ->
                             softNodesNeeded;
                        true ->
                             ok
                     end,
    failover_safety_rec(NewBaseSafety, NewExtraSafety,
                        RestConfigs, ActiveNodes, LiveNodes).

-spec failover_warnings() -> [failoverNeeded | rebalanceNeeded | hardNodesNeeded | softNodesNeeded].
failover_warnings() ->
    Config = ns_config:get(),

    ActiveNodes0 = ns_cluster_membership:active_nodes(Config),
    LiveNodes0 = ns_cluster_membership:actual_active_nodes(Config),
    ActiveNodes = ns_cluster_membership:filter_out_non_kv_nodes(ActiveNodes0),
    LiveNodes = ns_cluster_membership:filter_out_non_kv_nodes(LiveNodes0),
    {BaseSafety0, ExtraSafety}
        = failover_safety_rec(?FS_OK, ok,
                              [C || {_, C} <- get_buckets(Config),
                                    membase =:= bucket_type(C)],
                              ActiveNodes,
                              LiveNodes),
    BaseSafety = case BaseSafety0 of
                     ?FS_HARD_NODES_NEEDED -> hardNodesNeeded;
                     ?FS_FAILOVER_NEEDED -> failoverNeeded;
                     ?FS_REBALANCE_NEEDED -> rebalanceNeeded;
                     ?FS_SOFT_REBALANCE_NEEDED -> softRebalanceNeeded;
                     ?FS_OK -> ok
                 end,
    [S || S <- [BaseSafety, ExtraSafety], S =/= ok].

map_to_replicas(Map) ->
    lists:foldr(
      fun ({VBucket, [Master | Replicas]}, Acc) ->
              case Master of
                  undefined ->
                      Acc;
                  _ ->
                      [{Master, R, VBucket} || R <- Replicas, R =/= undefined] ++
                          Acc
              end
      end, [], misc:enumerate(Map, 0)).

%% returns _sorted_ list of vbuckets that are replicated from SrcNode
%% to DstNode according to given Map.
replicated_vbuckets(Map, SrcNode, DstNode) ->
    VBuckets = [V || {S, D, V} <- map_to_replicas(Map),
                     S =:= SrcNode, DstNode =:= D],
    lists:sort(VBuckets).

%% @doc Return the minimum number of live copies for all vbuckets.
-spec min_live_copies([node()], list()) -> non_neg_integer() | undefined.
min_live_copies(LiveNodes, Config) ->
    case proplists:get_value(map, Config) of
        undefined -> undefined;
        Map ->
            lists:foldl(
              fun (Chain, Min) ->
                      NumLiveCopies =
                          lists:foldl(
                            fun (Node, Acc) ->
                                    case lists:member(Node, LiveNodes) of
                                        true -> Acc + 1;
                                        false -> Acc
                                    end
                            end, 0, Chain),
                      erlang:min(Min, NumLiveCopies)
              end, length(hd(Map)), Map)
    end.

node_locator(BucketConfig) ->
    case proplists:get_value(type, BucketConfig) of
        membase ->
            vbucket;
        memcached ->
            ketama
    end.

-spec num_replicas([{_,_}]) -> integer().
num_replicas(Bucket) ->
    case proplists:get_value(num_replicas, Bucket) of
        X when is_integer(X) ->
            X
    end.

bucket_type(Bucket) ->
    proplists:get_value(type, Bucket).

auth_type(Bucket) ->
    proplists:get_value(auth_type, Bucket).

sasl_password(Bucket) ->
    proplists:get_value(sasl_password, Bucket, "").

moxi_port(Bucket) ->
    proplists:get_value(moxi_port, Bucket).

bucket_nodes(Bucket) ->
    proplists:get_value(servers, Bucket).

-spec replication_type([{_,_}]) -> bucket_replication_type().
replication_type(Bucket) ->
    proplists:get_value(repl_type, Bucket, tap).

-spec needs_upgrade_to_dcp([{_,_}]) -> boolean().
needs_upgrade_to_dcp(Bucket) ->
    DefaultReplType = get_default_repl_type(),
    case replication_type(Bucket) of
        dcp ->
            false;
        DefaultReplType ->
            false;
        _ ->
            true
    end.

json_map_from_config(LocalAddr, BucketConfig) ->
    Config = ns_config:get(),
    json_map_with_full_config(LocalAddr, BucketConfig, Config).

json_map_with_full_config(LocalAddr, BucketConfig, Config) ->
    NumReplicas = num_replicas(BucketConfig),
    EMap = proplists:get_value(map, BucketConfig, []),
    BucketNodes = proplists:get_value(servers, BucketConfig, []),
    ENodes = lists:delete(undefined, lists:usort(lists:append([BucketNodes |
                                                                EMap]))),
    Servers = lists:map(
                fun (ENode) ->
                        Port = ns_config:search_node_prop(ENode, Config,
                                                          memcached, port),
                        Host = case misc:node_name_host(ENode) of
                                   {_Name, "127.0.0.1"} -> LocalAddr;
                                   {_Name, H} -> H
                               end,
                        list_to_binary(Host ++ ":" ++ integer_to_list(Port))
                end, ENodes),
    {_, NodesToPositions0}
        = lists:foldl(fun (N, {Pos,Dict}) ->
                              {Pos+1, dict:store(N, Pos, Dict)}
                      end, {0, dict:new()}, ENodes),
    NodesToPositions = dict:store(undefined, -1, NodesToPositions0),
    Map = [[dict:fetch(N, NodesToPositions) || N <- Chain] || Chain <- EMap],
    FastForwardMapList =
        case proplists:get_value(fastForwardMap, BucketConfig) of
            undefined -> [];
            FFM ->
                [{vBucketMapForward,
                  [[dict:fetch(N, NodesToPositions) || N <- Chain]
                   || Chain <- FFM]}]
        end,
    {struct, [{hashAlgorithm, <<"CRC">>},
              {numReplicas, NumReplicas},
              {serverList, Servers},
              {vBucketMap, Map} |
              FastForwardMapList]}.

set_bucket_config(Bucket, NewConfig) ->
    update_bucket_config(Bucket, fun (_) -> NewConfig end).

%% Here's code snippet from bucket-engine.  We also disallow '.' &&
%% '..' which cause problems with browsers even when properly
%% escaped. See bug 953
%%
%% static bool has_valid_bucket_name(const char *n) {
%%     bool rv = strlen(n) > 0;
%%     for (; *n; n++) {
%%         rv &= isalpha(*n) || isdigit(*n) || *n == '.' || *n == '%' || *n == '_' || *n == '-';
%%     }
%%     return rv;
%% }
%%
%% Now we also disallow bucket names starting with '.'. It's because couchdb
%% creates (at least now) auxiliary directories which start with dot. We don't
%% want to conflict with them
is_valid_bucket_name([]) -> {error, empty};
is_valid_bucket_name([$. | _]) -> {error, starts_with_dot};
is_valid_bucket_name(BucketName) ->
    case is_valid_bucket_name_inner(BucketName) of
        {error, _} = X ->
            X;
        true ->
            Reserved =
                string:str(string:to_lower(BucketName), "_users.couch.") =:= 1 orelse
                string:str(string:to_lower(BucketName), "_replicator.couch.") =:= 1,
            case Reserved of
                true ->
                    {error, reserved};
                false ->
                    true
            end
    end.

is_valid_bucket_name_inner([Char | Rest]) ->
    case ($A =< Char andalso Char =< $Z)
        orelse ($a =< Char andalso Char =< $z)
        orelse ($0 =< Char andalso Char =< $9)
        orelse Char =:= $. orelse Char =:= $%
        orelse Char =:= $_ orelse Char =:= $- of
        true ->
            case Rest of
                [] -> true;
                _ -> is_valid_bucket_name_inner(Rest)
            end;
        _ -> {error, invalid}
    end.

is_not_a_bucket_port(BucketName, Port) ->
    UsedPorts = lists:filter(fun (undefined) -> false;
                                 (_) -> true
                             end,
                             [proplists:get_value(moxi_port, Config)
                              || {Name, Config} <- get_buckets(),
                                 Name /= BucketName]),
    not lists:member(Port, UsedPorts).

is_not_a_kernel_port(Port) ->
    Env = application:get_all_env(kernel),
    MinPort = case lists:keyfind(inet_dist_listen_min, 1, Env) of
                  false ->
                      1000000;
                  {_, P} ->
                      P
              end,
    MaxPort = case lists:keyfind(inet_dist_listen_max, 1, Env) of
                  false ->
                      0;
                  {_, P1} ->
                      P1
              end,
    Port < MinPort orelse Port > MaxPort.

is_port_free(Port) ->
    is_port_free([], Port).

is_port_free(BucketName, Port) ->
    is_port_free(BucketName, Port, ns_config:get()).

is_port_free(BucketName, Port, Config) ->
    true = (Port /= undefined),
    TakenWebPort = case BucketName of
                       [] ->
                           0;
                       _ ->
                           proplists:get_value(port, menelaus_web:webconfig(Config))
                   end,
    UpstreamProxyPort = ns_config:search(Config, {node, node(), ssl_proxy_upstream_port}, undefined),
    DownstreamProxyPort = ns_config:search(Config, {node, node(), ssl_proxy_downstream_port}, undefined),

    SSLCapiPort = ns_config:search(Config, {node, node(), ssl_capi_port}, undefined),
    SSLRestPort = ns_config:search(Config, {node, node(), ssl_rest_port}, undefined),

    Port =/= ns_config:search_node_prop(Config, memcached, port)
        andalso Port =/= ns_config:search_node_prop(Config, memcached, dedicated_port)
        andalso Port =/= ns_config:search_node_prop(Config, memcached, ssl_port)
        andalso Port =/= ns_config:search_node_prop(Config, moxi, port)
        andalso Port =/= capi_utils:get_capi_port(node(), Config)
        andalso Port =/= TakenWebPort
        andalso Port =/= 4369 %% default epmd port
        andalso is_not_a_bucket_port(BucketName, Port)
        andalso is_not_a_kernel_port(Port)
        andalso Port =/= SSLCapiPort
        andalso Port =/= SSLRestPort
        andalso Port =/= UpstreamProxyPort
        andalso Port =/= DownstreamProxyPort.

validate_bucket_config(BucketName, NewConfig) ->
    case is_valid_bucket_name(BucketName) of
        true ->
            Port = proplists:get_value(moxi_port, NewConfig),
            case Port =:= undefined orelse is_port_free(BucketName, Port) of
                false ->
                    {error, {port_conflict, Port}};
                true ->
                    ok
            end;
        {error, _} ->
            {error, {invalid_bucket_name, BucketName}}
    end.

new_bucket_default_params(membase) ->
    NumVBuckets = case ns_config:search(couchbase_num_vbuckets_default) of
                      false -> misc:getenv_int("COUCHBASE_NUM_VBUCKETS", 1024);
                      {value, X} -> X
                  end,
    [{type, membase},
     {num_vbuckets, NumVBuckets},
     {num_replicas, 1},
     {ram_quota, 0},
     {replication_topology, star},
     {servers, []}];
new_bucket_default_params(memcached) ->
    Nodes = ns_cluster_membership:filter_out_non_kv_nodes(ns_cluster_membership:active_nodes()),
    [{type, memcached},
     {num_vbuckets, 0},
     {num_replicas, 0},
     {servers, Nodes},
     {map, []},
     {ram_quota, 0}].

cleanup_bucket_props(Props) ->
    case proplists:get_value(auth_type, Props) of
        sasl -> lists:keydelete(moxi_port, 1, Props);
        none -> lists:keydelete(sasl_password, 1, Props)
    end.

get_default_repl_type() ->
    case cluster_compat_mode:is_cluster_30() of
        false ->
            tap;
        _ ->
            case os:getenv("COUCHBASE_REPL_TYPE") of
                "tap" ->
                    tap;
                "upr" ->
                    dcp;
                "dcp" ->
                    dcp;
                _ ->
                    dcp
            end
    end.

create_bucket(BucketType, BucketName, NewConfig) ->
    case validate_bucket_config(BucketName, NewConfig) of
        ok ->
            MergedConfig0 =
                misc:update_proplist(new_bucket_default_params(BucketType),
                                     NewConfig),
            MergedConfig1 = cleanup_bucket_props(MergedConfig0),
            BucketUUID = couch_uuids:random(),
            MergedConfig = [{repl_type, get_default_repl_type()} |
                            [{uuid, BucketUUID} | MergedConfig1]],
            ns_config:update_sub_key(
              buckets, configs,
              fun (List) ->
                      case lists:keyfind(BucketName, 1, List) of
                          false -> ok;
                          Tuple ->
                              exit({already_exists, Tuple})
                      end,
                      [{BucketName, MergedConfig} | List]
              end),
            %% The janitor will handle creating the map.
            ok;
        E -> E
    end.

-spec delete_bucket(bucket_name()) -> ok | {exit, {not_found, bucket_name()}, any()}.
delete_bucket(BucketName) ->
    RV = ns_config:update_sub_key(buckets, configs,
                                  fun (List) ->
                                          case lists:keyfind(BucketName, 1, List) of
                                              false -> exit({not_found, BucketName});
                                              Tuple ->
                                                  lists:delete(Tuple, List)
                                          end
                                  end),
    case RV of
        ok -> ok;
        {exit, {not_found, _}, _} -> ok
    end,
    RV.

-spec delete_bucket_returning_config(bucket_name()) ->
                                            {ok, BucketConfig :: list()} |
                                            {exit, {not_found, bucket_name()}, any()}.
delete_bucket_returning_config(BucketName) ->
    Ref = make_ref(),
    Process = self(),
    RV = ns_config:update_sub_key(buckets, configs,
                                  fun (List) ->
                                          case lists:keyfind(BucketName, 1, List) of
                                              false -> exit({not_found, BucketName});
                                              {_, BucketConfig} = Tuple ->
                                                  Process ! {Ref, BucketConfig},
                                                  lists:delete(Tuple, List)
                                          end
                                  end),
    case RV of
        ok ->
            receive
                {Ref, BucketConfig} ->
                    {ok, BucketConfig}
            after 0 ->
                    exit(this_cannot_happen)
            end;
        {exit, {not_found, _}, _} ->
            RV
    end.

filter_ready_buckets(BucketInfos) ->
    lists:filter(fun ({_Name, PList}) ->
                         case proplists:get_value(servers, PList, []) of
                             [_|_] = List ->
                                 lists:member(node(), List);
                             _ -> false
                         end
                 end, BucketInfos).

%% Updates properties of bucket of given name and type.  Check of type
%% protects us from type change races in certain cases.
%%
%% If bucket with given name exists, but with different type, we
%% should return {exit, {not_found, _}, _}
update_bucket_props(Type, BucketName, Props) ->
    case lists:member(BucketName, get_bucket_names(Type)) of
        true ->
            update_bucket_props(BucketName, Props);
        false ->
            {exit, {not_found, BucketName}, []}
    end.

update_bucket_props(BucketName, Props) ->
    ns_config:update_sub_key(
      buckets, configs,
      fun (List) ->
              RV = misc:key_update(
                     BucketName, List,
                     fun (OldProps) ->
                             NewProps = lists:foldl(
                                          fun ({K, _V} = Tuple, Acc) ->
                                                  [Tuple | lists:keydelete(K, 1, Acc)]
                                          end, OldProps, Props),
                             cleanup_bucket_props(NewProps)
                     end),
              case RV of
                  false -> exit({not_found, BucketName});
                  _ -> ok
              end,
              RV
      end).

set_fast_forward_map(Bucket, Map) ->
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              OldMap = proplists:get_value(fastForwardMap, OldConfig, []),
              master_activity_events:note_set_ff_map(Bucket, Map, OldMap),
              lists:keystore(fastForwardMap, 1, OldConfig,
                             {fastForwardMap, Map})
      end).


set_map(Bucket, Map) ->
    true = mb_map:is_valid(Map),
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              OldMap = proplists:get_value(map, OldConfig, []),
              master_activity_events:note_set_map(Bucket, Map, OldMap),
              lists:keystore(map, 1, OldConfig, {map, Map})
      end).

set_map_opts(Bucket, Opts) ->
    OptsHash = erlang:phash2(Opts),
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keystore(map_opts_hash, 1, OldConfig, {map_opts_hash, OptsHash})
      end).

set_servers(Bucket, Servers) ->
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keystore(servers, 1, OldConfig, {servers, Servers})
      end).

% Update the bucket config atomically.
update_bucket_config(Bucket, Fun) ->
    ok = ns_config:update_key(
           buckets,
           fun (List) ->
                   Buckets = proplists:get_value(configs, List, []),
                   OldConfig = proplists:get_value(Bucket, Buckets),
                   NewConfig = Fun(OldConfig),
                   NewBuckets = lists:keyreplace(Bucket, 1, Buckets, {Bucket, NewConfig}),
                   lists:keyreplace(configs, 1, List, {configs, NewBuckets})
           end).

%% returns true iff bucket with given names is membase bucket.
is_persistent(BucketName) ->
    {ok, BucketConfig} = get_bucket(BucketName),
    bucket_type(BucketConfig) =:= membase.

names_conflict(BucketNameA, BucketNameB) ->
    string:to_lower(BucketNameA) =:= string:to_lower(BucketNameB).

%% @doc Check if a bucket name exists in the list. Case insensitive.
name_conflict(BucketName, ListOfBuckets) ->
    BucketNameLower = string:to_lower(BucketName),
    lists:any(fun ({Name, _}) -> BucketNameLower == string:to_lower(Name) end,
              ListOfBuckets).

%% @doc Check if a bucket exists. Case insensitive.
name_conflict(BucketName) ->
    name_conflict(BucketName, get_buckets()).

node_bucket_names(Node, BucketsConfigs) ->
    [B || {B, C} <- BucketsConfigs,
          lists:member(Node, proplists:get_value(servers, C, []))].

node_bucket_names(Node) ->
    node_bucket_names(Node, get_buckets()).

node_bucket_names_of_type(Node, Type) ->
    node_bucket_names_of_type(Node, Type, get_buckets()).

node_bucket_names_of_type(Node, Type, BucketConfigs) ->
    [B || {B, C} <- BucketConfigs,
          lists:member(Node, proplists:get_value(servers, C, [])),
          bucket_type(C) =:= Type].


%% All the vbuckets (active or replica) on a node
-spec all_node_vbuckets(term()) -> list(integer()).
all_node_vbuckets(BucketConfig) ->
    VBucketMap = couch_util:get_value(map, BucketConfig, []),
    Node = node(),
    [Ordinal-1 ||
        {Ordinal, VBuckets} <- misc:enumerate(VBucketMap),
        lists:member(Node, VBuckets)].

config_to_map_options(Config) ->
    [{max_slaves, proplists:get_value(max_slaves, Config, 10)},
     {replication_topology, proplists:get_value(replication_topology, Config, star)}].

update_vbucket_map_history(Map, SanifiedOptions) ->
    History = past_vbucket_maps(),
    NewEntry = {Map, SanifiedOptions},
    History2 = case lists:member(NewEntry, History) of
                   true ->
                       History;
                   false ->
                       History1 = [NewEntry | History],
                       case length(History1) > ?VBMAP_HISTORY_SIZE of
                           true -> lists:sublist(History1, ?VBMAP_HISTORY_SIZE);
                           false -> History1
                       end
               end,
    ns_config:set(vbucket_map_history, History2).

past_vbucket_maps() ->
    past_vbucket_maps(ns_config:latest_config_marker()).

past_vbucket_maps(Config) ->
    case ns_config:search(Config, vbucket_map_history) of
        {value, V} ->
            lists:map(
              fun ({Map, Options} = MapOptions) ->
                      case proplists:get_value(replication_topology, Options) of
                          undefined ->
                              {Map, [{replication_topology, chain} | Options]};
                          _ ->
                              MapOptions
                      end
              end, V);
        false -> []
    end.

needs_rebalance(BucketConfig, Nodes) ->
    Servers = proplists:get_value(servers, BucketConfig, []),
    case proplists:get_value(type, BucketConfig) of
        membase ->
            case Servers of
                [] ->
                    false;
                _ ->
                    Map = proplists:get_value(map, BucketConfig),
                    Map =:= undefined orelse
                        ns_bucket:needs_upgrade_to_dcp(BucketConfig) orelse
                        lists:sort(Nodes) =/= lists:sort(Servers) orelse
                        ns_rebalancer:map_options_changed(BucketConfig) orelse
                        (ns_rebalancer:unbalanced(Map, BucketConfig) andalso
                         not is_compatible_past_map(Nodes, BucketConfig, Map))
            end;
        memcached ->
            lists:sort(Nodes) =/= lists:sort(Servers)
    end.

is_compatible_past_map(Nodes, BucketConfig, Map) ->
    History = ns_bucket:past_vbucket_maps(),
    MapOpts = ns_rebalancer:generate_vbucket_map_options(Nodes, BucketConfig),
    Matching = mb_map:find_matching_past_maps(Nodes, Map,
                                              MapOpts, History, [trivial]),

    lists:member(Map, Matching).

bucket_view_nodes(Bucket) ->
    bucket_view_nodes(Bucket, ns_config:latest_config_marker()).

bucket_view_nodes(Bucket, Config) ->
    case ns_bucket:get_bucket(Bucket, Config) of
        {ok, BucketConfig} ->
            bucket_config_view_nodes(BucketConfig, Config);
        not_present ->
            []
    end.

bucket_config_view_nodes(BucketConfig) ->
    bucket_config_view_nodes(BucketConfig, ns_config:latest_config_marker()).

bucket_config_view_nodes(BucketConfig, Config) ->
    case bucket_type(BucketConfig) of
        membase ->
            BucketNodes = ns_bucket:bucket_nodes(BucketConfig),
            NonKVNodes = ns_cluster_membership:non_kv_active_nodes(Config),
            lists:usort(NonKVNodes ++ BucketNodes);
        memcached ->
            []
    end.

%%
%% Internal functions
%%

%%
%% Tests
%%

min_live_copies_test() ->
    ?assertEqual(min_live_copies([node1], []), undefined),
    ?assertEqual(min_live_copies([node1], [{map, undefined}]), undefined),
    Map1 = [[node1, node2], [node2, node1]],
    ?assertEqual(2, min_live_copies([node1, node2], [{map, Map1}])),
    ?assertEqual(1, min_live_copies([node1], [{map, Map1}])),
    ?assertEqual(0, min_live_copies([node3], [{map, Map1}])),
    Map2 = [[undefined, node2], [node2, node1]],
    ?assertEqual(1, min_live_copies([node1, node2], [{map, Map2}])),
    ?assertEqual(0, min_live_copies([node1, node3], [{map, Map2}])).
