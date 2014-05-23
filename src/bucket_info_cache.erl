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

%% for diagnostics
-export([submit_buckets_reset/2,
         submit_full_reset/0]).

%% NOTE: we're doing global replace of this string. So it must not
%% need any JSON escaping and it must not otherwise occur in terse
%% bucket info
-define(LOCALHOST_MARKER_STRING, "$HOST").

start_link() ->
    work_queue:start_link(bucket_info_cache, fun cache_init/0).

cache_init() ->
    {ok, _} = gen_event:start_link({local, bucket_info_cache_invalidations}),
    ets:new(bucket_info_cache, [set, named_table]),
    Self = self(),
    ns_pubsub:subscribe_link(ns_config_events, fun cleaner_loop/2, {Self, []}),
    submit_full_reset().

cleaner_loop({buckets, [{configs, NewBuckets0}]}, {Parent, CurrentBuckets}) ->
    NewBuckets = lists:sort(NewBuckets0),
    ToClean = ordsets:subtract(CurrentBuckets, NewBuckets),
    BucketNames  = [Name || {Name, _} <- ToClean],
    submit_buckets_reset(Parent, BucketNames),
    {Parent, NewBuckets};
cleaner_loop({{_, _, capi_port}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{node, _, memcached}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{node, _, moxi}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop(_, Cleaner) ->
    Cleaner.

submit_buckets_reset(Pid, BucketNames) ->
    work_queue:submit_work(
      Pid,
      fun () ->
              [ets:delete(bucket_info_cache, Name) || Name <- BucketNames],
              [gen_event:notify(bucket_info_cache_invalidations, Name) || Name <- BucketNames],
              ok
      end).

submit_full_reset() ->
    work_queue:submit_work(
      bucket_info_cache,
      fun () ->
              ets:delete_all_objects(bucket_info_cache),
              gen_event:notify(bucket_info_cache_invalidations, '*')
      end).

build_ports(Node, Config) ->
    [{proxy, ns_config:search_node_prop(Node, Config, moxi, port)},
     {direct, ns_config:search_node_prop(Node, Config, memcached, port)}].

build_services(Node, Config) ->
    CapiPorts = lists:append([case ns_config:search_node(Node, Config, ConfigKey) of
                                  {value, Value} -> [{JKey, Value}];
                                  false -> []
                              end || {ConfigKey, JKey} <- [{ssl_capi_port, capiSSL},
                                                           {ssl_rest_port, mgmtSSL}]]),
    PortsD = case ns_config:search_node_prop(Node, Config, memcached, ssl_port) of
                 undefined ->
                     CapiPorts;
                 SslPort ->
                     [{kvSSL, SslPort} | CapiPorts]
             end,
    {value, CapiPort} = ns_config:search_node(Node, Config, capi_port),
    [{mgmt, misc:node_rest_port(Config, Node)},
     {capi, CapiPort},
     {moxi, ns_config:search_node_prop(Node, Config, moxi, port)},
     {kv, ns_config:search_node_prop(Node, Config, memcached, port)}
     | PortsD].

maybe_build_ext_hostname(Node) ->
    case misc:node_name_host(Node) of
        {_, "127.0.0.1"} -> [];
        {_, H} -> [{hostname, list_to_binary(H)}]
    end.

do_compute_bucket_info(Bucket, Config) ->
    {ok, BucketConfig, BucketVC} = ns_bucket:get_bucket_with_vclock(Bucket, Config),
    {_, Servers0} = lists:keyfind(servers, 1, BucketConfig),

    %% we do sorting to make nodes list match order of servers inside vBucketServerMap
    Servers = lists:sort(Servers0),

    NIs = [{[{couchApiBase, capi_utils:capi_bucket_url_bin(Node, Bucket, ?LOCALHOST_MARKER_STRING)},
             {hostname, list_to_binary(menelaus_web:build_node_hostname(Config, Node, ?LOCALHOST_MARKER_STRING))},
             {ports, {build_ports(Node, Config)}}]}
           || Node <- Servers],

    NEIs = [{[{services, {build_services(Node, Config)}}
              | maybe_build_ext_hostname(Node)]}
            || Node <- Servers],

    {_, UUID} = lists:keyfind(uuid, 1, BucketConfig),

    BucketBin = list_to_binary(Bucket),

    MaybeVBMap = case lists:keyfind(type, 1, BucketConfig) of
                     {_, memcached} ->
                         [{bucketCapabilities, []}];
                     _ ->
                         {struct, VBMap} = ns_bucket:json_map_with_full_config(?LOCALHOST_MARKER_STRING, BucketConfig, Config),
                         [{bucketCapabilities, [touch, couchapi]},
                          {ddocs, {[{uri, <<"/pools/default/buckets/", BucketBin/binary, "/ddocs">>}]}},
                          {vBucketServerMap, {VBMap}}]
                 end,

    J = {[{rev, vclock:count_changes(BucketVC)},
          {name, BucketBin},
          {uri, <<"/pools/default/buckets/", BucketBin/binary, "?bucket_uuid=", UUID/binary>>},
          {streamingUri, <<"/pools/default/bucketsStreaming/", BucketBin/binary, "?bucket_uuid=", UUID/binary>>},
          {nodes, NIs},
          {nodesExt, NEIs},
          {nodeLocator, ns_bucket:node_locator(BucketConfig)},
          {uuid, UUID},
          {bucketCapabilitiesVer, ''} | MaybeVBMap]},
    ejson:encode(J).

compute_bucket_info(Bucket) ->
    Config = ns_config:get(),
    try do_compute_bucket_info(Bucket, Config) of
        V -> {ok, V}
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
                          {ok, V} ->
                              ets:insert(bucket_info_cache, {BucketName, V}),
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

terse_bucket_info_with_local_addr(BucketName, LocalAddr) ->
    case terse_bucket_info(BucketName) of
        {ok, Bin} ->
            {ok, binary:replace(Bin, list_to_binary(?LOCALHOST_MARKER_STRING), list_to_binary(LocalAddr), [global])};
        Other ->
            Other
    end.
