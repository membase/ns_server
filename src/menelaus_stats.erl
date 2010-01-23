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
        [test_under_debugger/0, debugger_apply/2,
         wrap_tests_with_cache_setup/1]).
-endif.

-export([handle_bucket_stats/3, basic_stats/2]).

-export([build_buckets_stats_ops_response/3,
         build_buckets_stats_hks_response/3,
         get_buckets_stats/3,
         get_stats/3,
         get_stats_raw/3]).

-import(menelaus_util,
        [reply_json/2,
         expect_prop_value/2,
         java_date/0,
         string_hash/1,
         my_seed/1,
         stateful_map/3,
         stateful_takewhile/3,
         low_pass_filter/2,
         caching_result/2]).

%% External API

basic_stats(PoolId, BucketId) ->
    Pool = menelaus_web:find_pool_by_id(PoolId),
    Bucket = menelaus_web:find_bucket_by_id(Pool, BucketId),
    MbPerNode = expect_prop_value(size_per_node, Bucket),
    NumNodes = length(ns_node_disco:nodes_wanted()),
    SamplesNum = 10,
    Samples = get_stats_raw(PoolId, BucketId, SamplesNum),
    OpsPerSec = avg(deltas(sum_stats_ops(Samples))),
    EvictionsPerSec = avg(deltas(proplists:get_value("evictions", Samples))),
    CurBytes = erlang:max(avg(proplists:get_value("bytes", Samples)),
                          1),
    MaxBytes = erlang:max(avg(proplists:get_value("limit_maxbytes", Samples)),
                          CurBytes),
    [{cacheSize, NumNodes * MbPerNode},
     {opsPerSec, OpsPerSec},
     {evictionsPerSec, EvictionsPerSec},
     {cachePercentUsed, float_round(CurBytes / MaxBytes)}].

% GET /pools/default/stats?stat=opsbysecond
% GET /pools/default/stats?stat=hot_keys

handle_bucket_stats(PoolId, all, Req) ->
    handle_bucket_stats(PoolId, "default", Req);

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
            Req:respond({400, [], []})
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

build_buckets_stats_hks_response(_PoolId, _BucketIds, _Params) ->
    % TODO: hot key stats.
    {struct, [{hot_keys, [{struct, [{name, <<"product:324:inventory">>},
                                    {gets, 10000},
                                    {bucket, <<"shopping application">>},
                                    {misses, 100}]},
                          {struct, [{name, <<"user:image:value2">>},
                                    {gets, 10000},
                                    {bucket, <<"chat application">>},
                                    {misses, 100}]},
                          {struct, [{name, <<"blog:117">>},
                                    {gets, 10000},
                                    {bucket, <<"blog application">>},
                                    {misses, 100}]},
                          {struct, [{name, <<"user:image:value4">>},
                                    {gets, 10000},
                                    {bucket, <<"chat application">>},
                                    {misses, 100}]}]}]}.

get_buckets_stats(PoolId, BucketIds, Params) ->
    [FirstStats | RestStats] =
        lists:map(fun(BucketId) ->
                          get_stats(PoolId, BucketId, Params)
                  end,
                  BucketIds),
    lists:foldl(
      fun({ok, XSamplesInterval, XLastSampleTStamp, XStat},
          {ok, YSamplesInterval, YLastSampleTStamp, YStat}) ->
              {ok,
               erlang:max(XSamplesInterval,
                          YSamplesInterval),
               erlang:max(XLastSampleTStamp,
                          YLastSampleTStamp),
               lists:map(fun({t, TStamps}) -> {t, TStamps};
                            ({Key, XVals}) ->
                                 case proplists:get_value(Key, YStat) of
                                     undefined -> {Key, XVals};
                                     YVals ->
                                         {Key, lists:zipwith(
                                                 fun(A, B) -> A + B end,
                                                 XVals, YVals)}
                                 end
                        end,
                        XStat)}
      end,
      FirstStats,
      RestStats).

get_stats(PoolId, BucketId, _Params) ->
    SamplesInterval = 1, % A sample every second.
    SamplesNum = 60, % Sixty seconds worth of data.
    Samples = get_stats_raw(PoolId, BucketId, SamplesNum),
    Samples2 = case lists:keytake(t, 1, Samples) of
                   false -> [{t, []} | Samples];
                   {value, {t, TStamps}, SamplesNoTStamps} ->
                       [{t, lists:map(fun misc:time_to_epoch_int/1,
                                      TStamps)} |
                        SamplesNoTStamps]
               end,
    LastSampleTStamp = case Samples2 of
                           [{t, []} | _]       -> 0;
                           [{t, TStamps2} | _] -> lists:last(TStamps2);
                           _                   -> 0
                       end,
    Samples3 = [{ops, sum_stats_ops(Samples2)} | Samples2],
    Samples4 = [{misses, sum_stats(["get_misses",
                                    "incr_misses",
                                    "decr_misses",
                                    "delete_misses",
                                    "cas_misses"],
                                   Samples3)} |
                Samples3],
    Samples5 = [{updates, sum_stats(["cmd_set",
                                     "incr_hits", "decr_hits", "cas_hits"],
                                    Samples4)} |
                Samples4],
    Samples6 = [{hit_ratio,
                 lists:zipwith(fun(undefined, _) -> 0;
                                  (_, undefined) -> 0;
                                  (_, 0)         -> 0;
                                  (Hits, Gets)   -> float_round(Hits / Gets)
                               end,
                               proplists:get_value("get_hits", Samples5),
                               proplists:get_value("cmd_get", Samples5))} |
                Samples5],
    Samples7 = lists:map(fun({t, Vals}) -> {t, Vals};
                            ({K, Vals}) -> {K, deltas(Vals)}
                         end,
                         Samples6),
    {ok, SamplesInterval, LastSampleTStamp, Samples7}.

% get_stats_raw() returns something like, where lists are sorted
% with most-recent last.
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

get_stats_raw(_PoolId, BucketId, SamplesNum) ->
    dict:to_list(stats_aggregator:get_stats(BucketId, SamplesNum)).

sum_stats_ops(Stats) ->
    sum_stats(["cmd_get", "cmd_set",
               "incr_misses", "incr_hits",
               "decr_misses", "decr_hits",
               "delete_misses", "delete_hits",
               "cas_misses", "cas_hits", "cas_badval",
               "cmd_flush"],
              Stats).

sum_stats([Key | Rest], Stats) ->
    sum_stats(Rest, Stats, proplists:get_value(Key, Stats)).

sum_stats([Key | Rest], Stats, undefined) ->
    sum_stats(Rest, Stats, proplists:get_value(Key, Stats));
sum_stats([], _Stats, undefined)    -> [];
sum_stats([], _Stats, Acc)          -> Acc;
sum_stats([Key | Rest], Stats, Acc) ->
    case proplists:get_value(Key, Stats) of
        undefined ->
            sum_stats(Rest, Stats, Acc);
        KeyStats ->
            Acc2 = lists:zipwith(fun(undefined, undefined) -> Acc;
                                    (undefined, _)         -> Acc;
                                    (_,         undefined) -> Acc;
                                    (X, Y) -> X + Y end, KeyStats, Acc),
            sum_stats(Rest, Stats, Acc2)
    end.

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

-endif.

