%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
%% @doc This service maintains public ETS table that's caching
%% json-inified bucket infos. See vbucket_map_mirror module for
%% explanation how this works.
-module(bucket_info_cache).
-include("ns_common.hrl").

-export([start_link/0,
         terse_bucket_info/1,
         terse_bucket_info_with_local_addr/2]).

-export([build_node_services/0]).

-export([build_services/3]).

%% for diagnostics
-export([submit_full_reset/0]).

%% NOTE: we're doing global replace of this string. So it must not
%% need any JSON escaping and it must not otherwise occur in terse
%% bucket info
-define(LOCALHOST_MARKER_STRING, "$HOST").

start_link() ->
    work_queue:start_link(bucket_info_cache, fun cache_init/0).

cache_init() ->
    {ok, _} = gen_event:start_link({local, bucket_info_cache_invalidations}),
    ets:new(bucket_info_cache, [set, named_table]),
    ets:new(bucket_info_cache_buckets, [ordered_set, named_table]),
    Self = self(),
    ns_pubsub:subscribe_link(ns_config_events, fun cleaner_loop/2, Self),
    {value, [{configs, NewBuckets}]} = ns_config:search(buckets),
    submit_new_buckets(Self, NewBuckets),
    submit_full_reset().

cleaner_loop({buckets, [{configs, NewBuckets}]}, Parent) ->
    submit_new_buckets(Parent, NewBuckets),
    Parent;
cleaner_loop({{_, _, capi_port}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{_, _, ssl_capi_port}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{_, _, ssl_rest_port}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{_, _, rest}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({rest, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{node, _, memcached}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{node, _, moxi}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{node, _, membership}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({cluster_compat_version, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop(_, Cleaner) ->
    Cleaner.

submit_new_buckets(Pid, Buckets0) ->
    work_queue:submit_work(
      Pid,
      fun () ->
              Buckets = lists:sort(Buckets0),
              BucketNames = compute_buckets_to_invalidate(Buckets),
              [begin
                   ets:delete(bucket_info_cache, Name),
                   ets:delete(bucket_info_cache_buckets, Name)
               end || Name <- BucketNames],
              [gen_event:notify(bucket_info_cache_invalidations, Name) || Name <- BucketNames],
              ok
      end).

compute_buckets_to_invalidate(Buckets) ->
    CachedBuckets = ets:tab2list(bucket_info_cache_buckets),
    Inv = ordsets:subtract(CachedBuckets, Buckets),
    [BucketName || {BucketName, _} <- Inv].

submit_full_reset() ->
    work_queue:submit_work(
      bucket_info_cache,
      fun () ->
              ets:delete_all_objects(bucket_info_cache),
              ets:delete_all_objects(bucket_info_cache_buckets),
              gen_event:notify(bucket_info_cache_invalidations, '*')
      end).

build_ports(Node, Config) ->
    [{proxy, ns_config:search_node_prop(Node, Config, moxi, port)},
     {direct, ns_config:search_node_prop(Node, Config, memcached, port)}].

build_services(Node, Config, EnabledServices) ->
    SSLPorts = lists:append([case ns_config:search_node(Node, Config, ConfigKey) of
                                 {value, Value} when Value =/= undefined -> [{JKey, Value}];
                                 _ -> []
                             end || {ConfigKey, JKey} <- [{ssl_capi_port, capiSSL},
                                                          {ssl_rest_port, mgmtSSL}]]),
    OptServices =
        [case S of
             kv ->
                 KVSSL = case ns_config:search_node_prop(Node, Config, memcached, ssl_port) of
                             undefined ->
                                 [];
                             SslPort ->
                                 [{kvSSL, SslPort}]
                         end,
                 KVProj = case ns_config:search(Config, {node, Node, projector_port}, undefined) of
                              undefined ->
                                  KVSSL;
                              ProjPort ->
                                  [{projector, ProjPort} | KVSSL]
                          end,
                 [{kv ,ns_config:search_node_prop(Node, Config, memcached, port)}
                  | KVProj];
             moxi ->
                 [{moxi, ns_config:search_node_prop(Node, Config, moxi, port)}];
             n1ql ->
                 [{n1ql, ns_config:search(Config, {node, Node, query_port}, undefined)}];
             index ->
                 [
                  {indexAdmin, ns_config:search(Config, {node, Node, indexer_admin_port}, undefined)},
                  {indexScan, ns_config:search(Config, {node, Node, indexer_scan_port}, undefined)},
                  {indexStreamInit, ns_config:search(Config, {node, Node, indexer_stinit_port}, undefined)},
                  {indexStreamCatchup, ns_config:search(Config, {node, Node, indexer_stcatchup_port}, undefined)},
                  {indexStreamMaint, ns_config:search(Config, {node, Node, indexer_stmaint_port}, undefined)}
                 ]
         end || S <- EnabledServices],
    {value, CapiPort} = ns_config:search_node(Node, Config, capi_port),
    [{mgmt, misc:node_rest_port(Config, Node)},
     {capi, CapiPort}
     | lists:append([SSLPorts | OptServices])].

maybe_build_ext_hostname(Node) ->
    case misc:node_name_host(Node) of
        {_, "127.0.0.1"} -> [];
        {_, H} -> [{hostname, list_to_binary(H)}]
    end.

build_nodes_ext([] = _Nodes, _Config, NodesExtAcc) ->
    lists:reverse(NodesExtAcc);
build_nodes_ext([Node | RestNodes], Config, NodesExtAcc) ->
    Services = ns_cluster_membership:node_services(Config, Node),
    NI1 = maybe_build_ext_hostname(Node),
    NI2 = case Node =:= node() of
              true ->
                  [{'thisNode', true} | NI1];
              _ ->
                  NI1
          end,
    NodeInfo = {[{services, {build_services(Node, Config, Services)}} | NI2]},
    build_nodes_ext(RestNodes, Config,
                    [NodeInfo | NodesExtAcc]).

do_compute_bucket_info(Bucket, Config) ->
    case ns_bucket:get_bucket_with_vclock(Bucket, Config) of
        {ok, BucketConfig, BucketVC} ->
            compute_bucket_info_with_config(Bucket, Config, BucketConfig, BucketVC);
        not_present ->
            not_present
    end.

compute_bucket_info_with_config(Bucket, Config, BucketConfig, BucketVC) ->
    {_, Servers0} = lists:keyfind(servers, 1, BucketConfig),

    %% we do sorting to make nodes list match order of servers inside vBucketServerMap
    Servers = lists:sort(Servers0),
    BucketUUID = proplists:get_value(uuid, BucketConfig),

    NIs = [{[{couchApiBase, capi_utils:capi_bucket_url_bin(Node, Bucket, BucketUUID, ?LOCALHOST_MARKER_STRING)},
             {hostname, list_to_binary(menelaus_web:build_node_hostname(Config, Node, ?LOCALHOST_MARKER_STRING))},
             {ports, {build_ports(Node, Config)}}]}
           || Node <- Servers],

    AllServers = Servers ++ ordsets:subtract(ns_cluster_membership:active_nodes(Config), Servers),
    NEIs = build_nodes_ext(AllServers, Config, []),

    {_, UUID} = lists:keyfind(uuid, 1, BucketConfig),

    BucketBin = list_to_binary(Bucket),

    Caps = menelaus_web_buckets:build_bucket_capabilities(BucketConfig),

    MaybeVBMap = case lists:keyfind(type, 1, BucketConfig) of
                     {_, memcached} ->
                         Caps;
                     _ ->
                         {struct, VBMap} = ns_bucket:json_map_with_full_config(?LOCALHOST_MARKER_STRING, BucketConfig, Config),
                         [{ddocs, {[{uri, <<"/pools/default/buckets/", BucketBin/binary, "/ddocs">>}]}},
                          {vBucketServerMap, {VBMap}}
                         | Caps]
                 end,

    %% NOTE: that we're reading compat mode not from config snapshot
    %% we're given. So we can serve older config with newer compat
    %% mode. That should be ok under our assumption that compat mode
    %% never decreases.
    %%
    %% We're computing rev using config's global rev which allows us
    %% to track changes to node services and set of active nodes. But
    %% for mixed version clusters we want to be serving same revs as
    %% 3.0 nodes.
    Rev = case cluster_compat_mode:is_cluster_sherlock() of
              true ->
                  ns_config:compute_global_rev(Config);
              false ->
                  vclock:count_changes(BucketVC)
          end,

    J = {[{rev, Rev},
          {name, BucketBin},
          {uri, <<"/pools/default/buckets/", BucketBin/binary, "?bucket_uuid=", UUID/binary>>},
          {streamingUri, <<"/pools/default/bucketsStreaming/", BucketBin/binary, "?bucket_uuid=", UUID/binary>>},
          {nodes, NIs},
          {nodesExt, NEIs},
          {nodeLocator, ns_bucket:node_locator(BucketConfig)},
          {uuid, UUID}
          | MaybeVBMap]},
    {ok, ejson:encode(J), BucketConfig}.

compute_bucket_info(Bucket) ->
    Config = ns_config:get(),
    try do_compute_bucket_info(Bucket, Config)
    catch T:E ->
            {T, E, erlang:get_stacktrace()}
    end.


call_compute_bucket_info(BucketName) ->
    work_queue:submit_sync_work(
      bucket_info_cache,
      fun () ->
              case ets:lookup(bucket_info_cache, BucketName) of
                  [] ->
                      case compute_bucket_info(BucketName) of
                          {ok, V, BucketConfig} ->
                              ets:insert(bucket_info_cache, {BucketName, V}),
                              ets:insert(bucket_info_cache_buckets, {BucketName, BucketConfig}),
                              {ok, V};
                          Other ->
                              %% note: we might consider caching
                              %% exceptions but they're supposedly
                              %% rare anyways
                              Other
                      end;
                  [{_, V}] ->
                      {ok, V}
              end
      end).

terse_bucket_info(BucketName) ->
    case ets:lookup(bucket_info_cache, BucketName) of
        [] ->
            call_compute_bucket_info(BucketName);
        [{_, V}] ->
            {ok, V}
    end.

build_node_services() ->
    case ets:lookup(bucket_info_cache, 'node_services') of
        [] ->
            case call_build_node_services() of
                {ok, V} -> V;
                {T, E, Stack} ->
                    erlang:raise(T, E, Stack)
            end;
        [{_, V}] ->
            V
    end.

call_build_node_services() ->
    work_queue:submit_sync_work(
      bucket_info_cache,
      fun () ->
              case ets:lookup(bucket_info_cache, 'node_services') of
                  [] ->
                      try do_build_node_services() of
                          V ->
                              ets:insert(bucket_info_cache, {'node_services', V}),
                              {ok, V}
                      catch T:E ->
                              {T, E, erlang:get_stacktrace()}
                      end;
                  [{_, V}] ->
                          {ok, V}
              end
      end).

do_build_node_services() ->
    Config = ns_config:get(),
    NEIs = build_nodes_ext(ns_cluster_membership:active_nodes(Config),
                           Config, []),
    J = {[{rev, ns_config:compute_global_rev(Config)},
          {nodesExt, NEIs}]},
    ejson:encode(J).

terse_bucket_info_with_local_addr(BucketName, LocalAddr) ->
    case terse_bucket_info(BucketName) of
        {ok, Bin} ->
            {ok, binary:replace(Bin, list_to_binary(?LOCALHOST_MARKER_STRING), list_to_binary(LocalAddr), [global])};
        Other ->
            Other
    end.
