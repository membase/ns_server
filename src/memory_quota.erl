%% @author Couchbase <info@couchbase.com>
%% @copyright 2018 Couchbase, Inc.
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
%% @doc this module contains memory quotas related code
%%
-module(memory_quota).

-include("ns_common.hrl").
-include("ns_config.hrl").

-export([this_node_memory_data/0,
         get_total_buckets_ram_quota/1,
         check_quotas/3,
         check_this_node_quotas/2,
         get_quota/1,
         get_quota/2,
         set_quotas/2,
         default_quotas/1,
         service_to_json_name/1,
         aware_services/1]).

-define(CGROUP_MEM_USAGE_FILE, "/sys/fs/cgroup/memory/memory.usage_in_bytes").
-define(CGROUP_MEM_LIMIT_FILE, "/sys/fs/cgroup/memory/memory.limit_in_bytes").

this_node_memory_data() ->
    case os:getenv("MEMBASE_RAM_MEGS") of
        false ->
            memory_data();
        X ->
            RAMBytes = list_to_integer(X) * ?MIB,
            {RAMBytes, 0, 0}
    end.

read_int_from_file(File) ->
    %% file:read_file/1 doesn't work for some reason for /sys/fs files
    case misc:with_file(File, [read], fun (FD) -> file:read(FD, 1024) end) of
        {ok, Data} ->
            try
                list_to_integer(string:strip(Data, right, $\n))
            catch
                _:_ -> undefined
            end;
        _ -> undefined
    end.

cgroup_memory_data() ->
    {read_int_from_file(?CGROUP_MEM_LIMIT_FILE),
     read_int_from_file(?CGROUP_MEM_USAGE_FILE)}.

memory_data() ->
    {TotalMemory, _, ProcInfo} = MemSupData = memsup:get_memory_data(),
    case cgroup_memory_data() of
        {undefined, _} -> MemSupData;
        {_, undefined} -> MemSupData;
        {0, _} -> MemSupData;
        {CgroupLimit, _} when TotalMemory < CgroupLimit -> MemSupData;
        {CgroupLimit, CgroupUsage} -> {CgroupLimit, CgroupUsage, ProcInfo}
    end.

get_total_buckets_ram_quota(Config) ->
    AllBuckets = ns_bucket:get_buckets(Config),
    lists:foldl(fun ({_, BucketConfig}, RAMQuota) ->
                                       ns_bucket:raw_ram_quota(BucketConfig) + RAMQuota
                               end, 0, AllBuckets).

allowed_memory_usage_max(MemSupData) ->
    {MaxMemoryBytes0, _, _} = MemSupData,
    MinusMegs = ?MIN_FREE_RAM,

    MaxMemoryMBPercent = (MaxMemoryBytes0 * ?MIN_FREE_RAM_PERCENT) div (100 * ?MIB),
    MaxMemoryMB = lists:max([(MaxMemoryBytes0 div ?MIB) - MinusMegs, MaxMemoryMBPercent]),
    MaxMemoryMB.

-type quota_result() :: ok | {error, quota_error()}.
-type quota_error() ::
        {total_quota_too_high, node(), Value :: integer(), MaxAllowed :: pos_integer()} |
        {service_quota_too_low, service(), Value :: integer(), MinRequired :: pos_integer()}.
-type quotas() :: [{service(), integer()}].

-spec check_quotas([NodeInfo], ns_config(), quotas()) -> quota_result() when
      NodeInfo :: {node(), [service()], MemoryData :: term()}.
check_quotas(NodeInfos, Config, UpdatedQuotas) ->
    case check_service_quotas(UpdatedQuotas, Config) of
        ok ->
            AllQuotas = get_all_quotas(Config, UpdatedQuotas),
            check_quotas_loop(NodeInfos, AllQuotas);
        Error ->
            Error
    end.

service_to_json_name(kv) ->
    memoryQuota;
service_to_json_name(index) ->
    indexMemoryQuota;
service_to_json_name(fts) ->
    ftsMemoryQuota;
service_to_json_name(cbas) ->
    cbasMemoryQuota;
service_to_json_name(eventing) ->
    eventingMemoryQuota.

services_ranking() ->
    [kv, cbas, index, fts, eventing].

aware_services(CompatVersion) ->
    [S || S <- ns_cluster_membership:supported_services_for_version(CompatVersion),
          lists:member(S, services_ranking())].

get_all_quotas(Config, UpdatedQuotas) ->
    CompatVersion = cluster_compat_mode:get_compat_version(Config),
    Services = aware_services(CompatVersion),
    lists:map(
      fun (Service) ->
              Value =
                  case lists:keyfind(Service, 1, UpdatedQuotas) of
                      false ->
                          {ok, V} = get_quota(Config, Service),
                          V;
                      {_, V} ->
                          V
                  end,
              {Service, Value}
      end, Services).

check_quotas_loop([], _) ->
    ok;
check_quotas_loop([{Node, Services, MemoryData} | Rest], AllQuotas) ->
    TotalQuota = lists:sum([Q || {S, Q} <- AllQuotas, lists:member(S, Services)]),
    case check_node_total_quota(Node, TotalQuota, MemoryData) of
        ok ->
            check_quotas_loop(Rest, AllQuotas);
        Error ->
            Error
    end.

check_node_total_quota(Node, TotalQuota, MemoryData) ->
    Max = allowed_memory_usage_max(MemoryData),
    case TotalQuota =< Max of
        true ->
            ok;
        false ->
            {error, {total_quota_too_high, Node, TotalQuota, Max}}
    end.

check_service_quotas([], _) ->
    ok;
check_service_quotas([{Service, Quota} | Rest], Config) ->
    case check_service_quota(Service, Quota, Config) of
        ok ->
            check_service_quotas(Rest, Config);
        Error ->
            Error
    end.

-define(MAX_DEFAULT_FTS_QUOTA, 512).

min_quota(kv) ->
    256;
min_quota(index) ->
    256;
min_quota(fts) ->
    256;
min_quota(cbas) ->
    1024;
min_quota(eventing) ->
    256.


check_service_quota(kv, Quota, Config) ->
    BucketsQuota = get_total_buckets_ram_quota(Config) div ?MIB,
    MinMemoryMB = erlang:max(min_quota(kv), BucketsQuota),
    check_min_quota(kv, MinMemoryMB, Quota);
check_service_quota(Service, Quota, _) ->
    check_min_quota(Service, min_quota(Service), Quota).

check_min_quota(_Service, MinQuota, Quota) when Quota >= MinQuota ->
    ok;
check_min_quota(Service, MinQuota, Quota) ->
    {error, {service_quota_too_low, Service, Quota, MinQuota}}.

%% check that the node has enough memory for the quotas; note that we do not
%% validate service quota values because we expect them to be validated by the
%% calling side
-spec check_this_node_quotas([service()], quotas()) -> quota_result().
check_this_node_quotas(Services, Quotas0) ->
    Quotas = [{S, Q} || {S, Q} <- Quotas0, lists:member(S, Services)],
    MemoryData = this_node_memory_data(),
    TotalQuota = lists:sum([Q || {_, Q} <- Quotas]),

    check_node_total_quota(node(), TotalQuota, MemoryData).

service_to_store_method(kv) ->
    {key, memory_quota};
service_to_store_method(index) ->
    {manager, index_settings_manager};
service_to_store_method(fts) ->
    {key, fts_memory_quota};
service_to_store_method(cbas) ->
    {key, cbas_memory_quota};
service_to_store_method(eventing) ->
    {manager, eventing_settings_manager}.

get_quota(Service) ->
    get_quota(ns_config:latest(), Service).

get_quota(Config, Service) ->
    case service_to_store_method(Service) of
        {key, Key}->
            case ns_config:search(Config, Key) of
                {value, Quota} ->
                    {ok, Quota};
                false ->
                    not_found
            end;
        {manager, Manager} ->
            NotFound = make_ref(),
            case Manager:get_from_config(Config, memoryQuota, NotFound) of
                NotFound ->
                    not_found;
                Quota ->
                    {ok, Quota}
            end
    end.

set_quotas(Config, Quotas) ->
    RV = ns_config:run_txn_with_config(
           Config,
           fun (Cfg, SetFn) ->
                   NewCfg =
                       lists:foldl(
                         fun ({Service, Quota}, Acc) ->
                                 do_set_memory_quota(Service, Quota, Acc, SetFn)
                         end, Cfg, Quotas),
                   {commit, NewCfg}
           end),

    case RV of
        {commit, _} ->
            ok;
        retry_needed ->
            retry_needed
    end.

do_set_memory_quota(Service, Quota, Cfg, SetFn) ->
    case service_to_store_method(Service) of
        {key, Key}->
            SetFn(Key, Quota, Cfg);
        {manager, Manager} ->
            Txn = Manager:update_txn([{memoryQuota, Quota}]),
            {commit, NewCfg, _} = Txn(Cfg, SetFn),
            NewCfg
    end.

default_quota(Service, Memory, Max) ->
    Quota = calculate_default_quota(Service, Memory),
    Min = min_quota(Service),

    %% note that this prefers enforcing minimum quota which for very small
    %% amounts of RAM can result in combined quota be actually larger than RAM
    %% size; but we don't really support such small machines anyway
    if Quota < Min ->
            Min;
       Quota > Max ->
            Max;
       true ->
            Quota
    end.

calculate_default_quota(kv, Memory) ->
    (Memory * 3) div 5;
calculate_default_quota(index, Memory) ->
    (Memory * 3) div 5;
calculate_default_quota(fts, Memory) ->
    min(Memory div 5, ?MAX_DEFAULT_FTS_QUOTA);
calculate_default_quota(cbas, Memory) ->
    Memory div 5;
calculate_default_quota(eventing, Memory) ->
    Memory div 5.

default_quotas(Services) ->
    %% this is actually bogus, because nodes can be heterogeneous; but that's
    %% best we can do
    MemSupData = this_node_memory_data(),
    default_quotas(Services, MemSupData).

default_quotas(Services, MemSupData) ->
    {MemoryBytes, _, _} = MemSupData,
    Memory = MemoryBytes div ?MIB,
    MemoryMax = allowed_memory_usage_max(MemSupData),

    {_, _, Result} =
        lists:foldl(
          fun (Service, {AccMem, AccMax, AccResult} = Acc) ->
                  case lists:member(Service, Services) of
                      true ->
                          Quota = default_quota(Service, AccMem, AccMax),
                          AccMem1 = AccMem - Quota,
                          AccMax1 = AccMax - Quota,
                          AccResult1 = [{Service, Quota} | AccResult],

                          {AccMem1, AccMax1, AccResult1};
                      false ->
                          Acc
                  end
          end, {Memory, MemoryMax, []}, services_ranking()),

    Result.
