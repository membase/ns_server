%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
-module(index_stats_collector).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").

-include("ns_stats.hrl").

%% API
-export([start_link/1]).
-export([per_index_stat/3, global_index_stat/2, prefix/1]).

%% callbacks
-export([init/1, handle_info/2, grab_stats/1, process_stats/5]).

-record(state, {type :: index | fts,
                default_stats,
                buckets}).

server_name(Type) ->
    list_to_atom(?MODULE_STRING "-" ++ atom_to_list(Type)).

ets_name(Type) ->
    list_to_atom(?MODULE_STRING "_names-" ++ atom_to_list(Type)).

get_gauges(index) ->
    [disk_size, data_size, num_docs_pending, num_docs_queued,
     items_count, frag_percent];
get_gauges(fts) ->
    [doc_count, num_pindexes].

get_counters(index) ->
    [num_requests, num_rows_returned, num_docs_indexed,
     scan_bytes_read, total_scan_duration];
get_counters(fts) ->
    [timer_batch_execute_count, timer_batch_merge_count, timer_batch_store_count,
     timer_iterator_next_count, timer_iterator_seek_count, timer_iterator_seek_first_count,
     timer_reader_get_count, timer_reader_iterator_count, timer_writer_delete_count,
     timer_writer_get_count, timer_writer_iterator_count, timer_writer_set_count,
     timer_opaque_set_count, timer_rollback_count, timer_data_update_count,
     timer_data_delete_count, timer_snapshot_start_count, timer_opaque_get_count].

get_computed(index) ->
    [disk_overhead_estimate];
get_computed(fts) ->
    [].

start_link(Type) ->
    base_stats_collector:start_link({local, server_name(Type)}, ?MODULE, Type).

init(Type) ->
    ets:new(ets_name(Type), [protected, named_table]),

    Self = self(),
    ns_pubsub:subscribe_link(
      ns_config_events,
      fun ({buckets, Buckets}) ->
              BucketConfigs = proplists:get_value(configs, Buckets, []),
              Self ! {buckets, ns_bucket:get_bucket_names(membase, BucketConfigs)};
          (_) ->
              ok
      end),

    Buckets = lists:map(fun list_to_binary/1, ns_bucket:get_bucket_names(membase)),
    Defaults = [{global_index_stat(Type, atom_to_binary(Stat, latin1)), 0}
                || Stat <- get_gauges(Type) ++ get_counters(Type) ++ get_computed(Type)],


    {ok, #state{type = Type,
                buckets = Buckets,
                default_stats = Defaults}}.

find_type(_, []) ->
    not_found;
find_type(Name, [{Type, Metrics} | Rest]) ->
    MaybeMetric = [Name || M <- Metrics,
                           atom_to_binary(M, latin1) =:= Name],

    case MaybeMetric of
        [_] ->
            Type;
        _ ->
            find_type(Name, Rest)
    end.

do_recognize_name(_IndexType, <<"needs_restart">>) ->
    {status, index_needs_restart};
do_recognize_name(_IndexType, <<"num_connections">>) ->
    {status, index_num_connections};
do_recognize_name(IndexType, K) ->
    case binary:split(K, <<":">>, [global]) of
        [Bucket, Index, Metric] ->
            Type = find_type(Metric, [{gauge, get_gauges(IndexType)},
                                      {counter, get_counters(IndexType)}]),

            case Type of
                not_found ->
                    undefined;
                _ ->
                    {Type, {Bucket, Index, Metric}}
            end;
        _ ->
            undefined
    end.

recognize_name(IndexType, Ets, K) ->
    case ets:lookup(Ets, K) of
        [{K, Type, NewK}] ->
            {Type, NewK};
        [{K, undefined}] ->
            undefined;
        [] ->
            case do_recognize_name(IndexType, K) of
                undefined ->
                    ets:insert(Ets, {K, undefined}),
                    undefined;
                {Type, NewK} ->
                    ets:insert(Ets, {K, Type, NewK}),
                    {Type, NewK}
            end
    end.

massage_stats(_Type, _Ets, [], AccGauges, AccCounters, AccStatus) ->
    {AccGauges, AccCounters, AccStatus};
massage_stats(Type, Ets, [{K, V} | Rest], AccGauges, AccCounters, AccStatus) ->
    case recognize_name(Type, Ets, K) of
        undefined ->
            massage_stats(Type, Ets, Rest, AccGauges, AccCounters, AccStatus);
        {counter, NewK} ->
            massage_stats(Type, Ets, Rest, AccGauges, [{NewK, V} | AccCounters], AccStatus);
        {gauge, NewK} ->
            massage_stats(Type, Ets, Rest, [{NewK, V} | AccGauges], AccCounters, AccStatus);
        {status, NewK} ->
            massage_stats(Type, Ets, Rest, AccGauges, AccCounters, [{NewK, V} | AccStatus])
    end.

grab_stats(#state{type = Type}) ->
    case ns_cluster_membership:should_run_service(ns_config:latest(), Type, node()) of
        true ->
            get_stats(Type);
        false ->
            []
    end.

do_get_stats(index) ->
    index_rest:get_json(index, "stats?async=true",
                        ns_config:read_key_fast({node, node(), index_http_port}, 9102),
                        ns_config:get_timeout(index_rest_request, 10000));
do_get_stats(fts) ->
    index_rest:get_json(fts, "api/nsstats",
                        ns_config:read_key_fast({node, node(), fts_http_port}, 9110),
                        ns_config:get_timeout(fts_rest_request, 10000)).

get_stats(Type) ->
    case do_get_stats(Type) of
        {ok, {[_|_] = Stats}} ->
            Stats;
        {ok, Other} ->
            ?log_error("Got invalid stats response for ~p:~n~p", [Type, Other]),
            [];
        {error, _} ->
            []
    end.

compute_gauges(index, Gauges0) ->
    compute_disk_overhead_estimates(Gauges0);
compute_gauges(fts, _) ->
    [].

prefix(Type) ->
    "@" ++ atom_to_list(Type) ++ "-".

process_stats(TS, GrabbedStats, PrevCounters, PrevTS, #state{type = Type,
                                                             buckets = KnownBuckets,
                                                             default_stats = Defaults} = State) ->
    {Gauges0, Counters, Status} = massage_stats(Type, ets_name(Type), GrabbedStats, [], [], []),
    Gauges = compute_gauges(Type, Gauges0) ++ Gauges0,

    {Stats, SortedCounters} =
        base_stats_collector:calculate_counters(TS, Gauges, Counters, PrevCounters, PrevTS),

    index_status_keeper:update(Type, Status),

    Prefix = prefix(Type),
    AggregatedStats =
        [{Prefix ++ binary_to_list(Bucket), Values} ||
            {Bucket, Values} <- aggregate_index_stats(Type, Stats, KnownBuckets, Defaults)],
    {AggregatedStats, SortedCounters, State}.

aggregate_index_stats(Type, Stats, Buckets, Defaults) ->
    do_aggregate_index_stats(Type, Stats, Buckets, Defaults, []).

do_aggregate_index_stats(_Type, [], Buckets, Defaults, Acc) ->
    [{B, Defaults} || B <- Buckets] ++ Acc;
do_aggregate_index_stats(Type, [{{Bucket, _, _}, _} | _] = Stats,
                         Buckets, Defaults, Acc) ->
    {BucketStats, RestStats} = aggregate_index_bucket_stats(Type, Bucket, Stats, Defaults),

    OtherBuckets = lists:delete(Bucket, Buckets),
    do_aggregate_index_stats(Type, RestStats, OtherBuckets, Defaults,
                             [{Bucket, BucketStats} | Acc]).

aggregate_index_bucket_stats(Type, Bucket, Stats, Defaults) ->
    do_aggregate_index_bucket_stats(Type, Defaults, Bucket, Stats).

do_aggregate_index_bucket_stats(_Type, Acc, _, []) ->
    {finalize_index_bucket_stats(Acc), []};
do_aggregate_index_bucket_stats(Type, Acc, Bucket, [{{Bucket, Index, Name}, V} | Rest]) ->
    Global = global_index_stat(Type, Name),
    PerIndex = per_index_stat(Type, Index, Name),

    Acc1 =
        case lists:keyfind(Global, 1, Acc) of
            false ->
                [{Global, V} | Acc];
            {_, OldV} ->
                lists:keyreplace(Global, 1, Acc, {Global, OldV + V})
        end,

    Acc2 = [{PerIndex, V} | Acc1],

    do_aggregate_index_bucket_stats(Type, Acc2, Bucket, Rest);
do_aggregate_index_bucket_stats(_Type, Acc, _, Stats) ->
    {finalize_index_bucket_stats(Acc), Stats}.

finalize_index_bucket_stats(Acc) ->
    lists:keysort(1, Acc).

aggregate_index_stats_test() ->
    In = [{{<<"a">>, <<"idx1">>, <<"m1">>}, 1},
          {{<<"a">>, <<"idx1">>, <<"m2">>}, 2},
          {{<<"b">>, <<"idx2">>, <<"m1">>}, 3},
          {{<<"b">>, <<"idx2">>, <<"m2">>}, 4},
          {{<<"b">>, <<"idx3">>, <<"m1">>}, 5},
          {{<<"b">>, <<"idx3">>, <<"m2">>}, 6}],
    Out = aggregate_index_stats(index, In, [], []),

    AStats0 = [{<<"index/idx1/m1">>, 1},
               {<<"index/idx1/m2">>, 2},
               {<<"index/m1">>, 1},
               {<<"index/m2">>, 2}],
    BStats0 = [{<<"index/idx2/m1">>, 3},
               {<<"index/idx2/m2">>, 4},
               {<<"index/idx3/m1">>, 5},
               {<<"index/idx3/m2">>, 6},
               {<<"index/m1">>, 3+5},
               {<<"index/m2">>, 4+6}],

    AStats = lists:keysort(1, AStats0),
    BStats = lists:keysort(1, BStats0),

    ?assertEqual(Out,
                 [{<<"b">>, BStats},
                  {<<"a">>, AStats}]).

handle_info({buckets, NewBuckets}, State) ->
    NewBuckets1 = lists:map(fun list_to_binary/1, NewBuckets),
    {noreply, State#state{buckets = NewBuckets1}};
handle_info(_Info, State) ->
    {noreply, State}.

per_index_stat(Type, Index, Metric) ->
    iolist_to_binary([atom_to_list(Type), <<"/">>, Index, $/, Metric]).

global_index_stat(Type, StatName) ->
    iolist_to_binary([atom_to_list(Type), <<"/">>, StatName]).

compute_disk_overhead_estimates(Stats) ->
    Dict = lists:foldl(
             fun ({StatKey, Value}, D) ->
                     {Bucket, Index, Metric} = StatKey,
                     Key = {Bucket, Index},

                     case Metric of
                         <<"frag_percent">> ->
                             misc:dict_update(
                               Key,
                               fun ({_, DiskSize}) ->
                                       {Value, DiskSize}
                               end, {undefined, undefined}, D);
                         <<"disk_size">> ->
                             misc:dict_update(
                               Key,
                               fun ({Frag, _}) ->
                                       {Frag, Value}
                               end, {undefined, undefined}, D);
                         _ ->
                             D
                     end
             end, dict:new(), Stats),

    dict:fold(
      fun ({Bucket, Index}, {Frag, DiskSize}, Acc) ->
              if
                  Frag =/= undefined andalso DiskSize =/= undefined ->
                      Est = (DiskSize * Frag) div 100,
                      [{{Bucket, Index, <<"disk_overhead_estimate">>}, Est} | Acc];
                  true ->
                      Acc
              end
      end, [], Dict).

compute_disk_overhead_estimates_test() ->
    In = [{{<<"a">>, <<"idx1">>, <<"disk_size">>}, 100},
          {{<<"a">>, <<"idx1">>, <<"frag_percent">>}, 0},
          {{<<"b">>, <<"idx2">>, <<"frag_percent">>}, 100},
          {{<<"b">>, <<"idx2">>, <<"disk_size">>}, 100},
          {{<<"b">>, <<"idx3">>, <<"disk_size">>}, 100},
          {{<<"b">>, <<"idx3">>, <<"frag_percent">>}, 50},
          {{<<"b">>, <<"idx3">>, <<"m">>}, 42}],
    Out = lists:keysort(1, compute_disk_overhead_estimates(In)),

    Expected0 = [{{<<"a">>, <<"idx1">>, <<"disk_overhead_estimate">>}, 0},
                 {{<<"b">>, <<"idx2">>, <<"disk_overhead_estimate">>}, 100},
                 {{<<"b">>, <<"idx3">>, <<"disk_overhead_estimate">>}, 50}],
    Expected = lists:keysort(1, Expected0),

    ?assertEqual(Expected, Out).
