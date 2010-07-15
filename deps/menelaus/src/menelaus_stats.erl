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

-ifdef(EUNIT).
-export([test/0]).
-endif.

-export([handle_bucket_stats/3, basic_stats/2]).

-export([build_buckets_stats_ops_response/3,
         build_buckets_stats_hks_response/3,
         get_buckets_stats/3,
         get_stats_raw/3]).

-import(menelaus_util,
        [reply_json/2,
         reply_json/3]).

default_find(K, Default, Dict) ->
    case dict:find(K, Dict) of
        error -> Default;
        {ok, Value} -> Value
    end.

default_find(K, Dict) ->
    default_find(K, [], Dict).

%% External API

basic_stats(_PoolId, BucketId) ->
    MbPerNode = 1,
    NumNodes = length(ns_node_disco:nodes_wanted()),
    SamplesNum = 10,
    Samples = get_stats_raw(fakepool, BucketId, SamplesNum),
    OpsPerSec = avg(deltas(sum_stats_ops(Samples))),
    EvictionsPerSec = avg(deltas(default_find("evictions", Samples))),
    CurBytes = erlang:max(avg(default_find("bytes", Samples)), 0),
    MaxBytes = erlang:max(avg(default_find("engine_maxbytes", Samples)),
                          1),
    [{cacheSize, NumNodes * MbPerNode},
     {opsPerSec, OpsPerSec},
     {evictionsPerSec, EvictionsPerSec},
     {cachePercentUsed, float_round(CurBytes / MaxBytes)}].

% GET /pools/default/stats?stat=opsbysecond
% GET /pools/default/stats?stat=hot_keys
% GET /pools/default/stats?stat=combined

handle_bucket_stats(PoolId, all, Req) ->
    BucketNames = menelaus_web:all_accessible_bucket_names(PoolId, Req),
    handle_buckets_stats(PoolId, BucketNames, Req);

handle_bucket_stats(PoolId, Id, Req) ->
    handle_buckets_stats(PoolId, [Id], Req).

handle_buckets_stats(PoolId, BucketIds, Req) ->
    Params = Req:parse_qs(),
    case proplists:get_value("stat", Params) of
        "opsbysecond" ->
            handle_buckets_stats_ops(Req, PoolId, BucketIds, Params);
        "hot_keys" ->
            handle_buckets_stats_hks(Req, PoolId, BucketIds, Params);
        "combined" ->
            {struct, PropList1} = build_buckets_stats_ops_response(PoolId, BucketIds, Params),
            {struct, PropList2} = build_buckets_stats_hks_response(PoolId, BucketIds, Params),
            reply_json(Req, {struct, PropList1 ++ PropList2});
        _ ->
            reply_json(Req, [list_to_binary("Stats requests require parameters.")], 400)
    end.

handle_buckets_stats_ops(Req, PoolId, BucketIds, Params) ->
    Res = build_buckets_stats_ops_response(PoolId, BucketIds, Params),
    reply_json(Req, Res).

handle_buckets_stats_hks(Req, PoolId, BucketIds, Params) ->
    Res = build_buckets_stats_hks_response(PoolId, BucketIds, Params),
    reply_json(Req, Res).

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
    OtherSamplesDict = dict:from_list([{Sample#stat_entry.timestamp, Sample} ||
                                          Sample <- OtherSamples]),
    {MergedSamples, _} = lists:foldl(fun (Sample, {Acc, MergerState2}) ->
                                             TStamp = Sample#stat_entry.timestamp,
                                             {NewSample, NextState} =
                                                 case dict:find(TStamp, OtherSamplesDict) of
                                                     {ok, AnotherSample} ->
                                                         MergerFun(Sample, AnotherSample, MergerState2);
                                                     _ -> {Sample, MergerState2}
                                                 end,
                                             {[NewSample | Acc], NextState}
                                     end, {[], MergerState}, MainSamples),
    lists:reverse(MergedSamples).

grab_op_stats(Bucket, Params) ->
    ClientTStamp = case proplists:get_value("haveTStamp", Params) of
                       undefined -> undefined;
                       X -> try list_to_integer(X) of
                                XI -> XI
                            catch
                                _:_ -> undefined
                            end
                   end,
    {Step, Period} = case proplists:get_value("zoom", Params) of
                         "minute" -> {1, minute};
                         "hour" -> {60, hour};
                         "day" -> {1440, day};
                         "week" -> {11520, week};
                         "month" -> {44640, month};
                         "year" -> {527040, year};
                         undefined -> {1, minute}
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
    try grab_op_stats_body(Bucket, ClientTStamp, RefToPass, Step, Period) of
        V -> case V =/= [] andalso (hd(V))#stat_entry.timestamp of
                 ClientTStamp -> {V, ClientTStamp, Step, 60};
                 _ -> {V, undefined, Step, 60}
             end
    after
        misc:flush(Ref),
        ns_pubsub:unsubscribe(ns_stats_event, Subscription)
    end.

invoke_archiver(Bucket, NodeS, Step, Period) ->
    case Step of
        1 ->
            Period = minute,
            stats_archiver:latest(minute, NodeS, Bucket, 60);
        _ ->
            stats_archiver:latest(Period, NodeS, Bucket, Step, 60)
    end.

grab_op_stats_body(Bucket, ClientTStamp, Ref, Step, Period) ->
    RV = invoke_archiver(Bucket, node(), Step, Period),
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
                            grab_op_stats_body(Bucket, ClientTStamp, [], Step, Period)
                    after 2000 ->
                            grab_op_stats_body(Bucket, undefined, [], Step, Period)
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
                    Replies = invoke_archiver(Bucket, ns_node_disco:nodes_wanted(), Step, Period),
                    %% merge samples from other nodes
                    MergedSamples = lists:foldl(fun ({Node, _}, AccSamples) when Node =:= node() -> AccSamples;
                                                    ({_Node, RemoteSamples}, AccSamples) ->
                                                        merge_samples(AccSamples, RemoteSamples,
                                                                      fun (A, B, _) ->
                                                                              {aggregate_stat_entries([A, B]), []}
                                                                      end, [])
                                                end, MainSamples, Replies),
                    lists:reverse(MergedSamples)
            end
    end.

produce_sum_stats([FirstStat | RestStats], Samples) ->
    lists:foldl(fun (StatName, XSamples) ->
                        YSamples = proplists:get_value(StatName, Samples),
                        [X+Y || {X,Y} <- lists:zip(XSamples, YSamples)]
                end, proplists:get_value(FirstStat, Samples), RestStats).

add_stat_sums(Samples) ->
    [{ops, produce_sum_stats([cmd_get, cmd_set,
                              incr_misses, incr_hits,
                              decr_misses, decr_hits,
                              delete_misses, delete_hits], Samples)},
     {misses, produce_sum_stats([get_misses, delete_misses, incr_misses, decr_misses,
                                 cas_misses], Samples)},
     {disk_writes, produce_sum_stats([ep_flusher_todo, ep_queue_size], Samples)},
     {updates, produce_sum_stats([cmd_set, incr_hits, decr_hits, cas_hits], Samples)}
     | Samples].

build_buckets_stats_ops_response(_PoolId, ["default"], Params) ->
    {Samples0, ClientTStamp, Step, TotalNumber} = grab_op_stats("default", Params),
    StatsList = tuple_to_list({timestamp, ?STAT_GAUGES, ?STAT_COUNTERS}),
    EmptyLists = [[] || _ <- StatsList],
    Samples = case Samples0 of
                  [#stat_entry{bytes_read = undefined} | T] -> T;
                  _ -> Samples0
              end,
    PropList0 = lists:zip(StatsList,
                         lists:foldl(fun (Sample, Acc) ->
                                             [[X | Y] || {X,Y} <- lists:zip(tl(tuple_to_list(Sample)), Acc)]
                                     end, EmptyLists, Samples)),
    PropList1 = [{K, lists:reverse(V)} || {K,V} <- PropList0],
    PropList2 = add_stat_sums(PropList1),
    OpPropList0 = [{samples, {struct, PropList2}},
                   {samplesCount, TotalNumber},
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

build_buckets_stats_hks_response(PoolId, BucketIds, Params) ->
    {ok, BucketsTopKeys} =
        get_buckets_hks(PoolId, BucketIds, Params),
    HotKeyStructs = lists:map(
                      fun ({BucketId, Key, Ratio, Ops}) ->
                              EscapedKey = case is_safe_key_name(Key) of
                                               true -> Key;
                                               _ -> "BIN_" ++ base64:encode_to_string(Key)
                                           end,
                              {struct, [{name, list_to_binary(EscapedKey)},
                                        {bucket, list_to_binary(BucketId)},
                                        {ratio, Ratio},
                                        {ops, Ops}]}
                      end,
                      lists:sublist(lists:reverse(lists:keysort(4, BucketsTopKeys)), 15)),
    {struct, [{hot_keys, HotKeyStructs}]}.

get_buckets_hks(_PoolId, _BucketIds, _Params) ->
    {ok, [
          {"default", "key1", 0.60, 3000},
          {"default", "key3", 0.8, 3345},
          {"default", "key2", 0.75, 3030},
          {"default", "keydf", 0.3, 450}
         ]}.

sum_stats_values_rec([], [], Rec) ->
    Rec;
sum_stats_values_rec([], YVals, Rec) ->
    lists:reverse(YVals, Rec);
sum_stats_values_rec(XVals, [], Rec) ->
    lists:reverse(XVals, Rec);
sum_stats_values_rec([X | XS], [Y | YS], Rec) ->
    sum_stats_values_rec(XS, YS, [X+Y | Rec]).

sum_stats_values(XVals, YVals) ->
    sum_stats_values_rec(lists:reverse(XVals), lists:reverse(YVals), []).

get_buckets_stats(PoolId, BucketIds, _Params) ->
    AllStatsList = lists:map(fun(BucketId) ->
                                     Samples = get_stats_raw(PoolId, BucketId, 60),
                                     case dict:size(Samples) =:= 0 of
                                         true -> undefined;
                                         _ -> process_raw_stats(Samples)
                                     end
                             end,
                             BucketIds),
    StatsList = lists:filter(fun (undefined) -> false;
                                 (_) -> true
                             end, AllStatsList),
    case StatsList of
        [] -> {ok, 0, 0, []};
        [FirstStats | RestStats] ->
            lists:foldl(
              fun({ok, XSamplesInterval, XLastSampleTStamp, XStat},
                  {ok, YSamplesInterval, YLastSampleTStamp, YStat}) ->
                      XSamplesInterval = YSamplesInterval,
                      {ok,
                       XSamplesInterval,
                       %% usually are equal too except when one value is 0 (empty stats)
                       erlang:max(XLastSampleTStamp, YLastSampleTStamp),
                       lists:map(fun({t, TStamps}) -> {t, TStamps};
                                    ({Key, XVals}) ->
                                         YVals = proplists:get_value(Key, YStat),
                                         {Key, sum_stats_values(XVals, YVals)}
                                 end,
                                 XStat)}
              end,
              FirstStats,
              RestStats)
    end.

process_raw_stats(Samples) ->
    SamplesInterval = 1000, % A sample every second.
    process_raw_stats(SamplesInterval, Samples).

process_raw_stats(SamplesInterval, Samples) ->
    LastSampleTStamp = case default_find(t, Samples) of
                           [] -> 0;
                           List -> lists:last(List)
                       end,

    Samples3 = dict:store(ops, sum_stats_ops(Samples), Samples),
    Samples4 = dict:store(misses,
                          sum_stats(["get_misses",
                                     "incr_misses",
                                     "decr_misses",
                                     "delete_misses",
                                     "cas_misses"],
                                    Samples3),
                         Samples3),

    Samples5 = dict:store(updates,
                          sum_stats(["cmd_set",
                                     "incr_hits", "decr_hits", "cas_hits"],
                                    Samples4),
                          Samples4),

    Samples6 = dict:store(hit_ratio,
                          lists:zipwith(fun (H,G) ->
                                                float_round(case catch(H / G) of
                                                                {'EXIT', _R} -> 0;
                                                                V -> V
                                                            end)
                                        end,
                                        default_find("get_hits", Samples5),
                                        default_find("cmd_get", Samples5)),
                          Samples5),

    Samples7 = dict:to_list(dict:map(fun(t, Vals) -> Vals;
                                        (_K, Vals) -> deltas(Vals)
                                     end,
                                     Samples6)),
    {ok, SamplesInterval, LastSampleTStamp, Samples7}.

% get_stats_raw() returns something like, where lists are sorted
% with most-recent last.
%
% (imagine this as a dict)
%
% [{"total_items",[0,0,0,0,0]},
%  {"curr_items",[0,0,0,0,0]},
%  {"bytes_read",[2208,2232,2256,2280,2304]},
%  {"cas_misses",[0,0,0,0,0]},
%  {t, [{1263,946873,864055},
%       {1263,946874,864059},
%       {1263,946875,864050},
%       {1263,946876,864053},
%       {1263,946877,864065}]},
%  ...]

get_stats_raw(_PoolId, _BucketId, _SamplesNum) ->
    dict:from_list([]).

sum_stats_ops(Stats) ->
    sum_stats(["cmd_get", "cmd_set",
               "incr_misses", "incr_hits",
               "decr_misses", "decr_hits",
               "delete_misses", "delete_hits", "evictions",
               "cas_misses", "cas_hits", "cas_badval",
               "cmd_flush"],
              Stats).

sum_stats(Keys, Stats) ->
    D = dict:filter(fun(K,_V) -> lists:member(K, Keys) end, Stats),
    dict:fold(fun(_K, V, []) ->
                      V;
                 (_K, V, L) ->
                      lists:zipwith(fun(X,Y) -> X+Y end, V, L)
              end, [], D).

sum_hks(Keys, Stats) ->
    D = dict:filter(fun(K, _V) -> lists:member(K, Keys) end, Stats),
    dict:fold(fun(_K, V, Acc) -> V + Acc end, 0, D).

avg(undefined) -> 0.0;
avg(L)         -> avg(L, 0, 0).

avg([], _, 0)            -> 0.0;
avg([], Sum, Count)      -> float(Sum) / float(Count);
avg([H | R], Sum, Count) -> avg(R, Sum + H, Count + 1).

float_round(X) -> float(trunc(1000.0 * X)) / 1000.0.

deltas(undefined)  -> undefined;
deltas([])         -> [];
deltas([X | Rest]) -> deltas(Rest, X, []).

deltas([], _, Acc) -> lists:reverse(Acc);
deltas([X | Rest], Prev, Acc) ->
    deltas(Rest, X, [erlang:max(X - Prev, 0) | Acc]).

aggregate_stat_entries([Entry | Rest]) ->
    aggregate_stat_entries_rec(Rest, tuple_to_list(Entry)).

aggregate_stat_entries_rec([], Acc) ->
    list_to_tuple(Acc);
aggregate_stat_entries_rec([Entry | Rest], Acc) ->
    [{stat_entry, stat_entry}, {TStamp1, TStamp2} | Meat] = lists:zip(tuple_to_list(Entry), Acc),
    TStamp1 = TStamp2,
    NewAcc = lists:map(fun ({X,Y}) ->
                               case X of
                                   undefined -> 0;
                                   _ -> X
                               end + case Y of
                                         undefined -> 0;
                                         _ -> Y
                                     end
                       end, Meat),
    aggregate_stat_entries_rec(Rest, [stat_entry, TStamp1 | NewAcc]).

-ifdef(EUNIT).

test() ->
    eunit:test({module, ?MODULE},
               [verbose]).

avg_test() ->
    ?assertEqual(0.0, avg([])),
    ?assertEqual(5.0, avg([5])),
    ?assertEqual(5.0, avg([5, 5, 5])),
    ?assertEqual(5.0, avg([0, 5, 10])),
    ok.

float_round_test() ->
    ?assertEqual(0.01, float_round(0.0100001)),
    ?assertEqual(0.08, float_round(0.0800001)),
    ?assertEqual(1.08, float_round(1.0800099)),
    ok.

deltas_test() ->
    ?assertEqual([], deltas([])),
    ?assertEqual([], deltas([10])),
    ?assertEqual([0], deltas([10, 10])),
    ?assertEqual([0, 0], deltas([10, 10, 10])),
    ?assertEqual([0, 0, 0],
                 deltas([10, 10, 10, 10])),
    ?assertEqual([0, 1, 1],
                 deltas([10, 10, 11, 12])),
    ?assertEqual([0, 1, 1, 0],
                 deltas([10, 10, 11, 12, 12])),
    ok.

sum_stats_values_test() ->
    ?assertEqual([], sum_stats_values([], [])),
    ?assertEqual([1,2], sum_stats_values([1,2],[])),
    ?assertEqual([1,2], sum_stats_values([],[1,2])),
    ?assertEqual([0,0,0,1,2,3,4], sum_stats_values([1,2,3,4],[0,0,0,0,0,0,0])),
    ?assertEqual([0,0,0,1,2,3,4], sum_stats_values([0,0,0,0,0,0,0],[1,2,3,4])),
    ?assertEqual([4,6], sum_stats_values([1,2],[3,4])),
    ?assertEqual([4,6], sum_stats_values([3,4],[1,2])),
    ?assertEqual([1,5,7], sum_stats_values([3,4],[1,2,3])),
    ?assertEqual([1,5], sum_stats_values([1,2],[3])),
    ?assertEqual([1,5], sum_stats_values([3],[1,2])).

-endif.
