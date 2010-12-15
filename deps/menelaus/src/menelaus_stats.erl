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

-include_lib("eunit/include/eunit.hrl").

-export([handle_bucket_stats/3,
         handle_overview_stats/2,
         basic_stats/1,
         basic_stats/2, basic_stats/3,
         bucket_disk_usage/1,
         bucket_ram_usage/1]).

%% External API

bucket_disk_usage(BucketName) ->
    bucket_disk_usage(BucketName, ns_bucket:live_bucket_nodes(BucketName)).

bucket_disk_usage(BucketName, Nodes) ->
    {Res, _} = rpc:multicall(Nodes, ns_storage_conf, local_bucket_disk_usage, [BucketName], 1000),
    lists:sum([case is_number(X) of
                   true -> X;
                   _ -> 0
               end || X <- Res]).

bucket_ram_usage(BucketName) ->
    element(1, last_membase_sample(BucketName, ns_bucket:live_bucket_nodes(BucketName))).

extract_stat(StatName, Sample) ->
    case orddict:find(StatName, Sample#stat_entry.values) of
        error -> 0;
        {ok, V} -> V
    end.

last_membase_sample(BucketName, Nodes) ->
    lists:foldl(fun ({_Node, []}, Acc) -> Acc;
                    ({_Node, [Sample|_]}, {AccMem, AccItems, AccOps, AccFetches}) ->
                        {extract_stat(mem_used, Sample) + AccMem,
                         extract_stat(curr_items, Sample) + AccItems,
                         extract_stat(ops, Sample) + AccOps,
                         extract_stat(ep_io_num_read, Sample) + AccFetches}
                end, {0, 0, 0, 0}, invoke_archiver(BucketName, Nodes, {1, minute, 1})).

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
     case CmdGet of
         0 -> 0;
         _ -> GetHits / CmdGet
     end}.

last_bucket_stats(membase, BucketName, Nodes) ->
    {MemUsed, ItemsCount, Ops, Fetches} = last_membase_sample(BucketName, Nodes),
    [{opsPerSec, Ops},
     {diskFetches, Fetches},
     {itemCount, ItemsCount},
     {diskUsed, bucket_disk_usage(BucketName, Nodes)},
     {memUsed, MemUsed}];
last_bucket_stats(memcached, BucketName, Nodes) ->
    {MemUsed, ItemsCount, Ops, HitRatio} = last_memcached_sample(BucketName, Nodes),
    [{opsPerSec, Ops},
     {hitRatio, HitRatio},
     {itemCount, ItemsCount},
     {diskUsed, bucket_disk_usage(BucketName, Nodes)},
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
                                   element(1, grab_op_stats(Name, [{"zoom", "hour"}]))
                           end, Names),
    MergedSamples = case AllSamples of
                        [FirstBucketSamples | RestSamples] ->
                            lists:foldl(fun (Samples, Acc) ->
                                        merge_samples_normally(Acc, Samples)
                                end, FirstBucketSamples, RestSamples);
                        [] -> []
                    end,
    TStamps = [X#stat_entry.timestamp || X <- MergedSamples],
    Ops = [extract_stat(ops, X) || X <- MergedSamples],
    DiskReads = [extract_stat(ep_io_num_read, X) || X <- MergedSamples],
    menelaus_util:reply_json(Req, {struct, [{timestamp, TStamps},
                                            {ops, Ops},
                                            {ep_io_num_read, DiskReads}]}).

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

handle_bucket_stats(PoolId, Id, Req) ->
    handle_buckets_stats(PoolId, [Id], Req).

handle_buckets_stats(PoolId, BucketIds, Req) ->
    Params = Req:parse_qs(),
    {struct, PropList1} = build_buckets_stats_ops_response(PoolId, BucketIds, Params),
    {struct, PropList2} = build_buckets_stats_hks_response(PoolId, BucketIds),
    menelaus_util:reply_json(Req, {struct, PropList1 ++ PropList2}).

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

merge_samples(MainSamples, OtherSamples, MergerFun, MergerState) ->
    OtherSamplesDict = orddict:from_list([{Sample#stat_entry.timestamp, Sample} ||
                                             Sample <- OtherSamples]),
    {MergedSamples, _} = lists:foldl(fun (Sample, {Acc, MergerState2}) ->
                                             TStamp = Sample#stat_entry.timestamp,
                                             {NewSample, NextState} =
                                                 case orddict:find(TStamp, OtherSamplesDict) of
                                                     {ok, AnotherSample} ->
                                                         MergerFun(Sample, AnotherSample, MergerState2);
                                                     _ -> {Sample, MergerState2}
                                                 end,
                                             {[NewSample | Acc], NextState}
                                     end, {[], MergerState}, MainSamples),
    lists:reverse(MergedSamples).

merge_samples_normally(MainSamples, OtherSamples) ->
    merge_samples(MainSamples, OtherSamples,
                  fun (A, B, _) ->
                          {aggregate_stat_entries(A, B), []}
                  end, []).


grab_op_stats(Bucket, Params) ->
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
    Subscription = ns_pubsub:subscribe(ns_stats_event, fun (_, done) -> done;
                                                           ({sample_archived, _, _}, _) ->
                                                               Self ! Ref,
                                                               done;
                                                           (_, X) -> X
                                                       end, []),
    %% don't wait next sample for anything other than real-time stats
    RefToPass = case Period of
                    minute -> Ref;
                    _ -> []
                end,
    try grab_op_stats_body(Bucket, ClientTStamp, RefToPass, {Step, Period, Window}) of
        V -> case V =/= [] andalso (hd(V))#stat_entry.timestamp of
                 ClientTStamp -> {V, ClientTStamp, Step, Window};
                 _ -> {V, undefined, Step, Window}
             end
    after
        misc:flush(Ref),
        ns_pubsub:unsubscribe(ns_stats_event, Subscription)
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

grab_op_stats_body(Bucket, ClientTStamp, Ref, PeriodParams) ->
    RV = invoke_archiver(Bucket, node(), PeriodParams),
    case RV of
        [] -> [];
        [_] -> [];
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
                            grab_op_stats_body(Bucket, ClientTStamp, [], PeriodParams)
                    after 2000 ->
                            []
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
                    Replies = invoke_archiver(
                                Bucket,
                                ns_bucket:live_bucket_nodes(Bucket),
                                PeriodParams),
                    %% merge samples from other nodes
                    MergedSamples = lists:foldl(fun ({Node, _}, AccSamples) when Node =:= node() -> AccSamples;
                                                    ({_Node, RemoteSamples}, AccSamples) ->
                                                        merge_samples_normally(AccSamples, RemoteSamples)
                                                end, MainSamples, Replies),
                    lists:reverse(MergedSamples)
            end
    end.

%% converts list of samples to proplist of stat values
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
    CmdGets = orddict:fetch(cmd_get, Dict),
    HitRatio = lists:zipwith(fun (null, _Hits) -> 0;
                                 (_Gets, null) -> 0;
                                 (Gets, _Hits) when Gets == 0 -> 0; % this handles int and float 0
                                 (Gets, Hits) -> Hits/Gets
                             end, CmdGets, orddict:fetch(get_hits, Dict)),
    EPCacheMissRatio = lists:zipwith(fun (BGFetches, Gets) ->
                                            try 100 - ((Gets - BGFetches) * 100 / Gets)
                                            catch error:badarith -> 0
                                            end
                                    end,
                                    orddict:fetch(ep_bg_fetched, Dict),
                                    CmdGets),
    ResidentItemsRatio = lists:zipwith(fun (NonResident, CurrItems) ->
                                               try (CurrItems - NonResident) * 100 / CurrItems
                                               catch error:badarith -> 0
                                               end
                                       end,
                                       orddict:fetch(ep_num_active_non_resident, Dict),
                                       orddict:fetch(curr_items, Dict)),
    ReplicaResidentItemRate = misc:zipwith4(
                                fun (ItemsTotal, CurrItems, NonResident, ActiveNonResident) ->
                                        try ((ItemsTotal - CurrItems)
                                             - (NonResident - ActiveNonResident)) * 100 / (ItemsTotal - CurrItems)
                                        catch error:badarith -> 0
                                        end
                                end,
                                orddict:fetch(curr_items_tot, Dict),
                                orddict:fetch(curr_items, Dict),
                                orddict:fetch(ep_num_non_resident, Dict),
                                orddict:fetch(ep_num_active_non_resident, Dict)),
    [{hit_ratio, HitRatio},
     {ep_cache_miss_rate, EPCacheMissRatio},
     {ep_resident_items_rate, ResidentItemsRatio},
     {ep_replica_resident_items_rate, ReplicaResidentItemRate} | orddict:to_list(Dict)].

build_buckets_stats_ops_response(_PoolId, [BucketName], Params) ->
    {Samples, ClientTStamp, Step, TotalNumber} = grab_op_stats(BucketName, Params),
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
    HotKeyStructs = lists:map(fun ({Key, PList}) ->
                                      EscapedKey = case is_safe_key_name(Key) of
                                                       true -> Key;
                                                       _ -> "BIN_" ++ base64:encode_to_string(Key)
                                                   end,
                                      {struct, [{name, list_to_binary(EscapedKey)},
                                                {ops, proplists:get_value(ops, PList)}]}
                              end, BucketsTopKeys),
    {struct, [{hot_keys, HotKeyStructs}]}.

aggregate_stat_entries(A, B) ->
    true = (B#stat_entry.timestamp =:= A#stat_entry.timestamp),
    BValues = B#stat_entry.values,
    NewValues = orddict:map(fun (K, X0) ->
                                    X = case X0 of
                                            undefined -> 0;
                                            _ -> X0
                                        end,
                                    case orddict:find(K, BValues) of
                                        {ok, Y} when Y =/= undefined -> X + Y;
                                        _ -> X
                                    end
                            end, A#stat_entry.values),
    A#stat_entry{values = NewValues}.
