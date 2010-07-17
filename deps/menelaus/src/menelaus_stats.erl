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

-export([handle_bucket_stats/3, basic_stats/2]).

%% External API

basic_stats(_PoolId, "default") ->
    {Samples, _, _, _} = grab_op_stats("default", [{"zoom", "minute"}]),
    LastSample = case Samples of
                     [] -> [{X, [0]} || X <- tuple_to_list({timestamp, ?STAT_GAUGES, ?STAT_COUNTERS})];
                     _ -> samples_to_proplists([lists:last(Samples)])
                 end,
    GetValue = fun (Name) ->
                       hd(proplists:get_value(Name, LastSample))
               end,
    Ops = GetValue(ops),
    Fetches = GetValue(ep_io_num_read),
    MemUsed = GetValue(mem_used),
    QuotaMB = lists:sum([ns_storage_conf:memory_quota(N) || N <- ns_node_disco:nodes_wanted()]), 
    ItemCount = GetValue(curr_items),
    [{opsPerSec, Ops},
     {diskFetches, Fetches},
     {quotaPercentUsed, try (MemUsed * 100.0 / (QuotaMB * 1048576.0)) of
                            X -> X
                        catch
                            error:badarith -> 0
                        end},
     {itemCount, ItemCount}].

%% GET /pools/default/stats
%% Supported query params:
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
    BucketNames = menelaus_web:all_accessible_bucket_names(PoolId, Req),
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
    RV = case Step of
             1 ->
                 Period = minute,
                 stats_archiver:latest(minute, NodeS, Bucket, 60);
             _ ->
                 stats_archiver:latest(Period, NodeS, Bucket, Step, 60)
         end,
    case is_list(NodeS) of
        true -> [{K, V} || {K, {ok, V}} <- RV];
        _ ->
            case RV of
                {ok, List} -> List;
                _ -> []
            end
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

samples_to_proplists(Samples) ->
    StatsList = tuple_to_list({timestamp, ?STAT_GAUGES, ?STAT_COUNTERS}),
    EmptyLists = [[] || _ <- StatsList],
    PropList0 = lists:zip(StatsList,
                         lists:foldl(fun (Sample, Acc) ->
                                             [[X | Y] || {X,Y} <- lists:zip(tl(tuple_to_list(Sample)), Acc)]
                                     end, EmptyLists, Samples)),
    PropList1 = [{K, lists:reverse(V)} || {K,V} <- PropList0],
    add_stat_sums(PropList1).

build_buckets_stats_ops_response(_PoolId, ["default"], Params) ->
    {Samples0, ClientTStamp, Step, TotalNumber} = grab_op_stats("default", Params),
    Samples = case Samples0 of
                  [#stat_entry{bytes_read = undefined} | T] -> T;
                  _ -> Samples0
              end,
    PropList2 = samples_to_proplists(Samples),
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

build_buckets_stats_hks_response(_PoolId, ["default"]) ->
    BucketsTopKeys = case hot_keys_keeper:bucket_hot_keys("default") of
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
