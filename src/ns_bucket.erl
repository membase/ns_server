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
         config_string/1,
         create_bucket/3,
         credentials/1,
         delete_bucket/1,
         delete_bucket_returning_config/1,
         failover_warnings/0,
         get_bucket/1,
         get_bucket_light/1,
         get_bucket/2,
         get_bucket_names/0,
         get_bucket_names/1,
         couchbase_bucket_exists/1,
         get_buckets/0,
         get_buckets/1,
         is_open_proxy_port/2,
         is_persistent/1,
         is_port_free/2,
         is_valid_bucket_name/1,
         json_map_from_config/2,
         live_bucket_nodes/1,
         map_to_replicas/1,
         replicated_vbuckets/3,
         maybe_get_bucket/2,
         moxi_port/1,
         name_conflict/1,
         names_conflict/2,
         node_locator/1,
         num_replicas/1,
         ram_quota/1,
         raw_ram_quota/1,
         sasl_password/1,
         set_bucket_config/2,
         set_fast_forward_map/2,
         set_map/2,
         set_servers/2,
         filter_ready_buckets/1,
         update_bucket_props/2,
         update_bucket_props/3,
         node_bucket_names/1,
         node_bucket_names/2,
         node_bucket_names_of_type/2,
         all_node_vbuckets/1,
         update_vbucket_map_history/2,
         past_vbucket_maps/0,
         config_to_map_options/1]).


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
                CouchPort = ns_config:search_node_prop(Config, memcached, mccouch_port, 11213),
                AccessLog = filename:join(DBSubDir, "access.log"),
                NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),
                NumThreads = proplists:get_value(num_threads, BucketConfig, 2),
                %% MemQuota is our per-node bucket memory limit
                CFG =
                    io_lib:format(
                      "ht_size=~B;ht_locks=~B;"
                      "tap_noop_interval=~B;max_txn_size=~B;"
                      "max_size=~B;"
                      "tap_keepalive=~B;dbname=~s;"
                      "allow_data_loss_during_shutdown=true;"
                      "backend=couchdb;couch_bucket=~s;couch_port=~B;max_vbuckets=~B;"
                      "alog_path=~s;data_traffic_enabled=false;max_num_shards=~B",
                      [proplists:get_value(
                         ht_size, BucketConfig,
                         misc:getenv_int("MEMBASE_HT_SIZE", 3079)),
                       proplists:get_value(
                         ht_locks, BucketConfig,
                         misc:getenv_int("MEMBASE_HT_LOCKS", 5)),
                       proplists:get_value(
                         tap_noop_interval, BucketConfig,
                         misc:getenv_int("MEMBASE_TAP_NOOP_INTERVAL", 20)),
                       proplists:get_value(
                         max_txn_size, BucketConfig,
                         misc:getenv_int("MEMBASE_MAX_TXN_SIZE", 10000)),
                       MemQuota,
                       %% Five minutes, should be enough time for
                       %% ebucketmigrator to restart.
                       proplists:get_value(
                         tap_keepalive, BucketConfig,
                         misc:getenv_int("MEMBASE_TAP_KEEPALIVE", 300)),
                       DBSubDir,
                       BucketName,
                       CouchPort,
                       NumVBuckets,
                       AccessLog,
                       NumThreads]),
                {CFG, {MemQuota, DBSubDir, NumThreads}, DBSubDir};
            memcached ->
                {io_lib:format("cache_size=~B", [MemQuota]),
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
    RV = ns_config:eval(
           fun (#config{dynamic=[PList]}) ->
                   {_, V} = lists:keyfind(buckets, 1, PList),
                   BucketsPList = case V of
                                      [{'_vclock', _}, {configs, X}] -> X;
                                      [{configs, X}] -> X
                                  end,
                   case lists:keyfind(Bucket, 1, BucketsPList) of
                       false -> not_present;
                       {_, BucketConfig} ->
                           {ok, BucketConfig}
                   end
           end),
    case RV of
        not_present ->
            RV;
        {ok, _} ->
            RV;
        _ ->
            erlang:error({get_bucket_failed, RV})
    end.

get_bucket_light(Bucket) ->
    RV = ns_config:eval(
           fun (#config{dynamic=[PList]}) ->
                   {_, V} = lists:keyfind(buckets, 1, PList),
                   BucketsPList = case V of
                                      [{'_vclock', _}, {configs, X}] -> X;
                                      [{configs, X}] -> X
                                  end,
                   case lists:keyfind(Bucket, 1, BucketsPList) of
                       false -> not_present;
                       {_, BucketConfig} ->
                           {ok, lists:keydelete(map, 1, BucketConfig)}
                   end
           end),
    case RV of
        not_present ->
            RV;
        {ok, _} ->
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
    [Name || {Name, Config} <- get_buckets(),
             proplists:get_value(type, Config) == Type].

get_buckets() ->
    get_buckets(ns_config:get()).

get_buckets(Config) ->
    ns_config:search_prop(Config, buckets, configs, []).

live_bucket_nodes(Bucket) ->
    {ok, BucketConfig} = get_bucket(Bucket),
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

bucket_failover_safety(BucketConfig, LiveNodes) ->
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
                    MinLiveCopies =:= undefined orelse MinLiveCopies =< 1 ->
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
                        case ns_rebalancer:unbalanced(proplists:get_value(map, BucketConfig),
                                                      proplists:get_value(servers, BucketConfig)) of
                            true ->
                                ?FS_SOFT_REBALANCE_NEEDED;
                            _ ->
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

failover_safety_rec(?FS_HARD_NODES_NEEDED, _ExtraSafety, _, _LiveNodes) -> {?FS_HARD_NODES_NEEDED, ok};
failover_safety_rec(BaseSafety, ExtraSafety, [], _LiveNodes) -> {BaseSafety, ExtraSafety};
failover_safety_rec(BaseSafety, ExtraSafety, [BucketConfig | RestConfigs], LiveNodes) ->
    {ThisBaseSafety, ThisExtraSafety} = bucket_failover_safety(BucketConfig, LiveNodes),
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
                        RestConfigs, LiveNodes).

-spec failover_warnings() -> [failoverNeeded | rebalanceNeeded | hardNodesNeeded | softNodesNeeded].
failover_warnings() ->
    LiveNodes = ns_cluster_membership:actual_active_nodes(),
    {BaseSafety0, ExtraSafety}
        = failover_safety_rec(?FS_OK, ok,
                              [C || {_, C} <- get_buckets(),
                                    membase =:= bucket_type(C)],
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
    map_to_replicas(Map, 0, []).

map_to_replicas([], _, Replicas) ->
    lists:append(Replicas);
map_to_replicas([Chain|Rest], V, Replicas) ->
    Pairs = [{Src, Dst, V}||{Src, Dst} <- misc:pairs(Chain),
                            Src /= undefined andalso Dst /= undefined],
    map_to_replicas(Rest, V+1, [Pairs|Replicas]).

%% returns _sorted_ list of vbuckets that are replicated from SrcNode
%% to DstNode according to given Map.
replicated_vbuckets(Map, SrcNode, DstNode) ->
    replicated_vbuckets_rec(Map, SrcNode, DstNode, 0).

replicated_vbuckets_rec([], _SrcNode, _DstNode, _Idx) -> [];
replicated_vbuckets_rec([Chain | RestChains], SrcNode, DstNode, Idx) ->
    RestResult = replicated_vbuckets_rec(RestChains, SrcNode, DstNode, Idx+1),
    case replicated_in_chain(Chain, SrcNode, DstNode) of
        true -> [Idx | RestResult];
        false -> RestResult
    end.

replicated_in_chain([SrcNode, DstNode | _], SrcNode, DstNode) ->
    true;
replicated_in_chain([_ | Rest], SrcNode, DstNode) ->
    replicated_in_chain(Rest, SrcNode, DstNode);
replicated_in_chain([], _SrcNode, _DstNode) ->
    false.

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

json_map_from_config(LocalAddr, BucketConfig) ->
    NumReplicas = num_replicas(BucketConfig),
    Config = ns_config:get(),
    NumReplicas = proplists:get_value(num_replicas, BucketConfig),
    EMap = proplists:get_value(map, BucketConfig, []),
    BucketNodes = proplists:get_value(servers, BucketConfig, []),
    ENodes0 = lists:delete(undefined, lists:usort(lists:append([BucketNodes |
                                                                EMap]))),
    ENodes = case lists:member(node(), ENodes0) of
                 true -> [node() | lists:delete(node(), ENodes0)];
                 false -> ENodes0
             end,
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
is_valid_bucket_name([]) -> false;
is_valid_bucket_name(".") -> false;
is_valid_bucket_name("..") -> false;
is_valid_bucket_name([$. | _]) -> false;
is_valid_bucket_name(BucketName) ->
    is_valid_bucket_name_inner(BucketName).

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
        _ -> false
    end.

is_open_proxy_port(BucketName, Port) ->
    UsedPorts = lists:filter(fun (undefined) -> false;
                                 (_) -> true
                             end,
                             [proplists:get_value(moxi_port, Config)
                              || {Name, Config} <- get_buckets(),
                                 Name /= BucketName]),
    not lists:member(Port, UsedPorts).

is_port_free(BucketName, Port) ->
    is_port_free(BucketName, Port, ns_config:get()).

is_port_free(BucketName, Port, Config) ->
    Port =/= ns_config:search_node_prop(Config, memcached, port)
        andalso Port =/= ns_config:search_node_prop(Config, memcached, dedicated_port)
        andalso Port =/= ns_config:search_node_prop(Config, moxi, port)
        andalso Port =/= ns_config:search_node_prop(Config, memcached, mccouch_port, 11213)
        andalso Port =/= capi_utils:get_capi_port(node(), Config)
        andalso Port =/= proplists:get_value(port, menelaus_web:webconfig(Config))
        andalso is_open_proxy_port(BucketName, Port).

validate_bucket_config(BucketName, NewConfig) ->
    case is_valid_bucket_name(BucketName) of
        true ->
            Port = proplists:get_value(moxi_port, NewConfig),
            case is_port_free(BucketName, Port) of
                false ->
                    {error, {port_conflict, Port}};
                true ->
                    ok
            end;
        false ->
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
     {servers, []}];
new_bucket_default_params(memcached) ->
    [{type, memcached},
     {num_vbuckets, 0},
     {num_replicas, 0},
     {servers, ns_cluster_membership:active_nodes()},
     {map, []},
     {ram_quota, 0}].

cleanup_bucket_props(Props) ->
    case proplists:get_value(auth_type, Props) of
        sasl -> lists:keydelete(moxi_port, 1, Props);
        none -> lists:keydelete(sasl_password, 1, Props)
    end.

create_bucket(BucketType, BucketName, NewConfig) ->
    case validate_bucket_config(BucketName, NewConfig) of
        ok ->
            MergedConfig0 =
                misc:update_proplist(new_bucket_default_params(BucketType),
                                     NewConfig),
            MergedConfig1 = cleanup_bucket_props(MergedConfig0),
            BucketUUID = couch_uuids:random(),
            MergedConfig = [{uuid, BucketUUID} | MergedConfig1],
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

%% @doc Check if a bucket exists. Case insensitive.
name_conflict(BucketName) ->
    BucketNameLower = string:to_lower(BucketName),
    lists:any(fun ({Name, _}) -> BucketNameLower == string:to_lower(Name) end,
              get_buckets()).

node_bucket_names(Node, BucketsConfigs) ->
    [B || {B, C} <- BucketsConfigs,
          lists:member(Node, proplists:get_value(servers, C, []))].

node_bucket_names(Node) ->
    node_bucket_names(Node, get_buckets()).

node_bucket_names_of_type(Node, Type) ->
    [B || {B, C} <- get_buckets(),
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
    [{max_slaves, proplists:get_value(max_slaves, Config, 10)}].

update_vbucket_map_history(Map, Options) ->
    History = past_vbucket_maps(),
    SanifiedOptions = lists:ukeysort(1, lists:keydelete(maps_history, 1, Options)),
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
    case ns_config:search(vbucket_map_history) of
        {value, V} -> V;
        false -> []
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
