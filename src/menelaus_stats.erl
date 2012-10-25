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
         basic_stats/2, basic_stats/3,
         bucket_disk_usage/1,
         bucket_ram_usage/1,
         serve_stats_directory/3]).

%% External API
bucket_disk_usage(BucketName) ->
    {_, _, _, _, DiskUsed, _, _}
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

last_membase_sample(BucketName, Nodes) ->
    lists:foldl(fun ({_Node, []}, Acc) -> Acc;
                    ({_Node, [Sample|_]}, {AccMem, AccItems, AccOps, AccFetches, AccDisk, AccData, AccViewsOps}) ->
                        {extract_stat(mem_used, Sample) + AccMem,
                         extract_stat(curr_items, Sample) + AccItems,
                         extract_stat(ops, Sample) + AccOps,
                         extract_stat(ep_bg_fetched, Sample) + AccFetches,
                         extract_stat(couch_docs_actual_disk_size, Sample) +
                           extract_stat(couch_views_actual_disk_size, Sample) + AccDisk,
                         extract_stat(couch_docs_data_size, Sample) + AccData,
                         extract_stat(couch_views_ops, Sample) + AccViewsOps}
                end, {0, 0, 0, 0, 0, 0, 0}, invoke_archiver(BucketName, Nodes, {1, minute, 1})).

last_memcached_sample(BucketName, Nodes) ->
    {MemUsed,
     CurrItems,
     Ops,
     CmdGet,
     GetHits} = lists:foldl(fun ({_Node, []}, Acc) -> Acc;
                                ({_Node, [Sample|_]}, {AccMem, AccItems, AccOps, AccGet, AccGetHits}) ->
                                    {extract_stat(mem_used, Sample) + AccMem,
                                     extract_stat(curr_items, Sample) + AccItems,
                                     extract_stat(ops, Sample) + AccOps,
                                     extract_stat(cmd_get, Sample) + AccGet,
                                     extract_stat(get_hits, Sample) + AccGetHits}
                            end, {0, 0, 0, 0, 0}, invoke_archiver(BucketName, Nodes, {1, minute, 1})),
    {MemUsed,
     CurrItems,
     Ops,
     case CmdGet == 0 of
         true -> 0;
         _ -> GetHits / CmdGet
     end}.

last_bucket_stats(membase, BucketName, Nodes) ->
    {MemUsed, ItemsCount, Ops, Fetches, Disk, Data, ViewOps}
        = last_membase_sample(BucketName, Nodes),
    [{opsPerSec, Ops},
     {viewOps, ViewOps},
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

basic_stats(BucketName, Nodes) ->
    basic_stats(BucketName, Nodes, undefined).

basic_stats(BucketName, Nodes, MaybeBucketConfig) ->
    {ok, BucketConfig} = ns_bucket:maybe_get_bucket(BucketName, MaybeBucketConfig),
    QuotaBytes = ns_bucket:ram_quota(BucketConfig),
    Stats = last_bucket_stats(ns_bucket:bucket_type(BucketConfig), BucketName, Nodes),
    MemUsed = proplists:get_value(memUsed, Stats),
    QuotaPercent = try (MemUsed * 100.0 / QuotaBytes) of
                       X -> X
                   catch
                       error:badarith -> 0
                   end,
    [{quotaPercentUsed, lists:min([QuotaPercent, 100])}
     | Stats].

basic_stats(BucketName) ->
    basic_stats(BucketName, ns_bucket:live_bucket_nodes(BucketName)).

handle_overview_stats(PoolId, Req) ->
    Names = lists:sort(menelaus_web_buckets:all_accessible_bucket_names(PoolId, Req)),
    AllSamples = lists:map(fun (Name) ->
                                   element(1, grab_aggregate_op_stats(Name, all, [{"zoom", "hour"}]))
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

%% GET /pools/default/stats
%% Supported query params:
%%  resampleForUI - pass 1 if you need 60 samples
%%  zoom - stats zoom level (minute | hour | day | week | month | year)
%%  haveTStamp - omit samples earlier than given
%%
%% Response:
%%  {hot_keys: [{name: "key, ops: 12.4}, ...],
%%   op: {lastTStamp: 123343434, // last timestamp in served samples. milliseconds
%%        tstampParam: 123342434, // haveTStamp param is given, understood and found
%%        interval: 1000, // samples interval in milliseconds
%%        samplesCount: 60, // number of samples that cover selected zoom level
%%        samples: {timestamp: [..tstamps..],
%%                  ops: [..ops samples..],
%%                  ...}
%%        }}

handle_bucket_stats(PoolId, all, Req) ->
    BucketNames = menelaus_web_buckets:all_accessible_bucket_names(PoolId, Req),
    handle_buckets_stats(PoolId, BucketNames, Req);

%% GET /pools/{PoolID}/buckets/{Id}/stats
handle_bucket_stats(PoolId, Id, Req) ->
    handle_buckets_stats(PoolId, [Id], Req).

handle_buckets_stats(PoolId, BucketIds, Req) ->
    Params = Req:parse_qs(),
    {struct, PropList1} = build_buckets_stats_ops_response(PoolId, all, BucketIds, Params),
    {struct, PropList2} = build_buckets_stats_hks_response(PoolId, BucketIds),
    menelaus_util:reply_json(Req, {struct, PropList1 ++ PropList2}).

%% Per-Node Stats
%% GET /pools/{PoolID}/buckets/{Id}/nodes/{NodeId}/stats
%%
%% Per-node stats match bucket stats with the addition of a 'hostname' key,
%% stats specific to the node (obviously), and removal of any cross-node stats
handle_bucket_node_stats(PoolId, BucketName, HostName, Req) ->
    menelaus_web:checking_bucket_hostname_access(
      PoolId, BucketName, HostName, Req,
      fun (_Req, _BucketInfo, HostInfo) ->
              Node = binary_to_atom(proplists:get_value(otpNode, HostInfo), latin1),
              Params = Req:parse_qs(),
              {struct, [{op, {struct, OpsPropList}}]} = build_buckets_stats_ops_response(PoolId, [Node], [BucketName], Params),

              SystemStatsSamples =
                  case grab_aggregate_op_stats("@system", [Node], Params) of
                      {SystemRawSamples, _, _, _} ->
                          samples_to_proplists(SystemRawSamples)
                  end,
              {samples, {struct, OpsSamples}} = lists:keyfind(samples, 1, OpsPropList),

              ModifiedOpsPropList = lists:keyreplace(samples, 1, OpsPropList, {samples, {struct, SystemStatsSamples ++ OpsSamples}}),
              Ops = [{op, {struct, ModifiedOpsPropList}}],

              {struct, HKS} = jsonify_hks(hot_keys_keeper:bucket_hot_keys(BucketName, Node)),
              menelaus_util:reply_json(
                Req,
                {struct, [{hostname, list_to_binary(HostName)}
                          | HKS ++ Ops]})
      end).

%% Specific Stat URL for all buckets
%% GET /pools/{PoolID}/buckets/{Id}/stats/{StatName}
handle_specific_stat_for_buckets(PoolId, Id, StatName, Req) ->
    Params = Req:parse_qs(),
    case proplists:get_value("per_node", Params, "true") of
        undefined ->
            Req:respond({501, [], []});
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
handle_specific_stat_for_buckets_group_per_node(PoolId, BucketName, StatName, Req) ->
    menelaus_web_buckets:checking_bucket_access(
      PoolId, BucketName, Req,
      fun (_Pool, _BucketConfig) ->
              Params = Req:parse_qs(),
              menelaus_util:reply_json(
                Req,
                build_per_node_stats(BucketName, StatName, Params, menelaus_util:local_addr(Req)))
      end).

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

build_stat_extractor(StatName) ->
    ExtraStats = computed_stats_lazy_proplist(),

    Stat = try
               {ok, list_to_existing_atom(StatName)}
           catch
               error:badarg ->
                   error
           end,
    StatBinary = list_to_binary(StatName),

    case Stat of
        {ok, StatAtom} ->
            case lists:keyfind(StatAtom, 1, ExtraStats) of
                {_K, {F, Meta}} ->
                    fun (#stat_entry{timestamp = TS, values = VS}) ->
                            Args = [dict_safe_fetch(Name, VS, undefined) || Name <- Meta],
                            case lists:member(undefined, Args) of
                                true -> {TS, undefined};
                                _ -> {TS, erlang:apply(F, Args)}
                            end
                    end;
                false ->
                    build_simple_stat_extractor(StatAtom, StatBinary)
            end;
        error ->
            build_raw_stat_extractor(StatBinary)
    end.

dict_safe_fetch(K, Dict, Default) ->
    case orddict:find(K, Dict) of
        error -> Default;
        {ok, V} -> V
    end.

build_per_node_stats(BucketName, StatName, Params, LocalAddr) ->
    {MainSamples, Replies, ClientTStamp, {Step, _, Window}}
        = gather_op_stats(BucketName, all, Params),

    StatExtractor = build_stat_extractor(StatName),

    RestSamplesRaw = lists:keydelete(node(), 1, Replies),
    Nodes = [node() | [N || {N, _} <- RestSamplesRaw]],
    AllNodesSamples = [{node(), lists:reverse(MainSamples)} | RestSamplesRaw],

    NodesSamples = [lists:map(StatExtractor, NodeSamples) || {_, NodeSamples} <- AllNodesSamples],

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
    OpPropList0 = [{samplesCount, Window},
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
                                                      Hostnames, [MainValues | AllignedRestValues])}}],
    OpPropList = case ClientTStamp of
                     undefined -> OpPropList0;
                     _ -> [{tstampParam, ClientTStamp}
                           | OpPropList0]
                 end,
    {struct, OpPropList}.

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

grab_aggregate_op_stats(Bucket, Nodes, Params) ->
    {MainSamples, Replies, ClientTStamp, {Step, _, Window}} = gather_op_stats(Bucket, Nodes, Params),
    RV = merge_all_samples_normally(MainSamples, [S || {N,S} <- Replies, N =/= node()]),
    V = lists:reverse(RV),
    case V =/= [] andalso (hd(V))#stat_entry.timestamp of
        ClientTStamp -> {V, ClientTStamp, Step, Window};
        _ -> {V, undefined, Step, Window}
    end.

gather_op_stats(Bucket, Nodes, Params) ->
    ClientTStamp = case proplists:get_value("haveTStamp", Params) of
                       undefined -> undefined;
                       X -> try list_to_integer(X) of
                                XI -> XI
                            catch
                                _:_ -> undefined
                            end
                   end,
    {Step0, Period, Window0} = case proplists:get_value("zoom", Params) of
                         "minute" -> {1, minute, 60};
                         "hour" -> {60, hour, 900};
                         "day" -> {1440, day, 1440};
                         "week" -> {11520, week, 1152};
                         "month" -> {44640, month, 1488};
                         "year" -> {527040, year, 1464};
                         undefined -> {1, minute, 60}
                     end,
    {Step, Window} = case proplists:get_value("resampleForUI", Params) of
                         undefined -> {1, Window0};
                         _ -> {Step0, 60}
                     end,
    Self = self(),
    Ref = make_ref(),
    Subscription = ns_pubsub:subscribe_link(
                     ns_stats_event,
                     fun (_, done) -> done;
                         ({sample_archived, Name, _}, _)
                           when Name =:= Bucket ->
                             Self ! Ref,
                             done;
                         (_, X) -> X
                     end, []),
    %% don't wait next sample for anything other than real-time stats
    RefToPass = case Period of
                    minute -> Ref;
                    _ -> []
                end,
    try gather_op_stats_body(Bucket, Nodes, ClientTStamp, RefToPass,
                             {Step, Period, Window}) of
        Something -> Something
    after
        ns_pubsub:unsubscribe(Subscription),

        misc:flush(Ref)
    end.

invoke_archiver(Bucket, NodeS, {Step, Period, Window}) ->
    RV = case Step of
             1 ->
                 catch stats_reader:latest(Period, NodeS, Bucket, Window);
             _ ->
                 catch stats_reader:latest(Period, NodeS, Bucket, Step, Window)
         end,
    case is_list(NodeS) of
        true -> [{K, V} || {K, {ok, V}} <- RV];
        _ ->
            case RV of
                {ok, List} -> List;
                _ -> []
            end
    end.

gather_op_stats_body(Bucket, Nodes, ClientTStamp,
                   Ref, PeriodParams) ->
    FirstNode = case Nodes of
                    all -> node();
                    [X] -> X
                end,
    RV = invoke_archiver(Bucket, FirstNode, PeriodParams),
    case RV of
        [] -> {[], [], ClientTStamp, PeriodParams};
        [_] -> {[], [], ClientTStamp, PeriodParams};
        _ ->
            %% we throw out last sample 'cause it might be missing on other nodes yet
            %% previous samples should be ok on all live nodes
            Samples = tl(lists:reverse(RV)),
            LastTStamp = (hd(Samples))#stat_entry.timestamp,
            case LastTStamp of
                %% wait if we don't yet have fresh sample
                ClientTStamp when Ref =/= [] ->
                    receive
                        Ref ->
                            gather_op_stats_body(Bucket, Nodes, ClientTStamp, [], PeriodParams)
                    after 2000 ->
                            {[], [], ClientTStamp, PeriodParams}
                    end;
                _ ->
                    %% cut samples up-to and including ClientTStamp
                    CutSamples = lists:dropwhile(fun (Sample) ->
                                                         Sample#stat_entry.timestamp =/= ClientTStamp
                                                 end, lists:reverse(Samples)),
                    MainSamples = case CutSamples of
                                      [] -> Samples;
                                      _ -> lists:reverse(CutSamples)
                                  end,
                    OtherNodes = case Nodes of
                                     all -> ns_bucket:live_bucket_nodes(Bucket);
                                     [_] -> []
                                 end,
                    Replies = invoke_archiver(Bucket, OtherNodes, PeriodParams),
                    {MainSamples, Replies, ClientTStamp, PeriodParams}
            end
    end.

computed_stats_lazy_proplist() ->
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
    AvgActiveQueueAge = Z2(vb_active_queue_age, curr_items,
                           fun (ActiveAge, ActiveCount) ->
                                   try ActiveAge / ActiveCount / 1000
                                   catch error:badarith -> 0
                                   end
                           end),
    AvgReplicaQueueAge = Z2(vb_replica_queue_age, vb_replica_curr_items,
                            fun (ReplicaAge, ReplicaCount) ->
                                    try ReplicaAge / ReplicaCount / 1000
                                    catch error:badarith -> 0
                                    end
                            end),
    AvgPendingQueueAge = Z2(vb_pending_queue_age, vb_pending_curr_items,
                            fun (PendingAge, PendingCount) ->
                                    try PendingAge / PendingCount / 1000
                                    catch error:badarith -> 0
                                    end
                            end),
    AvgTotalQueueAge = Z2(vb_total_queue_age, curr_items_tot,
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
                                  catch error:badarith -> 0
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

    [{couch_total_disk_size, TotalDisk},
     {couch_docs_fragmentation, DocsFragmentation},
     {couch_views_fragmentation, ViewsFragmentation},
     {hit_ratio, HitRatio},
     {ep_cache_miss_rate, EPCacheMissRatio},
     {ep_resident_items_rate, ResidentItemsRatio},
     {vb_avg_active_queue_age, AvgActiveQueueAge},
     {vb_avg_replica_queue_age, AvgReplicaQueueAge},
     {vb_avg_pending_queue_age, AvgPendingQueueAge},
     {vb_avg_total_queue_age, AvgTotalQueueAge},
     {vb_active_resident_items_ratio, ActiveResRate},
     {vb_replica_resident_items_ratio, ReplicaResRate},
     {vb_pending_resident_items_ratio, PendingResRate},
     {avg_disk_update_time, AverageDiskUpdateTime},
     {avg_disk_commit_time, AverageCommitTime},
     {avg_bg_wait_time, AverageBgWait}].

%% converts list of samples to proplist of stat values.
%%
%% null values should be uncommon, but they are not impossible. They
%% will be used for samples which lack some particular stat, for
%% example due to older membase version. I.e. when we upgrade we
%% sometimes add new kinds of stats and null values are used to mark
%% those past samples that don't have new stats gathered.
-spec samples_to_proplists([#stat_entry{}]) -> [{atom(), [null | number()]}].
samples_to_proplists([]) -> [{timestamp, []}];
samples_to_proplists(Samples) ->
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
                                                case orddict:find(K, Sample#stat_entry.values) of
                                                    {ok, ThisValue} -> [ThisValue | AccValues];
                                                    _ -> [null | AccValues]
                                                end
                                        end, Acc)
                       end, InitialAcc, ReversedRest),

    ExtraStats = lists:map(fun ({K, {F, [StatNameA, StatNameB]}}) ->
                                   ResA = orddict:find(StatNameA, Dict),
                                   ResB = orddict:find(StatNameB, Dict),
                                   ValR = case {ResA, ResB} of
                                              {{ok, ValA}, {ok, ValB}} ->
                                                  lists:zipwith(F, ValA, ValB);
                                              _ -> undefined
                                          end,
                                   {K, ValR}
                           end, computed_stats_lazy_proplist()),

    lists:filter(fun ({_, undefined}) -> false;
                     ({_, _}) -> true
                 end, ExtraStats)
        ++ orddict:to_list(Dict).

build_buckets_stats_ops_response(_PoolId, Nodes, [BucketName], Params) ->
    {Samples, ClientTStamp, Step, TotalNumber} = grab_aggregate_op_stats(BucketName, Nodes, Params),


    PropList2 = samples_to_proplists(Samples),
    OpPropList0 = [{samples, {struct, PropList2}},
                   {samplesCount, TotalNumber},
                   {isPersistent, ns_bucket:is_persistent(BucketName)},
                   {lastTStamp, case proplists:get_value(timestamp, PropList2) of
                                    [] -> 0;
                                    L -> lists:last(L)
                                end},
                   {interval, Step * 1000}],
    OpPropList = case ClientTStamp of
                     undefined -> OpPropList0;
                     _ -> [{tstampParam, ClientTStamp}
                           | OpPropList0]
                 end,
    {struct, [{op, {struct, OpPropList}}]}.

is_safe_key_name(Name) ->
    lists:all(fun (C) ->
                      C >= 16#20 andalso C =< 16#7f
              end, Name).

build_buckets_stats_hks_response(_PoolId, [BucketName]) ->
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
    {struct, [{hot_keys, HotKeyStructs}]}.

aggregate_stat_kv_pairs([], _BValues, Acc) ->
    lists:reverse(Acc);
aggregate_stat_kv_pairs(APairs, [], Acc) ->
    lists:reverse(Acc, APairs);
aggregate_stat_kv_pairs([{AK, AV} = APair | ARest] = A,
                        [{BK, BV} | BRest] = B,
                        Acc) ->
    case AK of
        BK ->
            NewAcc = [{AK,
                       try AV+BV
                       catch error:badarith ->
                               case ([X || X <- [AV,BV],
                                           X =/= undefined]) of
                                   [] -> 0;
                                   [X|_] -> X
                               end
                       end} | Acc],
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
    ?assertEqual([{a, 3}, {b, 0}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {b, undefined}, {d, undefined}, {e,1}],
                                         [])),
    ?assertEqual([{a, 3}, {b, 0}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {b, undefined}, {ba, 123}],
                                         [])),
    ?assertEqual([{a, 3}, {b, 0}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {c,0}, {d, undefined}, {e,1}],
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
                               {extraCSSClasses,<<"closed">>},
                               {stats,
                                [%% first row
                                 {struct,[{title,<<"docs to replicate">>},
                                          {name,<<Prefix/binary,"changes_left">>},
                                          {desc,<<"Document mutations pending XDC replication">>}]},
                                 {struct,[{title,<<"docs checked">>},
                                          {name,<<Prefix/binary,"docs_checked">>},
                                          {desc,<<"Document mutations checked for XDC replication">>}]},
                                 {struct,[{title,<<"docs replicated">>},
                                          {name,<<Prefix/binary,"docs_written">>},
                                          {desc,<<"Document mutations replicated to remote cluster">>}]},
                                 {struct,[{title,<<"data replicated">>},
                                          {name,<<Prefix/binary,"data_replicated">>},
                                          {desc,<<"Data in bytes replicated to remote cluster">>}]},
                                 %% second row
                                 {struct,[{title,<<"active vb reps">>},
                                          {name,<<Prefix/binary,"active_vbreps">>},
                                          {desc,<<"Number of active vbucket replications">>}]},
                                 {struct,[{title,<<"waiting vb reps">>},
                                          {name,<<Prefix/binary,"waiting_vbreps">>},
                                          {desc,<<"Number of waiting vbucket replications">>}]},
                                 {struct,[{title,<<"secs in replicating">>},
                                          {name,<<Prefix/binary,"time_working">>},
                                          {desc,<<"Total time in secs all vb replicators spent checking and writing">>}]},
                                 {struct,[{title,<<"secs in checkpointing">>},
                                          {name,<<Prefix/binary,"time_committing">>},
                                          {desc,<<"Total time all vb replicators spent waiting for commit and checkpoint">>}]},
                                 %% third row
                                 {struct,[{title,<<"checkpoints issued">>},
                                          {name,<<Prefix/binary,"num_checkpoints">>},
                                          {desc,<<"Number of checkpoints all vb replicators have issued successfully in current replication">>}]},
                                 {struct,[{title,<<"checkpoints failed">>},
                                          {name,<<Prefix/binary,"num_failedckpts">>},
                                          {desc,<<"Number of checkpoints all vb replicators have failed to issue in current replication">>}]},
                                 {struct,[{title,<<"docs in queue">>},
                                          {name,<<Prefix/binary,"docs_rep_queue">>},
                                          {desc,<<"Number of document mutations in XDC replication queue">>}]},
                                 {struct,[{title,<<"queue size">>},
                                          {name,<<Prefix/binary,"size_rep_queue">>},
                                          {desc,<<"Size in bytes of XDC replication queue">>}]}]}]}
              end, Reps).

couchbase_view_stats_descriptions(BucketId) ->
    DesignDocIds = capi_ddoc_replication_srv:fetch_ddoc_ids(BucketId),

    % fold over design docs and get the signature
    DictBySig = lists:foldl(
      fun (DDocId, BySig) ->
              {ok, Signature} = couch_set_view:get_group_signature(list_to_binary(BucketId), DDocId),
              dict:append(Signature, DDocId, BySig)
      end, dict:new(), DesignDocIds),

    dict:fold(
      fun(Sig, DDocIds0, Stats) ->
              Prefix = <<"views/", Sig/binary,"/">>,
              DDocIds = lists:sort(DDocIds0),
              Ids = iolist_to_binary([hd(DDocIds) |
                                      [[?SPACE_CHAR | Id]
                                       || Id <- tl(DDocIds)]]),
              MyStats = {struct,[{blockName,<<"View Stats: ",Ids/binary>>},
                                 {extraCSSClasses,<<"closed">>},
                                 {columns,
                                  [<<"Data">>,<<"Disk">>,<<"Read Ops">>]},
                                 {stats,
                                  [{struct,[{title,<<"data size">>},
                                            {name,<<Prefix/binary,"data_size">>},
                                            {desc,<<"How many bytes stored">>}]},
                                   {struct,[{title,<<"disk size">>},
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
                         {desc,<<"Number of back-offs sent per second to drivers due to \"out of memory\" situations from this bucket (measured from ep_tmp_oom_errors)">>}]},
                {struct, [{title, <<"low water mark">>},
                          {name, <<"ep_mem_low_wat">>},
                          {desc, <<"Low water mark for auto-evictions (measured from ep_mem_low_wat)">>}]},
                {struct, [{title, <<"high water mark">>},
                          {name, <<"ep_mem_high_wat">>},
                          {desc, <<"High water mark for auto-evictions (measured from ep_mem_high_wat)">>}]},
                {struct, [{title, <<"memory used">>},
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
                {struct,[{name,<<"couch_docs_data_size">>},
                         {title,<<"docs data size">>},
                         {desc,<<"The size of active data in this bucket">>}]},
                {struct,[{name,<<"couch_docs_actual_disk_size">>},
                         {title,<<"docs total disk size">>},
                         {desc,<<"The size of all data files for this bucket, including the data itself, meta data and temporary files.">>}]},
                {struct,[{name,<<"couch_docs_fragmentation">>},
                         {title,<<"docs fragmentation %">>},
                         {desc,<<"How much fragmented data there is to be compacted compared to real data for the data files in this bucket">>}]},
                {struct,[{name,<<"couch_total_disk_size">>},
                         {title,<<"total disk size">>},
                         {desc,<<"The total size on disk of all data and view files for this bucket.)">>}]},
                {struct,[{name,<<"couch_views_data_size">>},
                         {title,<<"views data size">>},
                         {desc,<<"The size of active data on for all the indexes in this bucket">>}]},
                {struct,[{name,<<"couch_views_actual_disk_size">>},
                         {title,<<"views total disk size">>},
                         {desc,<<"The size of all active items in all the indexes for this bucket on disk">>}]},
                {struct,[{name,<<"couch_views_fragmentation">>},
                         {title,<<"views fragmentation %">>},
                         {desc,<<"How much fragmented data there is to be compacted compared to real data for the view index files in this bucket">>}]},
                {struct,[{name,<<"couch_views_ops">>},
                         {title,<<"view reads per sec.">>},
                         {desc,<<"All the view reads for all design documents including scatter gather.">>}]},
                {struct, [{title, <<"disk update time">>},
                          {name, <<"avg_disk_update_time">>},
                          {hidden, true},
                          {desc, <<"Average disk update time in microseconds as from disk_update histogram of timings">>}]},
                {struct, [{title, <<"disk commit time">>},
                          {name, <<"avg_disk_commit_time">>},
                          {hidden, true},
                          {desc, <<"Average disk commit time in seconds as from disk_update histogram of timings">>}]},
                {struct, [{title, <<"bg wait time">>},
                          {hidden, true},
                          {name, <<"avg_bg_wait_time">>},
                          {desc, <<"Alrighty">>}]},
                {struct,[{title,<<"XDCR dest ops per sec.">>},
                         {name,<<"xdc_ops">>},
                         {desc,<<"Cross datacenter replication operations per second for this bucket.">>}]},
                {struct,[{title,<<"XDCR docs to replicate">>},
                         {name,<<"replication_changes_left">>},
                         {desc,<<"Number of items waiting to be replicated to other clusters">>}]}
             ]}]},
     {struct,[{blockName,<<"vBucket Resources">>},
              {extraCSSClasses,<<"withtotal closed">>},
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
                         {desc,<<"Percentage of replica items cached in RAM in this bucket (measured from vb_replica_resident_items_ratio)">>},
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
                {struct,[{title,<<"user data in RAM">>},
                         {name,<<"vb_active_itm_memory">>},
                         {desc,<<"Amount of active user data cached in RAM in this bucket (measured from vb_active_itm_memory)">>}]},
                {struct,[{title,<<"user data in RAM">>},
                         {name,<<"vb_replica_itm_memory">>},
                         {desc,<<"Amount of replica user data cached in RAM in this bucket (measured from vb_replica_itm_memory)">>}]},
                {struct,[{title,<<"user data in RAM">>},
                         {name,<<"vb_pending_itm_memory">>},
                         {desc,<<"Amount of pending user data cached in RAM in this bucket and should be transient during rebalancing (measured from vb_pending_itm_memory)">>}]},
                {struct,[{title,<<"user data in RAM">>},
                         {name,<<"ep_kv_size">>},
                         {desc,<<"Total amount of user data cached in RAM in this bucket (measured from ep_kv_size)">>}]},
                {struct,[{title,<<"metadata in RAM">>},
                         {name,<<"vb_active_meta_data_memory">>},
                         {desc,<<"Amount of active item metadata consuming RAM in this bucket (measured from vb_active_meta_data_memory)">>}]},
                {struct,[{title,<<"metadata in RAM">>},
                         {name,<<"vb_replica_meta_data_memory">>},
                         {desc,<<"Amount of replica item metadata consuming in RAM in this bucket (measured from vb_replica_meta_data_memory)">>}]},
                {struct,[{title,<<"metadata in RAM">>},
                         {name,<<"vb_pending_meta_data_memory">>},
                         {desc,<<"Amount of pending item metadata consuming RAM in this bucket and should be transient during rebalancing (measured from vb_pending_meta_data_memory)">>}]},
                {struct,[{title,<<"metadata in RAM">>},
                         {name,<<"ep_ht_memory">>},
                         {desc,<<"Total amount of item  metadata consuming RAM in this bucket (measured from ep_ht_memory)">>}]}]}]},
     {struct,[{blockName,<<"Disk Queues">>},
              {extraCSSClasses,<<"withtotal closed">>},
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
              {extraCSSClasses,<<"withtotal closed">>},
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
                         {desc,<<"Total number of items still on disk to be loaded for TAP connections to this bucket (measured from ep_tap_total_queue_itemonsidk)">>}]}]}]}]
        ++ couchbase_view_stats_descriptions(BucketId)
        ++ couchbase_replication_stats_descriptions(BucketId)
        ++ [{struct,[{blockName,<<"Incoming XDCR Operations">>},
                     {extraCSSClasses,<<"closed">>},
                     {stats,
                      [{struct,[{title,<<"gets per sec.">>},
                                {name,<<"ep_num_ops_get_meta">>},
                                {desc,<<"Number of get operations per second for this bucket as the target for XDCR">>}]},
                       {struct,[{title,<<"sets per sec.">>},
                                {name,<<"ep_num_ops_set_meta">>},
                                {desc,<<"Number of set operations per second for this bucket as the target for XDCR">>}]},
                       {struct,[{title,<<"deletes per sec.">>},
                                {name,<<"ep_num_ops_del_meta">>},
                                {desc,<<"Number of delete operations per second for this bucket as the target for XDCR">>}]},
                       {struct,[{title,<<"total ops per sec.">>},
                                {name,<<"xdc_ops">>},
                                {desc,<<"Total XDCR operations per second for this bucket.">>}]}]}]}].


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
                {struct,[{name,<<"mem_used">>},
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
     {extraCSSClasses,<<"server_resources">>},
     {stats,
      [{struct,[{name,<<"swap_used">>},
                {title,<<"swap usage">>},
                {desc,<<"Amount of swap space in use on this server (B=bytes, M=megabytes, G=gigabytes)">>}]},
       {struct,[{name,<<"mem_actual_free">>},
                {title,<<"free RAM">>},
                {desc,<<"Amount of RAM available on this server (B=bytes, M=megabytes, G=gigabytes)">>}]},
       {struct,[{name,<<"cpu_utilization_rate">>},
                {title,<<"CPU utilization %">>},
                {desc,<<"Percentage of CPU in use across all available cores on this server">>},
                {maxY,100}]},
       {struct,[{name,<<"curr_connections">>},
                {title,<<"connections">>},
                {desc,<<"Number of connections to this server "
                        "including connections from external drivers, proxies, "
                        "TAP requests and internal statistic gathering "
                        "(measured from curr_connections)">>}]}]}].

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
