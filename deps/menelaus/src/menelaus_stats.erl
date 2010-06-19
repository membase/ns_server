%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_stats).
-author('NorthScale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test/0]).
-import(menelaus_util,
        [wrap_tests_with_cache_setup/1]).
-endif.

-export([handle_bucket_stats/3, basic_stats/2]).

-export([build_buckets_stats_ops_response/3,
         build_buckets_stats_hks_response/3,
         get_buckets_stats/3,
         get_stats_raw/3]).

-import(menelaus_util,
        [reply_json/2,
         reply_json/3,
         expect_prop_value/2]).

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

build_buckets_stats_ops_response(PoolId, BucketIds, Params) ->
    {ok, SamplesInterval, LastSampleTStamp, Samples2} =
        get_buckets_stats(PoolId, BucketIds, Params),
    {struct, [{op, {struct, [{tstamp, LastSampleTStamp},
                             {samplesInterval, SamplesInterval}
                             | Samples2]}}]}.

is_safe_key_name(Name) ->
    lists:all(fun (C) ->
                      C >= 16#20 andalso C =< 16#7f
              end, Name).

build_buckets_stats_hks_response(PoolId, BucketIds, Params) ->
    {ok, BucketsTopKeys} =
        get_buckets_hks(PoolId, BucketIds, Params),
    HotKeyStructs = lists:map(
                      fun ({BucketId, Key, Evictions, Ratio, Ops}) ->
                              EscapedKey = case is_safe_key_name(Key) of
                                               true -> Key;
                                               _ -> "BIN_" ++ base64:encode_to_string(Key)
                                           end,
                              {struct, [{name, list_to_binary(EscapedKey)},
                                        {bucket, list_to_binary(BucketId)},
                                        {evictions, Evictions},
                                        {ratio, Ratio},
                                        {ops, Ops}]}
                      end,
                      lists:sublist(lists:reverse(lists:keysort(5, BucketsTopKeys)), 15)),
    {struct, [{hot_keys, HotKeyStructs}]}.

get_buckets_hks(_PoolId, _BucketIds, _Params) ->
    {ok, []}.

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

-ifdef(EUNIT).

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
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
