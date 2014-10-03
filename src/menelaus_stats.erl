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
%% @doc Web server for menelaus.

-module(menelaus_stats).
-author('NorthScale <info@northscale.com>').

-include("ns_stats.hrl").
-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([handle_bucket_stats/3,
         handle_bucket_node_stats/4,
         handle_specific_stat_for_buckets/4,
         handle_specific_stat_for_buckets_group_per_node/4,
         handle_overview_stats/2,
         basic_stats/1,
         bucket_disk_usage/1,
         bucket_ram_usage/1,
         serve_stats_directory/3]).

%% External API
bucket_disk_usage(BucketName) ->
    {_, _, _, _, DiskUsed, _}
        = last_membase_sample(BucketName, ns_bucket:live_bucket_nodes(BucketName)),
    DiskUsed.

bucket_ram_usage(BucketName) ->
    %% NOTE: we're getting last membase sample, but first stat name is
    %% same in memcached buckets, so it works for them too.
    element(1, last_membase_sample(BucketName, ns_bucket:live_bucket_nodes(BucketName))).

extract_stat(StatName, Sample) ->
    case orddict:find(StatName, Sample#stat_entry.values) of
        error -> 0;
        {ok, V} -> V
    end.

get_node_infos(NodeNames) ->
    NodesDict = ns_doctor:get_nodes(),
    lists:foldl(fun (N, A) ->
                         case dict:find(N, NodesDict) of
                             {ok, V} -> [{N, V} | A];
                             _ -> A
                         end
                 end, [], NodeNames).

grab_latest_bucket_stats(BucketName, Nodes) ->
    NodeInfos = get_node_infos(Nodes),
    Stats = extract_interesting_buckets(BucketName, NodeInfos),
    {FoundNodes, _} = lists:unzip(Stats),
    RestNodes = Nodes -- FoundNodes,
    RestStats = [{N, S} || {N, [#stat_entry{values=S} | _]} <-
                               menelaus_stats_gatherer:invoke_archiver(BucketName, RestNodes,
                                                                       {1, minute, 1})],
    Stats ++ RestStats.

extract_interesting_stat(Key, Stats) ->
    case lists:keyfind(Key, 1, Stats) of
        false -> 0;
        {_, Stat} -> Stat
    end.

extract_interesting_buckets(BucketName, NodeInfos) ->
    Stats0 =
        lists:map(
          fun ({Node, NodeInfo}) ->
                  case proplists:get_value(per_bucket_interesting_stats, NodeInfo) of
                      undefined ->
                          [];
                      NodeStats ->
                          case [S || {B, S} <- NodeStats, B =:= BucketName] of
                              [BucketStats] ->
                                  [{Node, BucketStats}];
                              _ ->
                                  []
                          end
                  end
          end, NodeInfos),

    lists:append(Stats0).

last_membase_sample(BucketName, Nodes) ->
    lists:foldl(
        fun ({_, Stats},
             {AccMem, AccItems, AccOps, AccFetches, AccDisk, AccData}) ->
                    {extract_interesting_stat(mem_used, Stats) + AccMem,
                     extract_interesting_stat(curr_items, Stats) + AccItems,
                     extract_interesting_stat(ops, Stats) + AccOps,
                     extract_interesting_stat(ep_bg_fetched, Stats) + AccFetches,
                     extract_interesting_stat(couch_docs_actual_disk_size, Stats) +
                       extract_interesting_stat(couch_views_actual_disk_size, Stats) + AccDisk,
                     extract_interesting_stat(couch_docs_data_size, Stats) + AccData}
        end, {0, 0, 0, 0, 0, 0}, grab_latest_bucket_stats(BucketName, Nodes)).



last_memcached_sample(BucketName, Nodes) ->
    {MemUsed, CurrItems, Ops, CmdGet, GetHits}
            = lists:foldl(
                    fun ({_, Stats},
                         {AccMem, AccItems, AccOps, AccGet, AccGetHits}) ->
                                {extract_interesting_stat(mem_used, Stats) + AccMem,
                                 extract_interesting_stat(curr_items, Stats) + AccItems,
                                 extract_interesting_stat(ops, Stats) + AccOps,
                                 extract_interesting_stat(cmd_get, Stats) + AccGet,
                                 extract_interesting_stat(get_hits, Stats) + AccGetHits}
                    end, {0, 0, 0, 0, 0}, grab_latest_bucket_stats(BucketName, Nodes)),

    {MemUsed, CurrItems, Ops,
     case CmdGet == 0 of
         true -> 0;
         _ -> GetHits / CmdGet
     end}.

last_bucket_stats(membase, BucketName, Nodes) ->
    {MemUsed, ItemsCount, Ops, Fetches, Disk, Data}
        = last_membase_sample(BucketName, Nodes),
    [{opsPerSec, Ops},
     {diskFetches, Fetches},
     {itemCount, ItemsCount},
     {diskUsed, Disk},
     {dataUsed, Data},
     {memUsed, MemUsed}];
last_bucket_stats(memcached, BucketName, Nodes) ->
    {MemUsed, ItemsCount, Ops, HitRatio} = last_memcached_sample(BucketName, Nodes),
    [{opsPerSec, Ops},
     {hitRatio, HitRatio},
     {itemCount, ItemsCount},
     {memUsed, MemUsed}].

basic_stats(BucketName) ->
    {ok, BucketConfig} = ns_bucket:maybe_get_bucket(BucketName, undefined),
    QuotaBytes = ns_bucket:ram_quota(BucketConfig),
    BucketType = ns_bucket:bucket_type(BucketConfig),
    BucketNodes = ns_bucket:live_bucket_nodes_from_config(BucketConfig),
    Stats = last_bucket_stats(BucketType, BucketName, BucketNodes),
    MemUsed = proplists:get_value(memUsed, Stats),
    QuotaPercent = try (MemUsed * 100.0 / QuotaBytes) of
                       X -> X
                   catch
                       error:badarith -> 0
                   end,
    [{quotaPercentUsed, lists:min([QuotaPercent, 100])}
     | Stats].

handle_overview_stats(PoolId, Req) ->
    Names = lists:sort(menelaus_web_buckets:all_accessible_bucket_names(PoolId, Req)),
    {ClientTStamp, Window} = parse_stats_params([{"zoom", "hour"}]),
    AllSamples = lists:map(fun (Name) ->
                                   grab_aggregate_op_stats(Name, all, ClientTStamp, Window)
                           end, Names),
    MergedSamples = case AllSamples of
                        [FirstBucketSamples | RestSamples] ->
                            merge_all_samples_normally(FirstBucketSamples, RestSamples);
                        [] -> []
                    end,
    TStamps = [X#stat_entry.timestamp || X <- MergedSamples],
    Ops = [extract_stat(ops, X) || X <- MergedSamples],
    DiskReads = [extract_stat(ep_bg_fetched, X) || X <- MergedSamples],
    menelaus_util:reply_json(Req, {struct, [{timestamp, TStamps},
                                            {ops, Ops},
                                            {ep_bg_fetched, DiskReads}]}).

%% GET /pools/{PoolID}/buckets/{Id}/stats
handle_bucket_stats(_PoolId, Id, Req) ->
    Params = Req:parse_qs(),
    PropList1 = build_bucket_stats_ops_response(all, Id, Params),
    PropList2 = build_bucket_stats_hks_response(Id),
    menelaus_util:reply_json(Req, {struct, PropList1 ++ PropList2}).

%% Per-Node Stats
%% GET /pools/{PoolID}/buckets/{Id}/nodes/{NodeId}/stats
%%
%% Per-node stats match bucket stats with the addition of a 'hostname' key,
%% stats specific to the node (obviously), and removal of any cross-node stats
handle_bucket_node_stats(_PoolId, BucketName, HostName, Req) ->
    case menelaus_web:find_bucket_hostname(BucketName, HostName, Req) of
        false ->
            menelaus_util:reply_not_found(Req);
        {ok, Node} ->
            Params = Req:parse_qs(),
            Ops = build_bucket_stats_ops_response([Node], BucketName, Params),
            BucketsTopKeys = case hot_keys_keeper:bucket_hot_keys(BucketName, Node) of
                                 undefined -> [];
                                 X -> X
                             end,

            HKS = jsonify_hks(BucketsTopKeys),
            menelaus_util:reply_json(
              Req,
              {struct, [{hostname, list_to_binary(HostName)}
                        | HKS ++ Ops]})
      end.

%% Specific Stat URL for all buckets
%% GET /pools/{PoolID}/buckets/{Id}/stats/{StatName}
handle_specific_stat_for_buckets(PoolId, Id, StatName, Req) ->
    Params = Req:parse_qs(),
    case proplists:get_value("per_node", Params, "true") of
        undefined ->
            menelaus_util:reply(Req, 501);
        "true" ->
            handle_specific_stat_for_buckets_group_per_node(PoolId, Id, StatName, Req)
    end.

%% Specific Stat URL grouped by nodes
%% GET /pools/{PoolID}/buckets/{Id}/stats/{StatName}?per_node=true
%%
%% Req:ok({"application/json",
%%         menelaus_util:server_header(),
%%         <<"{
%%     \"timestamp\": [1,2,3,4,5],
%%     \"nodeStats\": [{\"127.0.0.1:9000\": [1,2,3,4,5]},
%%                     {\"127.0.0.1:9001\": [1,2,3,4,5]}]
%%   }">>}).
handle_specific_stat_for_buckets_group_per_node(_PoolId, BucketName, StatName, Req) ->
    Params = Req:parse_qs(),
    menelaus_util:reply_json(
      Req,
      build_response_for_specific_stat(BucketName, StatName, Params, menelaus_util:local_addr(Req))).

build_simple_stat_extractor(StatAtom, StatBinary) ->
    fun (#stat_entry{timestamp = TS, values = VS}) ->
            V = case orddict:find(StatAtom, VS) of
                    error ->
                        dict_safe_fetch(StatBinary, VS, undefined);
                    {ok, V1} ->
                        V1
                end,

            {TS, V}
    end.

build_raw_stat_extractor(StatBinary) ->
    fun (#stat_entry{timestamp = TS, values = VS}) ->
            {TS, dict_safe_fetch(StatBinary, VS, undefined)}
    end.

build_stat_extractor(BucketName, StatName) ->
    ExtraStats = computed_stats_lazy_proplist(BucketName),
    StatBinary = list_to_binary(StatName),

    case lists:keyfind(StatBinary, 1, ExtraStats) of
        {_K, {F, Meta}} ->
            fun (#stat_entry{timestamp = TS, values = VS}) ->
                    Args = [dict_safe_fetch(Name, VS, undefined) || Name <- Meta],
                    case lists:member(undefined, Args) of
                        true -> {TS, undefined};
                        _ -> {TS, erlang:apply(F, Args)}
                    end
            end;
        false ->
            Stat = try
                       {ok, list_to_existing_atom(StatName)}
                   catch
                       error:badarg ->
                           error
                   end,

            case Stat of
                {ok, StatAtom} ->
                    build_simple_stat_extractor(StatAtom, StatBinary);
                error ->
                    build_raw_stat_extractor(StatBinary)
            end
    end.

dict_safe_fetch(K, Dict, Default) ->
    case lists:keyfind(K, 1, Dict) of
        {_, V} -> V;
        _ -> Default
    end.

are_samples_undefined(Samples) ->
    lists:all(fun (List) ->
                      lists:all(fun ({_, undefined}) ->
                                        true;
                                    ({_, _}) ->
                                        false
                                end, List)
              end, Samples).

get_samples_for_stat(BucketName, StatName, ForNodes, ClientTStamp, Window) ->
    StatExtractor = build_stat_extractor(BucketName, StatName),

    {MainNode, MainSamples, RestSamplesRaw}
        = menelaus_stats_gatherer:gather_stats(BucketName, ForNodes, ClientTStamp, Window),

    Nodes = [MainNode | [N || {N, _} <- RestSamplesRaw]],
    AllNodesSamples = [{MainNode, lists:reverse(MainSamples)} | RestSamplesRaw],

    {[lists:map(StatExtractor, NodeSamples) || {_, NodeSamples} <- AllNodesSamples], Nodes}.

get_samples_for_system_or_bucket_stat(BucketName, StatName, ClientTStamp, Window) ->
    ForNodes = ns_bucket:live_bucket_nodes(BucketName),
    RV = {Samples, _} = get_samples_for_stat("@system", StatName, ForNodes, ClientTStamp, Window),
    case are_samples_undefined(Samples) of
        true ->
            get_samples_for_stat(BucketName, StatName, ForNodes, ClientTStamp, Window);
        false ->
            RV
    end.

build_response_for_specific_stat(BucketName, StatName, Params, LocalAddr) ->
    {ClientTStamp, {Step, _, Count} = Window} =
        parse_stats_params(Params),

    {NodesSamples, Nodes} =
        get_samples_for_system_or_bucket_stat(BucketName, StatName, ClientTStamp, Window),

    Config = ns_config:get(),
    Hostnames = [list_to_binary(menelaus_web:build_node_hostname(Config, N, LocalAddr)) || N <- Nodes],

    Timestamps = [TS || {TS, _} <- hd(NodesSamples)],
    MainValues = [VS || {_, VS} <- hd(NodesSamples)],

    AllignedRestValues
        = lists:map(fun (undefined) -> [undefined || _ <- Timestamps];
                        (Samples) ->
                            Dict = orddict:from_list(Samples),
                            [dict_safe_fetch(T, Dict, 0) || T <- Timestamps]
                    end, tl(NodesSamples)),
    {struct, [{samplesCount, Count},
              {isPersistent, ns_bucket:is_persistent(BucketName)},
              {lastTStamp, case Timestamps of
                               [] -> 0;
                               L -> lists:last(L)
                           end},
              {interval, Step * 1000},
              {timestamp, Timestamps},
              {nodeStats, {struct, lists:zipwith(fun (H, VS) ->
                                                         {H, VS}
                                                 end,
                                                 Hostnames, [MainValues | AllignedRestValues])}}]}.

%% ops SUM(cmd_get, cmd_set,
%%         incr_misses, incr_hits,
%%         decr_misses, decr_hits,
%%         cas_misses, cas_hits, cas_badval,
%%         delete_misses, delete_hits,
%%         cmd_flush)
%% cmd_get (cmd_get)
%% get_misses (get_misses)
%% get_hits (get_hits)
%% cmd_set (cmd_set)
%% evictions (evictions)
%% replacements (if available in time)
%% misses SUM(get_misses, delete_misses, incr_misses, decr_misses,
%%            cas_misses)
%% updates SUM(cmd_set, incr_hits, decr_hits, cas_hits)
%% bytes_read (bytes_read)
%% bytes_written (bytes_written)
%% hit_ratio (get_hits / cmd_get)
%% curr_items (curr_items)

%% Implementation

merge_all_samples_normally(MainSamples, ListOfLists) ->
    ETS = ets:new(ok, [{keypos, #stat_entry.timestamp}]),
    try do_merge_all_samples_normally(ETS, MainSamples, ListOfLists)
    after
        ets:delete(ETS)
    end.

do_merge_all_samples_normally(ETS, MainSamples, ListOfLists) ->
    ets:insert(ETS, MainSamples),
    lists:foreach(
      fun (OtherSamples) ->
              lists:foreach(
                fun (OtherS) ->
                        TS = OtherS#stat_entry.timestamp,
                        case ets:lookup(ETS, TS) of
                            [S|_] ->
                                ets:insert(ETS, aggregate_stat_entries(S, OtherS));
                            _ ->
                                nothing
                        end
                end, OtherSamples)
      end, ListOfLists),
    [hd(ets:lookup(ETS, T)) || #stat_entry{timestamp = T} <- MainSamples].

grab_system_aggregate_op_stats(Bucket, all, ClientTStamp, Window) ->
    grab_aggregate_op_stats("@system", ns_bucket:live_bucket_nodes(Bucket), ClientTStamp, Window);
grab_system_aggregate_op_stats(_Bucket, [Node], ClientTStamp, Window) ->
    grab_aggregate_op_stats("@system", [Node], ClientTStamp, Window).

grab_aggregate_op_stats(Bucket, all, ClientTStamp, Window) ->
    grab_aggregate_op_stats(Bucket, ns_bucket:live_bucket_nodes(Bucket), ClientTStamp, Window);
grab_aggregate_op_stats(Bucket, Nodes, ClientTStamp, Window) ->
    {_MainNode, MainSamples, Replies} =
        menelaus_stats_gatherer:gather_stats(Bucket, Nodes, ClientTStamp, Window),
    RV = merge_all_samples_normally(MainSamples, [S || {_,S} <- Replies]),
    lists:reverse(RV).

parse_stats_params(Params) ->
    ClientTStamp = case proplists:get_value("haveTStamp", Params) of
                       undefined -> undefined;
                       X -> try list_to_integer(X) of
                                XI -> XI
                            catch
                                _:_ -> undefined
                            end
                   end,
    {Step0, Period, Count0} = case proplists:get_value("zoom", Params) of
                                  "minute" -> {1, minute, 60};
                                  "hour" -> {60, hour, 900};
                                  "day" -> {1440, day, 1440};
                                  "week" -> {11520, week, 1152};
                                  "month" -> {44640, month, 1488};
                                  "year" -> {527040, year, 1464};
                                  undefined -> {1, minute, 60}
                              end,
    {Step, Count} = case proplists:get_value("resampleForUI", Params) of
                        undefined -> {1, Count0};
                        _ -> {Step0, 60}
                    end,
    {ClientTStamp, {Step, Period, Count}}.


computed_stats_lazy_proplist("@system") ->
    [];
computed_stats_lazy_proplist(BucketName) ->
    Z2 = fun (StatNameA, StatNameB, Combiner) ->
                 {Combiner, [StatNameA, StatNameB]}
         end,
    HitRatio = Z2(cmd_get, get_hits,
                  fun (Gets, _Hits) when Gets == 0 -> 0; % this handles int and float 0
                      (Gets, Hits) -> Hits * 100/Gets
                  end),
    EPCacheMissRatio = Z2(ep_bg_fetched, cmd_get,
                         fun (BGFetches, Gets) ->
                                 try BGFetches * 100 / Gets
                                 catch error:badarith -> 0
                                 end
                         end),
    ResidentItemsRatio = Z2(ep_num_non_resident, curr_items_tot,
                            fun (NonResident, CurrItems) ->
                                    try (CurrItems - NonResident) * 100 / CurrItems
                                    catch error:badarith -> 100
                                    end
                            end),
    AvgActiveQueueAge = Z2(vb_active_queue_age, vb_active_queue_size,
                           fun (ActiveAge, ActiveCount) ->
                                   try ActiveAge / ActiveCount / 1000
                                   catch error:badarith -> 0
                                   end
                           end),
    AvgReplicaQueueAge = Z2(vb_replica_queue_age, vb_replica_queue_size,
                            fun (ReplicaAge, ReplicaCount) ->
                                    try ReplicaAge / ReplicaCount / 1000
                                    catch error:badarith -> 0
                                    end
                            end),
    AvgPendingQueueAge = Z2(vb_pending_queue_age, vb_pending_queue_size,
                            fun (PendingAge, PendingCount) ->
                                    try PendingAge / PendingCount / 1000
                                    catch error:badarith -> 0
                                    end
                            end),
    AvgTotalQueueAge = Z2(vb_total_queue_age, ep_diskqueue_items,
                          fun (TotalAge, TotalCount) ->
                                  try TotalAge / TotalCount / 1000
                                  catch error:badarith -> 0
                                  end
                          end),
    TotalDisk = Z2(couch_docs_actual_disk_size, couch_views_actual_disk_size,
                          fun (Views, Docs) ->
                                  Views + Docs
                          end),

    ResidenceCalculator = fun (NonResident, Total) ->
                                  try (Total - NonResident) * 100 / Total
                                  catch error:badarith -> 100
                                  end
                          end,

    Fragmentation = fun (Data, Disk) ->
                            try
                                round((Disk - Data) / Disk * 100)
                            catch error:badarith ->
                                    0
                            end
                    end,

    DocsFragmentation = Z2(couch_docs_data_size, couch_docs_disk_size,
                           Fragmentation),
    ViewsFragmentation = Z2(couch_views_data_size, couch_views_disk_size,
                           Fragmentation),

    ActiveResRate = Z2(vb_active_num_non_resident, curr_items,
                       ResidenceCalculator),
    ReplicaResRate = Z2(vb_replica_num_non_resident, vb_replica_curr_items,
                        ResidenceCalculator),
    PendingResRate = Z2(vb_pending_num_non_resident, vb_pending_curr_items,
                        ResidenceCalculator),

    AverageDiskUpdateTime = Z2(disk_update_total, disk_update_count,
                               fun (Total, Count) ->
                                       try Total / Count
                                       catch error:badarith -> 0
                                       end
                               end),

    AverageCommitTime = Z2(disk_commit_total, disk_commit_count,
                           fun (Total, Count) ->
                                   try Total / Count / 1000000
                                   catch error:badarith -> 0
                                   end
                           end),

    AverageBgWait = Z2(bg_wait_total, bg_wait_count,
                       fun (Total, Count) ->
                               try Total / Count
                               catch error:badarith -> 0
                               end
                       end),

    %% compute a list of per replication XDC stats
    Reps = xdc_replication_sup:get_replications(list_to_binary(BucketName)),
    XDCAllRepStats =
        lists:flatmap(fun ({Id, _Pid}) ->
                              Prefix = <<"replications/", Id/binary,"/">>,

                              WtAvgMetaLatency = Z2(<<Prefix/binary, "meta_latency_aggr">>,
                                                    <<Prefix/binary, "meta_latency_wt">>,
                                                    fun (Total, Count) ->
                                                            try Total / Count
                                                            catch error:badarith -> 0
                                                            end
                                                    end),

                              WtAvgDocsLatency = Z2(<<Prefix/binary, "docs_latency_aggr">>,
                                                    <<Prefix/binary, "docs_latency_wt">>,
                                                    fun (Total, Count) ->
                                                            try Total / Count
                                                            catch error:badarith -> 0
                                                            end
                                                    end),

                              PercentCompleteness = Z2(<<Prefix/binary, "docs_checked">>,
                                                       <<Prefix/binary, "changes_left">>,
                                                       fun (Checked, Left) ->
                                                               try (100 * Checked) / (Checked + Left)
                                                               catch error:badarith -> 0
                                                               end
                                                       end),

                              Utilization = Z2(<<Prefix/binary, "time_working_rate">>,
                                               <<Prefix/binary, "max_vbreps">>,
                                               fun (Rate, Max) ->
                                                       try 100 * Rate / Max
                                                       catch error:badarith -> 0
                                                       end
                                               end),

                              [{<<Prefix/binary, "wtavg_meta_latency">>, WtAvgMetaLatency},
                               {<<Prefix/binary, "wtavg_docs_latency">>, WtAvgDocsLatency},
                               {<<Prefix/binary, "percent_completeness">>, PercentCompleteness},
                               {<<Prefix/binary, "utilization">>, Utilization}]
                      end,
                      Reps),

    [{<<"couch_total_disk_size">>, TotalDisk},
     {<<"couch_docs_fragmentation">>, DocsFragmentation},
     {<<"couch_views_fragmentation">>, ViewsFragmentation},
     {<<"hit_ratio">>, HitRatio},
     {<<"ep_cache_miss_rate">>, EPCacheMissRatio},
     {<<"ep_resident_items_rate">>, ResidentItemsRatio},
     {<<"vb_avg_active_queue_age">>, AvgActiveQueueAge},
     {<<"vb_avg_replica_queue_age">>, AvgReplicaQueueAge},
     {<<"vb_avg_pending_queue_age">>, AvgPendingQueueAge},
     {<<"vb_avg_total_queue_age">>, AvgTotalQueueAge},
     {<<"vb_active_resident_items_ratio">>, ActiveResRate},
     {<<"vb_replica_resident_items_ratio">>, ReplicaResRate},
     {<<"vb_pending_resident_items_ratio">>, PendingResRate},
     {<<"avg_disk_update_time">>, AverageDiskUpdateTime},
     {<<"avg_disk_commit_time">>, AverageCommitTime},
     {<<"avg_bg_wait_time">>, AverageBgWait}] ++ XDCAllRepStats.

%% converts list of samples to proplist of stat values.
%%
%% null values should be uncommon, but they are not impossible. They
%% will be used for samples which lack some particular stat, for
%% example due to older membase version. I.e. when we upgrade we
%% sometimes add new kinds of stats and null values are used to mark
%% those past samples that don't have new stats gathered.
-spec samples_to_proplists([#stat_entry{}], list()) -> [{atom(), [null | number()]}].
samples_to_proplists([], _BucketName) -> [{timestamp, []}];
samples_to_proplists(Samples, BucketName) ->
    %% we're assuming that last sample has currently supported stats,
    %% that's why we are folding from backward and why we're ignoring
    %% other keys of other samples
    [LastSample | ReversedRest] = lists:reverse(Samples),
    InitialAcc0 = orddict:map(fun (_, V) -> [V] end, LastSample#stat_entry.values),
    InitialAcc = orddict:store(timestamp, [LastSample#stat_entry.timestamp], InitialAcc0),
    Dict = lists:foldl(fun (Sample, Acc) ->
                               orddict:map(fun (timestamp, AccValues) ->
                                                   [Sample#stat_entry.timestamp | AccValues];
                                               (K, AccValues) ->
                                                   case lists:keyfind(K, 1, Sample#stat_entry.values) of
                                                       {_, ThisValue} -> [ThisValue | AccValues];
                                                       _ -> [null | AccValues]
                                                   end
                                           end, Acc)
                       end, InitialAcc, ReversedRest),

    ExtraStats = lists:map(fun ({K, {F, [StatNameA, StatNameB]}}) ->
                                   ResA = orddict:find(StatNameA, Dict),
                                   ResB = orddict:find(StatNameB, Dict),
                                   ValR = case {ResA, ResB} of
                                              {{ok, ValA}, {ok, ValB}} ->
                                                  lists:zipwith(
                                                    fun (A, B) when A =/= null, B =/= null ->
                                                            F(A, B);
                                                        (_, _) ->
                                                            null
                                                    end, ValA, ValB);
                                              _ -> undefined
                                          end,
                                   {K, ValR}
                           end, computed_stats_lazy_proplist(BucketName)),

    lists:filter(fun ({_, undefined}) -> false;
                     ({_, _}) -> true
                 end, ExtraStats)
        ++ orddict:to_list(Dict).

join_samples(A, B) ->
    lists:reverse(join_samples(A, B, [])).

join_samples([A | _] = ASamples, [B | TailB], Acc) when A#stat_entry.timestamp > B#stat_entry.timestamp ->
    join_samples(ASamples, TailB, Acc);
join_samples([A | TailA], [B | _] = BSamples, Acc) when A#stat_entry.timestamp < B#stat_entry.timestamp ->
    join_samples(TailA, BSamples, Acc);
join_samples([A | TailA], [B | TailB], Acc) ->
    NewAcc = [A#stat_entry{values = A#stat_entry.values ++ B#stat_entry.values} | Acc],
    join_samples(TailA, TailB, NewAcc);
join_samples(_, _, Acc) ->
    Acc.

join_samples_test() ->
    A = [
         {stat_entry, 1, [{key1, 1},
                          {key2, 2}]},
         {stat_entry, 2, [{key1, 3},
                          {key2, 4}]},
         {stat_entry, 3, [{key1, 5},
                          {key2, 6}]}],
    B = [
         {stat_entry, 2, [{key3, 1},
                          {key4, 2}]},
         {stat_entry, 3, [{key3, 3},
                          {key4, 4}]},
         {stat_entry, 4, [{key3, 5},
                          {key4, 6}]}],

    R1 = [
          {stat_entry, 2, [{key1, 3},
                           {key2, 4},
                           {key3, 1},
                           {key4, 2}]},
          {stat_entry, 3, [{key1, 5},
                           {key2, 6},
                           {key3, 3},
                           {key4, 4}]}],

    R2 = [
          {stat_entry, 2, [{key3, 1},
                           {key4, 2},
                           {key1, 3},
                           {key2, 4}]},
          {stat_entry, 3, [{key3, 3},
                           {key4, 4},
                           {key1, 5},
                           {key2, 6}]}],

    ?assertEqual(R1, join_samples(A, B)),
    ?assertEqual(R2, join_samples(B, A)).


build_bucket_stats_ops_response(Nodes, BucketName, Params) ->
    {ClientTStamp, {Step, _, Count} = Window} = parse_stats_params(Params),

    BucketRawSamples = grab_aggregate_op_stats(BucketName, Nodes, ClientTStamp, Window),
    SystemRawSamples = grab_system_aggregate_op_stats(BucketName, Nodes, ClientTStamp, Window),

    % this will throw out all samples with timestamps that are not present
    % in both BucketRawSamples and SystemRawSamples
    Samples = join_samples(BucketRawSamples, SystemRawSamples),

    StatsPropList = samples_to_proplists(Samples, BucketName),

    [{op, {struct,
           [{samples, {struct, StatsPropList}},
            {samplesCount, Count},
            {isPersistent, ns_bucket:is_persistent(BucketName)},
            {lastTStamp, case proplists:get_value(timestamp, StatsPropList) of
                             [] -> 0;
                             L -> lists:last(L)
                         end},
            {interval, Step * 1000}]}}].

is_safe_key_name(Name) ->
    lists:all(fun (C) ->
                      C >= 16#20 andalso C =< 16#7f
              end, Name).

build_bucket_stats_hks_response(BucketName) ->
    BucketsTopKeys = case hot_keys_keeper:bucket_hot_keys(BucketName) of
                         undefined -> [];
                         X -> X
                     end,
    jsonify_hks(BucketsTopKeys).

jsonify_hks(BucketsTopKeys) ->
    HotKeyStructs = lists:map(fun ({Key, PList}) ->
                                      EscapedKey = case is_safe_key_name(Key) of
                                                       true -> Key;
                                                       _ -> "BIN_" ++ base64:encode_to_string(Key)
                                                   end,
                                      {struct, [{name, list_to_binary(EscapedKey)},
                                                {ops, proplists:get_value(ops, PList)}]}
                              end, BucketsTopKeys),
    [{hot_keys, HotKeyStructs}].

%% by default we aggregate stats between nodes using SUM
%% but in some cases other methods should be used
%% for example for couch_views_ops since view hits all the nodes
%% we use max to prevent the number of ops to be multiplied to the number of nodes
get_aggregate_method(Key) ->
    case Key of
        couch_views_ops ->
            max;
        cpu_utilization_rate ->
            max;
        <<"views/", S/binary>> ->
            case binary:match(S, <<"/accesses">>) of
                nomatch ->
                    sum;
                _ ->
                    max
            end;
        _ ->
            sum
    end.

aggregate_values(Key, AV, BV) ->
    case get_aggregate_method(Key) of
        sum ->
            try AV+BV
            catch error:badarith ->
                    case ([X || X <- [AV,BV],
                                X =/= undefined]) of
                        [] -> undefined;
                        [X|_] -> X
                    end
            end;
        max ->
            case {AV, BV} of
                {undefined, undefined} ->
                    undefined;
                {undefined, _} ->
                    BV;
                {_, undefined} ->
                    AV;
                _ ->
                    max(AV, BV)
            end
    end.

aggregate_stat_kv_pairs([], _BValues, Acc) ->
    lists:reverse(Acc);
aggregate_stat_kv_pairs(APairs, [], Acc) ->
    lists:reverse(Acc, APairs);
aggregate_stat_kv_pairs([{AK, AV} = APair | ARest] = A,
                        [{BK, BV} | BRest] = B,
                        Acc) ->
    case AK of
        BK ->
            NewAcc = [{AK, aggregate_values(AK, AV, BV)} | Acc],
            aggregate_stat_kv_pairs(ARest, BRest, NewAcc);
        _ when AK < BK ->
            case AV of
                undefined ->
                    aggregate_stat_kv_pairs(ARest, B, [{AK, 0} | Acc]);
                _ ->
                    aggregate_stat_kv_pairs(ARest, B, [APair | Acc])
            end;
        _ ->
            aggregate_stat_kv_pairs(A, BRest, Acc)
    end.

aggregate_stat_kv_pairs_test() ->
    ?assertEqual([{a, 3}, {b, undefined}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {b, undefined}, {d, undefined}, {e,1}],
                                         [])),
    ?assertEqual([{a, 3}, {b, undefined}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {b, undefined}, {ba, 123}],
                                         [])),
    ?assertEqual([{a, 3}, {b, 0}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {c,0}, {d, undefined}, {e,1}],
                                         [])),
    ?assertEqual([{couch_views_ops, 3},
                  {<<"views/A1/accesses">>, 4},
                  {<<"views/A1/blah">>, 3}],
                 aggregate_stat_kv_pairs([{couch_views_ops, 1},
                                          {<<"views/A1/accesses">>, 4},
                                          {<<"views/A1/blah">>, 1}],
                                         [{couch_views_ops, 3},
                                          {<<"views/A1/accesses">>, 2},
                                          {<<"views/A1/blah">>, 2}],
                                         [])).

aggregate_stat_entries(A, B) ->
    true = (B#stat_entry.timestamp =:= A#stat_entry.timestamp),
    NewValues = aggregate_stat_kv_pairs(A#stat_entry.values,
                                        B#stat_entry.values,
                                        []),
    A#stat_entry{values = NewValues}.

-define(SPACE_CHAR, 16#20).

couchbase_replication_stats_descriptions(BucketId) ->
    Reps = xdc_replication_sup:get_replications(list_to_binary(BucketId)),
    lists:map(fun ({Id, Pid}) ->
                      {ok, Targ} = xdc_replication:target(Pid),
                      Prefix = <<"replications/", Id/binary,"/">>,

                      {ok, {RemoteClusterUUID, RemoteBucket}} = remote_clusters_info:parse_remote_bucket_reference(Targ),
                      RemoteCluster = remote_clusters_info:find_cluster_by_uuid(RemoteClusterUUID),
                      RemoteClusterName = proplists:get_value(name, RemoteCluster),
                      BlockName = io_lib:format("Outbound XDCR Operations to bucket ~p "
                                                "on remote cluster ~p",[RemoteBucket, RemoteClusterName]),

                      {struct,[{blockName, iolist_to_binary(BlockName)},
                               {extraCSSClasses,<<"dynamic_closed">>},
                               {stats,
                                [%% first row
                                 {struct,[{title,<<"outbound XDCR mutations">>},
                                          {name,<<Prefix/binary,"changes_left">>},
                                          {desc,<<"Number of mutations to be replicated to other clusters "
                                                  "(measured from per-replication stat changes_left)">>}]},
                                 {struct,[{title,<<"percent completed">>},
                                          {maxY, 100},
                                          {name,<<Prefix/binary, "percent_completeness">>},
                                          {desc,<<"Percentage of checked items out of all checked and to-be-replicated items "
                                                  "(measured from per-replication stat percent_completeness)">>}]},
                                 {struct,[{title,<<"active vb reps">>},
                                          {name,<<Prefix/binary,"active_vbreps">>},
                                          {desc,<<"Number of active vbucket replications "
                                                  "(measured from per-replication stat active_vbreps)">>}]},
                                 {struct,[{title,<<"waiting vb reps">>},
                                          {name,<<Prefix/binary,"waiting_vbreps">>},
                                          {desc,<<"Number of waiting vbucket replications "
                                                  "(measured from per-replication stat waiting_vbreps)">>}]},
                                 %% second row
                                 {struct,[{title,<<"mutation replication rate">>},
                                          {name,<<Prefix/binary,"rate_replication">>},
                                          {desc,<<"Rate of replication in terms of number of replicated mutations per second "
                                                  "(measured from per-replication stat rate_replication)">>}]},
                                 {struct,[{isBytes,true},
                                          {title,<<"data replication rate">>},
                                          {name,<<Prefix/binary,"bandwidth_usage">>},
                                          {desc,<<"Rate of replication in terms of bytes replicated per second "
                                                  "(measured from per-replication stat bandwidth_usage)">>}]},
                                 {struct,[{title,<<"opt. replication rate">>},
                                          {name,<<Prefix/binary,"rate_doc_opt_repd">>},
                                          {desc,<<"Rate of optimistic replications in terms of number of replicated mutations per second ">>}]},
                                 {struct,[{title,<<"doc checks rate">>},
                                          {name,<<Prefix/binary,"rate_doc_checks">>},
                                          {desc,<<"Rate of doc checks per second ">>}]},

                                 %% third row
                                 {struct,[{title,<<"meta batches per sec">>},
                                          {name,<<Prefix/binary, "meta_latency_wt">>},
                                          {desc,<<"Weighted average latency in ms of sending getMeta and waiting for conflict solution result from remote cluster "
                                                  "(measured from per-replication stat wtavg_meta_latency)">>}]},
                                 {struct,[{title,<<"ms meta batch latency">>},
                                          {name,<<Prefix/binary, "wtavg_meta_latency">>},
                                          {desc,<<"Weighted average latency in ms of sending getMeta and waiting for conflict solution result from remote cluster "
                                                  "(measured from per-replication stat wtavg_meta_latency)">>}]},
                                 {struct,[{title,<<"docs batches per sec">>},
                                          {name,<<Prefix/binary, "docs_latency_wt">>},
                                          {desc,<<"Weighted average latency in ms of sending replicated mutations to remote cluster "
                                                  "(measured from per-replication stat wtavg_docs_latency)">>}]},
                                 {struct,[{title,<<"ms doc batch latency">>},
                                          {name,<<Prefix/binary, "wtavg_docs_latency">>},
                                          {desc,<<"Weighted average latency in ms of sending replicated mutations to remote cluster "
                                                  "(measured from per-replication stat wtavg_docs_latency)">>}]},
                                 %% fourth row
                                 {struct, [{title, <<"wakeups per sec">>},
                                           {name, <<Prefix/binary, "wakeups_rate">>},
                                           {desc, <<"Rate of XDCR vbucket replicator wakeups">>}]},
                                 {struct, [{title, <<"XDCR vb reps per sec">>},
                                           {name, <<Prefix/binary, "worker_batches_rate">>},
                                           {desc, <<"Rate at which XDCR vbucket replicators replicates batches per sec">>}]},
                                 {struct, [{title, <<"% time spent vb reps">>},
                                           {maxY, 100},
                                           {name, <<Prefix/binary, "utilization">>},
                                           {desc, <<"Percentage of time spent with vbucket replicators * 100 / (max_workers_count * <time passed since last sample>)">>}]}]}]}

              end, Reps).

couchbase_view_stats_descriptions(BucketId) ->
    DictBySig = ns_couchdb_api:get_design_doc_signatures(BucketId),

    dict:fold(
      fun(Sig, DDocIds0, Stats) ->
              Prefix = <<"views/", Sig/binary,"/">>,
              DDocIds = lists:sort(DDocIds0),
              Ids = iolist_to_binary([hd(DDocIds) |
                                      [[?SPACE_CHAR | Id]
                                       || Id <- tl(DDocIds)]]),
              MyStats = {struct,[{blockName,<<"View Stats: ",Ids/binary>>},
                                 {extraCSSClasses,<<"dynamic_closed">>},
                                 {columns,
                                  [<<"Data">>,<<"Disk">>,<<"Read Ops">>]},
                                 {stats,
                                  [{struct,[{isBytes,true},
                                            {title,<<"data size">>},
                                            {name,<<Prefix/binary,"data_size">>},
                                            {desc,<<"How many bytes stored">>}]},
                                   {struct,[{isBytes,true},
                                            {title,<<"disk size">>},
                                            {name,<<Prefix/binary,"disk_size">>},
                                            {desc,<<"How much storage used">>}]},
                                   {struct,[{title,<<"view reads per sec.">>},
                                            {name,<<Prefix/binary,"accesses">>},
                                            {desc,<<"Traffic to the views in this design doc">>}]}
                                  ]}]},
              [MyStats|Stats]
      end, [], DictBySig).

membase_stats_description(BucketId) ->
    [{struct,[{blockName,<<"Summary">>},
              {stats,
               [{struct,[{title,<<"ops per second">>},
                         {name,<<"ops">>},
                         {desc,<<"Total amount of operations per second to this bucket (measured from cmd_get + cmd_set + incr_misses + incr_hits + decr_misses + decr_hits + delete_misses + delete_hits)">>},
                         {default,true}]},
                {struct,[{title,<<"cache miss ratio">>},
                         {name,<<"ep_cache_miss_rate">>},
                         {desc,<<"Percentage of reads per second to this bucket from disk as opposed to RAM (measured from ep_bg_fetches / gets * 100)">>},
                         {maxY,100}]},
                {struct,[{title,<<"gets per sec.">>},
                         {name,<<"cmd_get">>},
                         {desc,<<"Number of reads (get operations) per second from this bucket (measured from cmd_get)">>}]},
                {struct,[{title,<<"sets per sec.">>},
                         {name,<<"cmd_set">>},
                         {desc,<<"Number of writes (set operations) per second to this bucket (measured from cmd_set)">>}]},
                {struct,[{title,<<"deletes per sec.">>},
                         {name,<<"delete_hits">>},
                         {desc,<<"Number of delete operations per second for this bucket (measured from delete_hits)">>}]},
                {struct,[{title,<<"CAS ops per sec.">>},
                         {name,<<"cas_hits">>},
                         {desc,<<"Number of operations with a CAS id per second for this bucket (measured from cas_hits)">>}]},
                {struct,[{title,<<"active docs resident %">>},
                         {name,<<"vb_active_resident_items_ratio">>},
                         {desc,<<"Percentage of active items cached in RAM in this bucket (measured from vb_active_resident_items_ratio)">>},
                         {maxY,100}]},
                {struct,[{title,<<"items">>},
                         {name,<<"curr_items">>},
                         {desc,<<"Number of unique items in this bucket - only active items, not replica (measured from curr_items)">>}]},
                {struct,[{title,<<"temp OOM per sec.">>},
                         {name,<<"ep_tmp_oom_errors">>},
                         {desc,<<"Number of back-offs sent per second to client SDKs due to \"out of memory\" situations from this bucket (measured from ep_tmp_oom_errors)">>}]},
                {struct, [{isBytes,true},
                          {title, <<"low water mark">>},
                          {name, <<"ep_mem_low_wat">>},
                          {desc, <<"Low water mark for auto-evictions (measured from ep_mem_low_wat)">>}]},
                {struct, [{isBytes,true},
                          {title, <<"high water mark">>},
                          {name, <<"ep_mem_high_wat">>},
                          {desc, <<"High water mark for auto-evictions (measured from ep_mem_high_wat)">>}]},
                {struct, [{isBytes,true},
                          {title, <<"memory used">>},
                          {name, <<"mem_used">>},
                          {desc, <<"Memory used as measured from mem_used">>}]},
                {struct,[{title,<<"disk creates per sec.">>},
                         {name,<<"ep_ops_create">>},
                         {desc,<<"Number of new items created on disk per second for this bucket (measured from vb_active_ops_create + vb_replica_ops_create + vb_pending_ops_create)">>}]},
                {struct,[{title,<<"disk updates per sec.">>},
                         {name,<<"ep_ops_update">>},
                         {desc,<<"Number of items updated on disk per second for this bucket (measured from vb_active_ops_update + vb_replica_ops_update + vb_pending_ops_update)">>}]},
                {struct,[{title,<<"disk reads per sec.">>},
                         {name,<<"ep_bg_fetched">>},
                         {desc,<<"Number of reads per second from disk for this bucket (measured from ep_bg_fetched)">>}]},
                {struct,[{title,<<"disk write queue">>},
                         {name,<<"disk_write_queue">>},
                         {desc,<<"Number of items waiting to be written to disk in this bucket (measured from ep_queue_size+ep_flusher_todo)">>}]},
                {struct,[{isBytes,true},
                         {name,<<"couch_docs_data_size">>},
                         {title,<<"docs data size">>},
                         {desc,<<"The size of active data in this bucket "
                                 "(measured from couch_docs_data_size)">>}]},
                {struct,[{isBytes, true},
                         {name,<<"couch_docs_actual_disk_size">>},
                         {title,<<"docs total disk size">>},
                         {desc,<<"The size of all data files for this bucket, including the data itself, meta data and temporary files "
                                 "(measured from couch_docs_actual_disk_size).">>}]},
                {struct,[{name,<<"couch_docs_fragmentation">>},
                         {title,<<"docs fragmentation %">>},
                         {desc,<<"How much fragmented data there is to be compacted compared to real data for the data files in this bucket "
                                  "(measured from couch_docs_fragmentation).">>}]},
                {struct,[{isBytes,true},
                         {name,<<"couch_total_disk_size">>},
                         {title,<<"total disk size">>},
                         {desc,<<"The total size on disk of all data and view files for this bucket."
                                 "(measured from couch_total_disk_size).">>}]},
                {struct,[{isBytes,true},
                         {name,<<"couch_views_data_size">>},
                         {title,<<"views data size">>},
                         {desc,<<"The size of active data on for all the indexes in this bucket"
                                 "(measured from couch_views_data_size).">>}]},
                {struct,[{isBytes,true},
                         {name,<<"couch_views_actual_disk_size">>},
                         {title,<<"views total disk size">>},
                         {desc,<<"The size of all active items in all the indexes for this bucket on disk"
                                 "(measured from couch_views_actual_disk_size).">>}]},
                {struct,[{name,<<"couch_views_fragmentation">>},
                         {title,<<"views fragmentation %">>},
                         {desc,<<"How much fragmented data there is to be compacted compared to real data for the view index files in this bucket"
                                 "(measured from couch_views_fragmentation).">>}]},
                {struct,[{name,<<"couch_views_ops">>},
                         {title,<<"view reads per sec.">>},
                         {desc,<<"All the view reads for all design documents including scatter gather."
                                 "(measured from couch_views_ops).">>}]},
                {struct, [{title, <<"disk update time">>},
                          {name, <<"avg_disk_update_time">>},
                          {hidden, true},
                          {desc, <<"Average disk update time in microseconds as from disk_update histogram of timings"
                                   "(measured from avg_disk_update_time).">>}]},
                {struct, [{title, <<"disk commit time">>},
                          {name, <<"avg_disk_commit_time">>},
                          {hidden, true},
                          {desc, <<"Average disk commit time in seconds as from disk_update histogram of timings"
                                   "(measured from avg_disk_commit_time).">>}]},
                {struct, [{title, <<"bg wait time">>},
                          {hidden, true},
                          {name, <<"avg_bg_wait_time">>},
                          {desc, <<"Average background fetch time in microseconds"
                                   "(measured from avg_bg_wait_time).">>}]},
                {struct,[{title,<<"Incoming XDCR ops/sec.">>},
                         {name,<<"xdc_ops">>},
                         {desc,<<"Incoming XDCR operations per second for this bucket "
                                 "(measured from xdc_ops).">>}]},
                {struct,[{title,<<"outbound XDCR mutations">>},
                         {name,<<"replication_changes_left">>},
                         {desc,<<"Number of mutations to be replicated to other clusters"
                                 "(measured from replication_changes_left).">>}]},
                {struct,[{title,<<"Intra-Replication Queue">>},
                         {name,<<"ep_dcp_replica_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to producer in this bucket (measured from ep_dcp_replica_items_remaining)">>}]}
             ]}]},
     {struct,[{blockName,<<"vBucket Resources">>},
              {extraCSSClasses,<<"dynamic_withtotal dynamic_closed">>},
              {columns,
               [<<"Active">>,<<"Replica">>,<<"Pending">>,<<"Total">>]},
              {stats,
               [{struct,[{title,<<"vBuckets">>},
                         {name,<<"vb_active_num">>},
                         {desc,<<"Number of vBuckets in the \"active\" state for this bucket (measured from vb_active_num)">>}]},
                {struct,[{title,<<"vBuckets">>},
                         {name,<<"vb_replica_num">>},
                         {desc,<<"Number of vBuckets in the \"replica\" state for this bucket (measured from vb_replica_num)">>}]},
                {struct,[{title,<<"vBuckets">>},
                         {name,<<"vb_pending_num">>},
                         {desc,<<"Number of vBuckets in the \"pending\" state for this bucket and should be transient during rebalancing (measured from vb_pending_num)">>}]},
                {struct,[{title,<<"vBuckets">>},
                         {name,<<"ep_vb_total">>},
                         {desc,<<"Total number of vBuckets for this bucket (measured from ep_vb_total)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"curr_items">>},
                         {desc,<<"Number of items in \"active\" vBuckets in this bucket (measured from curr_items)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"vb_replica_curr_items">>},
                         {desc,<<"Number of items in \"replica\" vBuckets in this bucket (measured from vb_replica_curr_items)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"vb_pending_curr_items">>},
                         {desc,<<"Number of items in \"pending\" vBuckets in this bucket and should be transient during rebalancing (measured from vb_pending_curr_items)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"curr_items_tot">>},
                         {desc,<<"Total number of items in this bucket (measured from curr_items_tot)">>}]},
                {struct,[{title,<<"resident %">>},
                         {name,<<"vb_active_resident_items_ratio">>},
                         {desc,<<"Percentage of active items cached in RAM in this bucket (measured from vb_active_resident_items_ratio)">>},
                         {maxY,100}]},
                {struct,[{title,<<"resident %">>},
                         {name,<<"vb_replica_resident_items_ratio">>},
                         {desc,<<"Percentage of replica items cached in RAM in this bucket (measured from vb_replica_resident_items_ratio)">>},
                         {maxY,100}]},
                {struct,[{title,<<"resident %">>},
                         {name,<<"vb_pending_resident_items_ratio">>},
                         {desc,<<"Percentage of items in pending state vbuckets cached in RAM in this bucket (measured from vb_pending_resident_items_ratio)">>},
                         {maxY,100}]},
                {struct,[{title,<<"resident %">>},
                         {name,<<"ep_resident_items_rate">>},
                         {desc,<<"Percentage of all items cached in RAM in this bucket (measured from ep_resident_items_rate)">>},
                         {maxY,100}]},
                {struct,[{title,<<"new items per sec.">>},
                         {name,<<"vb_active_ops_create">>},
                         {desc,<<"New items per second being inserted into \"active\" vBuckets in this bucket (measured from vb_active_ops_create)">>}]},
                {struct,[{title,<<"new items per sec.">>},
                         {name,<<"vb_replica_ops_create">>},
                         {desc,<<"New items per second being inserted into \"replica\" vBuckets in this bucket (measured from vb_replica_ops_create">>}]},
                {struct,[{title,<<"new items per sec.">>},
                         {name,<<"vb_pending_ops_create">>},
                         {desc,<<"New items per second being instead into \"pending\" vBuckets in this bucket and should be transient during rebalancing (measured from vb_pending_ops_create)">>}]},
                {struct,[{title,<<"new items per sec.">>},
                         {name,<<"ep_ops_create">>},
                         {desc,<<"Total number of new items being inserted into this bucket (measured from ep_ops_create)">>}]},
                {struct,[{title,<<"ejections per sec.">>},
                         {name,<<"vb_active_eject">>},
                         {desc,<<"Number of items per second being ejected to disk from \"active\" vBuckets in this bucket (measured from vb_active_eject)">>}]},
                {struct,[{title,<<"ejections per sec.">>},
                         {name,<<"vb_replica_eject">>},
                         {desc,<<"Number of items per second being ejected to disk from \"replica\" vBuckets in this bucket (measured from vb_replica_eject)">>}]},
                {struct,[{title,<<"ejections per sec.">>},
                         {name,<<"vb_pending_eject">>},
                         {desc,<<"Number of items per second being ejected to disk from \"pending\" vBuckets in this bucket and should be transient during rebalancing (measured from vb_pending_eject)">>}]},
                {struct,[{title,<<"ejections per sec.">>},
                         {name,<<"ep_num_value_ejects">>},
                         {desc,<<"Total number of items per second being ejected to disk in this bucket (measured from ep_num_value_ejects)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"user data in RAM">>},
                         {name,<<"vb_active_itm_memory">>},
                         {desc,<<"Amount of active user data cached in RAM in this bucket (measured from vb_active_itm_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"user data in RAM">>},
                         {name,<<"vb_replica_itm_memory">>},
                         {desc,<<"Amount of replica user data cached in RAM in this bucket (measured from vb_replica_itm_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"user data in RAM">>},
                         {name,<<"vb_pending_itm_memory">>},
                         {desc,<<"Amount of pending user data cached in RAM in this bucket and should be transient during rebalancing (measured from vb_pending_itm_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"user data in RAM">>},
                         {name,<<"ep_kv_size">>},
                         {desc,<<"Total amount of user data cached in RAM in this bucket (measured from ep_kv_size)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"metadata in RAM">>},
                         {name,<<"vb_active_meta_data_memory">>},
                         {desc,<<"Amount of active item metadata consuming RAM in this bucket (measured from vb_active_meta_data_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"metadata in RAM">>},
                         {name,<<"vb_replica_meta_data_memory">>},
                         {desc,<<"Amount of replica item metadata consuming in RAM in this bucket (measured from vb_replica_meta_data_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"metadata in RAM">>},
                         {name,<<"vb_pending_meta_data_memory">>},
                         {desc,<<"Amount of pending item metadata consuming RAM in this bucket and should be transient during rebalancing (measured from vb_pending_meta_data_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"metadata in RAM">>},
                         {name,<<"ep_meta_data_memory">>},
                         {desc,<<"Total amount of item  metadata consuming RAM in this bucket (measured from ep_meta_data_memory)">>}]}]}]},
     {struct,[{blockName,<<"Disk Queues">>},
              {extraCSSClasses,<<"dynamic_withtotal dynamic_closed">>},
              {columns,
               [<<"Active">>,<<"Replica">>,<<"Pending">>,<<"Total">>]},
              {stats,
               [{struct,[{title,<<"items">>},
                         {name,<<"vb_active_queue_size">>},
                         {desc,<<"Number of active items waiting to be written to disk in this bucket (measured from vb_active_queue_size)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"vb_replica_queue_size">>},
                         {desc,<<"Number of replica items waiting to be written to disk in this bucket (measured from vb_replica_queue_size)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"vb_pending_queue_size">>},
                         {desc,<<"Number of pending items waiting to be written to disk in this bucket and should be transient during rebalancing  (measured from vb_pending_queue_size)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"ep_diskqueue_items">>},
                         {desc,<<"Total number of items waiting to be written to disk in this bucket (measured from ep_diskqueue_items)">>}]},
                {struct,[{title,<<"fill rate">>},
                         {name,<<"vb_active_queue_fill">>},
                         {desc,<<"Number of active items per second being put on the active item disk queue in this bucket (measured from vb_active_queue_fill)">>}]},
                {struct,[{title,<<"fill rate">>},
                         {name,<<"vb_replica_queue_fill">>},
                         {desc,<<"Number of replica items per second being put on the replica item disk queue in this bucket (measured from vb_replica_queue_fill)">>}]},
                {struct,[{title,<<"fill rate">>},
                         {name,<<"vb_pending_queue_fill">>},
                         {desc,<<"Number of pending items per second being put on the pending item disk queue in this bucket and should be transient during rebalancing (measured from vb_pending_queue_fill)">>}]},
                {struct,[{title,<<"fill rate">>},
                         {name,<<"ep_diskqueue_fill">>},
                         {desc,<<"Total number of items per second being put on the disk queue in this bucket (measured from ep_diskqueue_fill)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"vb_active_queue_drain">>},
                         {desc,<<"Number of active items per second being written to disk in this bucket (measured from vb_active_queue_drain)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"vb_replica_queue_drain">>},
                         {desc,<<"Number of replica items per second being written to disk in this bucket (measured from vb_replica_queue_drain)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"vb_pending_queue_drain">>},
                         {desc,<<"Number of pending items per second being written to disk in this bucket and should be transient during rebalancing (measured from vb_pending_queue_drain)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"ep_diskqueue_drain">>},
                         {desc,<<"Total number of items per second being written to disk in this bucket (measured from ep_diskqueue_drain)">>}]},
                {struct,[{title,<<"average age">>},
                         {name,<<"vb_avg_active_queue_age">>},
                         {desc,<<"Average age in seconds of active items in the active item queue for this bucket (measured from vb_avg_active_queue_age)">>}]},
                {struct,[{title,<<"average age">>},
                         {name,<<"vb_avg_replica_queue_age">>},
                         {desc,<<"Average age in seconds of replica items in the replica item queue for this bucket (measured from vb_avg_replica_queue_age)">>}]},
                {struct,[{title,<<"average age">>},
                         {name,<<"vb_avg_pending_queue_age">>},
                         {desc,<<"Average age in seconds of pending items in the pending item queue for this bucket and should be transient during rebalancing (measured from vb_avg_pending_queue_age)">>}]},
                {struct,[{title,<<"average age">>},
                         {name,<<"vb_avg_total_queue_age">>},
                         {desc,<<"Average age in seconds of all items in the disk write queue for this bucket (measured from vb_avg_total_queue_age)">>}]}]}]},
     {struct,[{blockName,<<"Tap Queues">>},
              {extraCSSClasses,<<"dynamic_withtotal dynamic_closed">>},
              {columns,
               [<<"Replication">>,<<"Rebalance">>,<<"Clients">>,<<"Total">>]},
              {stats,
               [{struct,[{title,<<"TAP senders">>},
                         {name,<<"ep_tap_replica_count">>},
                         {desc,<<"Number of internal replication TAP queues in this bucket (measured from ep_tap_replica_count)">>}]},
                {struct,[{title,<<"TAP senders">>},
                         {name,<<"ep_tap_rebalance_count">>},
                         {desc,<<"Number of internal rebalancing TAP queues in this bucket (measured from ep_tap_rebalance_count)">>}]},
                {struct,[{title,<<"TAP senders">>},
                         {name,<<"ep_tap_user_count">>},
                         {desc,<<"Number of internal \"user\" TAP queues in this bucket (measured from ep_tap_user_count)">>}]},
                {struct,[{title,<<"TAP senders">>},
                         {name,<<"ep_tap_total_count">>},
                         {desc,<<"Total number of internal TAP queues in this bucket (measured from ep_tap_total_count)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"ep_tap_replica_qlen">>},
                         {desc,<<"Number of items in the replication TAP queues in this bucket (measured from ep_tap_replica_qlen)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"ep_tap_rebalance_qlen">>},
                         {desc,<<"Number of items in the rebalance TAP queues in this bucket (measured from ep_tap_rebalance_qlen)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"ep_tap_user_qlen">>},
                         {desc,<<"Number of items in \"user\" TAP queues in this bucket (measured from ep_tap_user_qlen)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"ep_tap_total_qlen">>},
                         {desc,<<"Total number of items in TAP queues in this bucket (measured from ep_tap_total_qlen)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"ep_tap_replica_queue_drain">>},
                         {desc,<<"Number of items per second being sent over replication TAP connections to this bucket, i.e. removed from queue (measured from ep_tap_replica_queue_drain)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"ep_tap_rebalance_queue_drain">>},
                         {desc,<<"Number of items per second being sent over rebalancing TAP connections to this bucket, i.e. removed from queue (measured from ep_tap_rebalance_queue_drain)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"ep_tap_user_queue_drain">>},
                         {desc,<<"Number of items per second being sent over \"user\" TAP connections to this bucket, i.e. removed from queue (measured from ep_tap_user_queue_drain)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"ep_tap_total_queue_drain">>},
                         {desc,<<"Total number of items per second being sent over TAP connections to this bucket (measured from ep_tap_total_queue_drain)">>}]},
                {struct,[{title,<<"back-off rate">>},
                         {name,<<"ep_tap_replica_queue_backoff">>},
                         {desc,<<"Number of back-offs received per second while sending data over replication TAP connections to this bucket (measured from ep_tap_replica_queue_backoff)">>}]},
                {struct,[{title,<<"back-off rate">>},
                         {name,<<"ep_tap_rebalance_queue_backoff">>},
                         {desc,<<"Number of back-offs received per second while sending data over rebalancing TAP connections to this bucket (measured from ep_tap_rebalance_queue_backoff)">>}]},
                {struct,[{title,<<"back-off rate">>},
                         {name,<<"ep_tap_user_queue_backoff">>},
                         {desc,<<"Number of back-offs received per second while sending data over \"user\" TAP connections to this bucket (measured from ep_tap_user_queue_backoff)">>}]},
                {struct,[{title,<<"back-off rate">>},
                         {name,<<"ep_tap_total_queue_backoff">>},
                         {desc,<<"Total number of back-offs received per second while sending data over TAP connections to this bucket (measured from ep_tap_total_queue_backoff)">>}]},
                {struct,[{title,<<"backfill remaining">>},
                         {name,<<"ep_tap_replica_queue_backfillremaining">>},
                         {desc,<<"Number of items in the backfill queues of replication TAP connections for this bucket (measured from ep_tap_replica_queue_backfillremaining)">>}]},
                {struct,[{title,<<"backfill remaining">>},
                         {name,<<"ep_tap_rebalance_queue_backfillremaining">>},
                         {desc,<<"Number of items in the backfill queues of rebalancing TAP connections to this bucket (measured from ep_tap_rebalance_queue_backfillreamining)">>}]},
                {struct,[{title,<<"backfill remaining">>},
                         {name,<<"ep_tap_user_queue_backfillremaining">>},
                         {desc,<<"Number of items in the backfill queues of \"user\" TAP connections to this bucket (measured from ep_tap_user_queue_backfillremaining)">>}]},
                {struct,[{title,<<"backfill remaining">>},
                         {name,<<"ep_tap_total_queue_backfillremaining">>},
                         {desc,<<"Total number of items in the backfill queues of TAP connections to this bucket (measured from ep_tap_total_queue_backfillremaining)">>}]},
                {struct,[{title,<<"remaining on disk">>},
                         {name,<<"ep_tap_replica_queue_itemondisk">>},
                         {desc,<<"Number of items still on disk to be loaded for replication TAP connections to this bucket (measured from ep_tap_replica_queue_itemondisk)">>}]},
                {struct,[{title,<<"remaining on disk">>},
                         {name,<<"ep_tap_rebalance_queue_itemondisk">>},
                         {desc,<<"Number of items still on disk to be loaded for rebalancing TAP connections to this bucket (measured from ep_tap_rebalance_queue_itemondisk)">>}]},
                {struct,[{title,<<"remaining on disk">>},
                         {name,<<"ep_tap_user_queue_itemondisk">>},
                         {desc,<<"Number of items still on disk to be loaded for \"client\" TAP connections to this bucket (measured from ep_tap_user_queue_itemondisk)">>}]},
                {struct,[{title,<<"remaining on disk">>},
                         {name,<<"ep_tap_total_queue_itemondisk">>},
                         {desc,<<"Total number of items still on disk to be loaded for TAP connections to this bucket (measured from ep_tap_total_queue_itemonsidk)">>}]}]}]},
     {struct,[{blockName,<<"DCP Queues">>},
              {extraCSSClasses,<<"dynamic_closed">>},
              {columns,
               [<<"Replication">>,<<"XDCR">>,<<"Views">>,<<"Other">>]},
              {stats,
               [{struct,[{title,<<"DCP connections">>},
                         {name,<<"ep_dcp_replica_count">>},
                         {desc,<<"Number of internal replication DCP connections in this bucket (measured from ep_dcp_replica_count)">>}]},
                {struct,[{title,<<"DCP connections">>},
                         {name,<<"ep_dcp_xdcr_count">>},
                         {desc,<<"Number of internal xdcr DCP connections in this bucket (measured from ep_dcp_xdcr_count)">>}]},
                {struct,[{title,<<"DCP connections">>},
                         {name,<<"ep_dcp_views_count">>},
                         {desc,<<"Number of internal views DCP connections in this bucket (measured from ep_dcp_views_count)">>}]},
                {struct,[{title,<<"DCP connections">>},
                         {name,<<"ep_dcp_other_count">>},
                         {desc,<<"Number of other DCP connections in this bucket (measured from ep_dcp_other_count)">>}]},
                {struct,[{title,<<"DCP senders">>},
                         {name,<<"ep_dcp_replica_producer_count">>},
                         {desc,<<"Number of replication senders for this bucket (measured from ep_dcp_replica_producer_count)">>}]},
                {struct,[{title,<<"DCP senders">>},
                         {name,<<"ep_dcp_xdcr_producer_count">>},
                         {desc,<<"Number of xdcr senders for this bucket (measured from ep_dcp_xdcr_producer_count)">>}]},
                {struct,[{title,<<"DCP senders">>},
                         {name,<<"ep_dcp_views_producer_count">>},
                         {desc,<<"Number of views senders for this bucket (measured from ep_dcp_views_producer_count)">>}]},
                {struct,[{title,<<"DCP senders">>},
                         {name,<<"ep_dcp_other_producer_count">>},
                         {desc,<<"Number of other senders for this bucket (measured from ep_dcp_other_producer_count)">>}]},
                {struct,[{title,<<"items remaining">>},
                         {name,<<"ep_dcp_replica_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to producer in this bucket (measured from ep_dcp_replica_items_remaining)">>}]},
                {struct,[{title,<<"items remaining">>},
                         {name,<<"ep_dcp_xdcr_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to producer in this bucket (measured from ep_dcp_xdcr_items_remaining)">>}]},
                {struct,[{title,<<"items remaining">>},
                         {name,<<"ep_dcp_views_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to producer in this bucket (measured from ep_dcp_views_items_remaining)">>}]},
                {struct,[{title,<<"items remaining">>},
                         {name,<<"ep_dcp_other_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to producer in this bucket (measured from ep_dcp_other_items_remaining)">>}]},
                {struct,[{title,<<"drain rate items/sec">>},
                         {name,<<"ep_dcp_replica_items_sent">>},
                         {desc,<<"Number of items per second being sent for a producer for this bucket (measured from ep_dcp_replica_items_sent)">>}]},
                {struct,[{title,<<"drain rate items/sec">>},
                         {name,<<"ep_dcp_xdcr_items_sent">>},
                         {desc,<<"Number of items per second being sent for a producer for this bucket (measured from ep_dcp_xdcr_items_sent)">>}]},
                {struct,[{title,<<"drain rate items/sec">>},
                         {name,<<"ep_dcp_views_items_sent">>},
                         {desc,<<"Number of items per second being sent for a producer for this bucket (measured from ep_dcp_views_items_sent)">>}]},
                {struct,[{title,<<"drain rate items/sec">>},
                         {name,<<"ep_dcp_other_items_sent">>},
                         {desc,<<"Number of items per second being sent for a producer for this bucket (measured from ep_dcp_other_items_sent)">>}]},
                {struct,[{title,<<"drain rate bytes/sec">>},
                         {name,<<"ep_dcp_replica_total_bytes">>},
                         {desc,<<"Number of bytes per second being sent for replication DCP connections for this bucket (measured from ep_dcp_replica_total_bytes)">>}]},
                {struct,[{title,<<"drain rate bytes/sec">>},
                         {name,<<"ep_dcp_xdcr_total_bytes">>},
                         {desc,<<"Number of bytes per second being sent for xdcr DCP connections for this bucket (measured from ep_dcp_xdcr_total_bytes)">>}]},
                {struct,[{title,<<"drain rate bytes/sec">>},
                         {name,<<"ep_dcp_views_total_bytes">>},
                         {desc,<<"Number of bytes per second being sent for views DCP connections for this bucket (measured from ep_dcp_views_total_bytes)">>}]},
                {struct,[{title,<<"drain rate bytes/sec">>},
                         {name,<<"ep_dcp_other_total_bytes">>},
                         {desc,<<"Number of bytes per second being sent for other DCP connections for this bucket (measured from ep_dcp_other_total_bytes)">>}]},
                {struct, [{title, <<"backoffs/sec">>},
                          {name, <<"ep_dcp_replica_backoff">>},
                          {desc,<<"Number of backoffs for replication DCP connections">>}]},
                {struct, [{title, <<"backoffs/sec">>},
                          {name, <<"ep_dcp_xdcr_backoff">>},
                          {desc,<<"Number of backoffs for xdcr DCP connections">>}]},
                {struct, [{title, <<"backoffs/sec">>},
                          {name, <<"ep_dcp_views_backoff">>},
                          {desc,<<"Number of backoffs for views DCP connections">>}]},
                {struct, [{title, <<"backoffs/sec">>},
                          {name, <<"ep_dcp_other_backoff">>},
                          {desc,<<"Number of backoffs for other DCP connections">>}]}
               ]}]}]
        ++ couchbase_view_stats_descriptions(BucketId)
        ++ couchbase_replication_stats_descriptions(BucketId)
        ++ [{struct,[{blockName,<<"Incoming XDCR Operations">>},
                     {bigTitlePrefix, <<"Incoming XDCR">>},
                     {extraCSSClasses,<<"dynamic_closed">>},
                     {stats,
                      [{struct,[{title,<<"metadata reads per sec.">>},
                                {bigTitle,<<"Incoming XDCR metadata reads per sec.">>},
                                {name,<<"ep_num_ops_get_meta">>},
                                {desc,<<"Number of metadata read operations per second for this bucket as the target for XDCR "
                                        "(measured from ep_num_ops_get_meta)">>}]},
                       {struct,[{title,<<"sets per sec.">>},
                                {name,<<"ep_num_ops_set_meta">>},
                                {desc,<<"Number of set operations per second for this bucket as the target for XDCR"
                                        "(measured from ep_num_ops_set_meta)">>}]},
                       {struct,[{title,<<"deletes per sec.">>},
                                {name,<<"ep_num_ops_del_meta">>},
                                {desc,<<"Number of delete operations per second for this bucket as the target for XDCR "
                                        "(measured from ep_num_ops_del_meta)">>}]},
                       {struct,[{title,<<"total ops per sec.">>},
                                {bigTitle, <<"Incoming XDCR total ops/sec.">>},
                                {name,<<"xdc_ops">>},
                                {desc,<<"Total XDCR operations per second for this bucket "
                                        "(measured from xdc_ops).">>}]}]}]}].


memcached_stats_description() ->
    [{struct,[{blockName,<<"Memcached">>},
              {stats,
               [{struct,[{name,<<"ops">>},
                         {title,<<"ops per sec.">>},
                         {default,true},
                         {desc,<<"Total operations per second serviced by this bucket (measured from cmd_get + cmd_set + incr_misses + incr_hits + decr_misses + decr_hits + delete_misses + delete_hits + get_meta + set_meta + delete_meta)">>}]},
                {struct,[{name,<<"hit_ratio">>},
                         {title,<<"hit ratio">>},
                         {maxY,100},
                         {desc,<<"Percentage of get requests served with data from this bucket (measured from get_hits * 100/cmd_get)">>}]},
                {struct,[{isBytes,true},
                         {name,<<"mem_used">>},
                         {title,<<"RAM used">>},
                         {desc,<<"Total amount of RAM used by this bucket (measured from mem_used)">>}]},
                {struct,[{name,<<"curr_items">>},
                         {title,<<"items">>},
                         {desc,<<"Number of items stored in this bucket (measured from curr_items)">>}]},
                {struct,[{name,<<"evictions">>},
                         {title,<<"evictions per sec.">>},
                         {desc,<<"Number of items per second evicted from this bucket (measured from evictions)">>}]},
                {struct,[{name,<<"cmd_set">>},
                         {title,<<"sets per sec.">>},
                         {desc,<<"Number of set operations serviced by this bucket (measured from cmd_set)">>}]},
                {struct,[{name,<<"cmd_get">>},
                         {title,<<"gets per sec.">>},
                         {desc,<<"Number of get operations serviced by this bucket (measured from cmd_get)">>}]},
                {struct,[{name,<<"bytes_written">>},
                         {title,<<"bytes TX per sec.">>},
                         {desc,<<"Number of bytes per second sent from this bucket (measured from bytes_written)">>}]},
                {struct,[{name,<<"bytes_read">>},
                         {title,<<"bytes RX per sec.">>},
                         {desc,<<"Number of bytes per second sent into this bucket (measured from bytes_read)">>}]},
                {struct,[{name,<<"get_hits">>},
                         {title,<<"get hits per sec.">>},
                         {desc,<<"Number of get operations per second for data that this bucket contains (measured from get_hits)">>}]},
                {struct,[{name,<<"delete_hits">>},
                         {title,<<"delete hits per sec.">>},
                         {desc,<<"Number of delete operations per second for data that this bucket contains (measured from delete_hits)">>}]},
                {struct,[{name,<<"incr_hits">>},
                         {title,<<"incr hits per sec.">>},
                         {desc,<<"Number of increment operations per second for data that this bucket contains (measured from incr_hits)">>}]},
                {struct,[{name,<<"decr_hits">>},
                         {title,<<"decr hits per sec.">>},
                         {desc,<<"Number of decrement operations per second for data that this bucket contains (measured from decr_hits)">>}]},
                {struct,[{name,<<"delete_misses">>},
                         {title,<<"delete misses per sec.">>},
                         {desc,<<"Number of delete operations per second for data that this bucket does not contain (measured from delete_misses)">>}]},
                {struct,[{name,<<"decr_misses">>},
                         {title,<<"decr misses per sec.">>},
                         {desc,<<"Number of decr operations per second for data that this bucket does not contain (measured from decr_misses)">>}]},
                {struct,[{name,<<"get_misses">>},
                         {title,<<"get misses per sec.">>},
                         {desc,<<"Number of get operations per second for data that this bucket does not contain (measured from get_misses)">>}]},
                {struct,[{name,<<"incr_misses">>},
                         {title,<<"incr misses per sec.">>},
                         {desc,<<"Number of increment operations per second for data that this bucket does not contain (measured from incr_misses)">>}]},
                {struct,[{name,<<"cas_hits">>},
                         {title,<<"CAS hits per sec.">>},
                         {desc,<<"Number of CAS operations per second for data that this bucket contains (measured from cas_hits)">>}]},
                {struct,[{name,<<"cas_badval">>},
                         {title,<<"CAS badval per sec.">>},
                         {desc,<<"Number of CAS operations per second using an incorrect CAS ID for data that this bucket contains (measured from cas_badval)">>}]},
                {struct,[{name,<<"cas_misses">>},
                         {title,<<"CAS misses per sec.">>},
                         {desc,<<"Number of CAS operations per second for data that this bucket does not contain (measured from cas_misses)">>}]}]}]}].

server_resources_stats_description() ->
    [{blockName,<<"Server Resources">>},
     {serverResources, true},
     {stats,
      [{struct,[{isBytes,true},
                {name,<<"swap_used">>},
                {title,<<"swap usage">>},
                {desc,<<"Amount of swap space in use on this server">>}]},
       {struct,[{isBytes,true},
                {name,<<"mem_actual_free">>},
                {title,<<"free RAM">>},
                {desc,<<"Amount of RAM available on this server">>}]},
       {struct,[{name,<<"cpu_utilization_rate">>},
                {title,<<"CPU utilization %">>},
                {desc,<<"Percentage of CPU in use across all available cores on this server">>},
                {maxY,100}]},
       {struct,[{name,<<"curr_connections">>},
                {title,<<"connections">>},
                {desc,<<"Number of connections to this server including"
                        "connections from external client SDKs, proxies, "
                        "TAP requests and internal statistic gathering "
                        "(measured from curr_connections)">>}]},
       {struct,[{name,<<"rest_requests">>},
                {title,<<"port 8091 reqs/sec">>},
                {desc,<<"Rate of http requests on port 8091">>}]},
       {struct,[{name,<<"hibernated_requests">>},
                {title,<<"idle streaming requests">>},
                {desc,<<"Number of streaming requests on port 8091 now idle">>}]},
       {struct,[{name,<<"hibernated_waked">>},
                {title,<<"streaming wakeups/sec">>},
                {desc,<<"Rate of streaming request wakeups on port 8091">>}]}]}].

serve_stats_directory(_PoolId, BucketId, Req) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(BucketId),
    BaseDescription = case ns_bucket:bucket_type(BucketConfig) of
                          membase -> membase_stats_description(BucketId);
                          memcached -> memcached_stats_description()
                      end,
    BaseDescription1 = [{struct, server_resources_stats_description()} | BaseDescription],
    Prefix = menelaus_util:concat_url_path(["pools", "default", "buckets", BucketId, "stats"]),
    Desc = [{struct, add_specific_stats_url(BD, Prefix)} || {struct, BD} <- BaseDescription1],
    menelaus_util:reply_json(Req, {struct, [{blocks, Desc}]}).

add_specific_stats_url(BlockDesc, Prefix) ->
    {stats, Infos} = lists:keyfind(stats, 1, BlockDesc),
    NewInfos =
        [{struct, [{specificStatsURL, begin
                                          {name, Name} = lists:keyfind(name, 1, KV),
                                          iolist_to_binary([Prefix, $/, mochiweb_util:quote_plus(Name)])
                                      end} |
                   KV]} || {struct, KV} <- Infos],
    lists:keyreplace(stats, 1, BlockDesc, {stats, NewInfos}).
