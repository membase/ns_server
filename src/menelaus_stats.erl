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
    % TODO.
    [{cacheSize, NumNodes * MbPerNode},
     {opsPerSec, 100},
     {evictionsPerSec, 5},
     {cachePercentUsed, 50}].

handle_bucket_stats(PoolId, all, Req) ->
    % TODO: get aggregate stats for all buckets.
    handle_bucket_stats(PoolId, "default", Req);

handle_bucket_stats(PoolId, Id, Req) ->
    Now = java_date(),
    Params = Req:parse_qs(),
    Res = build_bucket_stats_response(PoolId, Id, Params, Now),
    reply_json(Req, Res).

%% Implementation

% get_stats() returns something like, where lists are sorted
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

get_stats(_PoolId, BucketId, SamplesNum) ->
    dict:to_list(stats_aggregator:get_stats(BucketId, SamplesNum)).

build_bucket_stats_response(PoolId, BucketId, _Params, _Now) ->
    SamplesInterval = 1, % A sample every second.
    SamplesNum = 60, % Sixty seconds worth of data.
    Samples = get_stats(PoolId, BucketId, SamplesNum),
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
                                    {misses, 100}]}]},
              {op, {struct, [{tstamp, LastSampleTStamp},
                             {samplesInterval, SamplesInterval}
                             | Samples2]}}]}.

-ifdef(EUNIT).

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

-endif.

