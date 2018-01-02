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

%% callbacks
-export([init/1, handle_info/2, grab_stats/1, process_stats/5]).

-record(state, {indexer :: atom(),
                default_stats,
                buckets}).

-record(stats_accumulators, {
          gauges = [],
          counters = [],
          sys_gauges = [],
          sys_counters = [],
          status = []
         }).

server_name(Indexer) ->
    list_to_atom(?MODULE_STRING "-" ++ atom_to_list(Indexer:get_type())).

ets_name(Indexer) ->
    list_to_atom(?MODULE_STRING "_names-" ++ atom_to_list(Indexer:get_type())).

start_link(Indexer) ->
    base_stats_collector:start_link({local, server_name(Indexer)}, ?MODULE, Indexer).

init(Indexer) ->
    ets:new(ets_name(Indexer), [protected, named_table]),

    Self = self(),
    ns_pubsub:subscribe_link(
      ns_config_events,
      fun ({buckets, Buckets}) ->
              BucketConfigs = proplists:get_value(configs, Buckets, []),
              BucketsList = ns_bucket:get_bucket_names_of_type(membase, couchstore, BucketConfigs) ++
                  ns_bucket:get_bucket_names_of_type(membase, ephemeral, BucketConfigs),
              Self ! {buckets, BucketsList};
          (_) ->
              ok
      end),

    Buckets = lists:map(fun list_to_binary/1,
                        ns_bucket:get_bucket_names_of_type(membase, couchstore) ++
                            ns_bucket:get_bucket_names_of_type(membase, ephemeral)),
    Defaults = [{Indexer:global_index_stat(atom_to_binary(Stat, latin1)), 0}
                || Stat <- Indexer:get_gauges() ++ Indexer:get_counters() ++ Indexer:get_computed()],


    {ok, #state{indexer = Indexer,
                buckets = Buckets,
                default_stats = finalize_index_stats(Defaults)}}.

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

do_recognize_name(_Indexer, <<"needs_restart">>) ->
    {#stats_accumulators.status, index_needs_restart};
do_recognize_name(_Indexer, <<"num_connections">>) ->
    {#stats_accumulators.status, index_num_connections};
do_recognize_name(Indexer, K) ->
    Type = find_type(K, [{#stats_accumulators.sys_gauges, Indexer:get_service_gauges()},
                         {#stats_accumulators.sys_counters, Indexer:get_service_counters()}]),
    case Type of
        not_found ->
            do_recognize_bucket_metric(Indexer, K);
        _ ->
            NewKey = list_to_binary(Indexer:service_stat_prefix() ++
                                        binary_to_list(K)),
            {Type, NewKey}
    end.

do_recognize_bucket_metric(Indexer, K) ->
    case binary:split(K, <<":">>, [global]) of
        [Bucket, Index, Metric] ->
            Type = find_type(Metric, [{#stats_accumulators.gauges, Indexer:get_gauges()},
                                      {#stats_accumulators.counters, Indexer:get_counters()}]),

            case Type of
                not_found ->
                    undefined;
                _ ->
                    {Type, {Bucket, Index, Metric}}
            end;
        _ ->
            undefined
    end.

recognize_name(Indexer, Ets, K) ->
    case ets:lookup(Ets, K) of
        [{K, Type, NewK}] ->
            {Type, NewK};
        [{K, undefined}] ->
            undefined;
        [] ->
            case do_recognize_name(Indexer, K) of
                undefined ->
                    ets:insert(Ets, {K, undefined}),
                    undefined;
                {Type, NewK} ->
                    ets:insert(Ets, {K, Type, NewK}),
                    {Type, NewK}
            end
    end.

massage_stats(Indexer, Ets, GrabbedStats) ->
    massage_stats(Indexer, Ets, GrabbedStats, #stats_accumulators{}).

massage_stats(_Indexer, _Ets, [], Acc) ->
    Acc;
massage_stats(Indexer, Ets, [{K, V} | Rest], Acc) ->
    case recognize_name(Indexer, Ets, K) of
        undefined ->
            massage_stats(Indexer, Ets, Rest, Acc);
        {Pos, NewK} ->
            massage_stats(
              Indexer, Ets, Rest, setelement(Pos, Acc, [{NewK, V} | element(Pos, Acc)]))
    end.

grab_stats(#state{indexer = Indexer}) ->
    case ns_cluster_membership:should_run_service(ns_config:latest(), Indexer:get_type(), node()) of
        true ->
            do_grab_stats(Indexer);
        false ->
            []
    end.

do_grab_stats(Indexer) ->
    case Indexer:grab_stats() of
        {ok, {[_|_] = Stats}} ->
            Stats;
        {ok, Other} ->
            ?log_error("Got invalid stats response for ~p:~n~p", [Indexer, Other]),
            [];
        {error, _} ->
            []
    end.

process_stats(TS, GrabbedStats, PrevCounters, PrevTS, #state{indexer = Indexer,
                                                             buckets = KnownBuckets,
                                                             default_stats = Defaults} = State) ->
    MassagedStats =
        massage_stats(Indexer, ets_name(Indexer), GrabbedStats),

    CalculateStats =
        fun (GaugesPos, CountersPos, ComputeGauges) ->
                Gauges0 = element(GaugesPos, MassagedStats),
                Gauges = Indexer:ComputeGauges(Gauges0) ++ Gauges0,
                Counters = element(CountersPos, MassagedStats),
                base_stats_collector:calculate_counters(TS, Gauges, Counters, PrevCounters, PrevTS)
        end,

    index_status_keeper:update(Indexer, MassagedStats#stats_accumulators.status),

    {Stats, SortedBucketCounters} =
        CalculateStats(#stats_accumulators.gauges, #stats_accumulators.counters, compute_gauges),
    {ServiceStats1, SortedServiceCounters} =
        CalculateStats(#stats_accumulators.sys_gauges, #stats_accumulators.sys_counters,
                       compute_service_gauges),

    ServiceStats = [{Indexer:service_event_name(),
                     finalize_index_stats(ServiceStats1)}],
    Prefix = Indexer:prefix(),
    AggregatedStats =
        [{Prefix ++ binary_to_list(Bucket), Values} ||
            {Bucket, Values} <- aggregate_index_stats(Indexer, Stats, KnownBuckets, Defaults)] ++
        ServiceStats,

    AllCounters = SortedBucketCounters ++ SortedServiceCounters,
    SortedCounters = lists:sort(AllCounters),
    {AggregatedStats, SortedCounters, State}.

aggregate_index_stats(Indexer, Stats, Buckets, Defaults) ->
    do_aggregate_index_stats(Indexer, Stats, Buckets, Defaults, []).

do_aggregate_index_stats(_Indexer, [], Buckets, Defaults, Acc) ->
    [{B, Defaults} || B <- Buckets] ++ Acc;
do_aggregate_index_stats(Indexer, [{{Bucket, _, _}, _} | _] = Stats,
                         Buckets, Defaults, Acc) ->
    {BucketStats, RestStats} = aggregate_index_bucket_stats(Indexer, Bucket, Stats, Defaults),

    OtherBuckets = lists:delete(Bucket, Buckets),
    do_aggregate_index_stats(Indexer, RestStats, OtherBuckets, Defaults,
                             [{Bucket, BucketStats} | Acc]).

aggregate_index_bucket_stats(Indexer, Bucket, Stats, Defaults) ->
    do_aggregate_index_bucket_stats(Indexer, Defaults, Bucket, Stats).

do_aggregate_index_bucket_stats(_Indexer, Acc, _, []) ->
    {finalize_index_stats(Acc), []};
do_aggregate_index_bucket_stats(Indexer, Acc, Bucket, [{{Bucket, Index, Name}, V} | Rest]) ->
    Global = Indexer:global_index_stat(Name),
    PerIndex = Indexer:per_index_stat(Index, Name),

    Acc1 =
        case lists:keyfind(Global, 1, Acc) of
            false ->
                [{Global, V} | Acc];
            {_, OldV} ->
                lists:keyreplace(Global, 1, Acc, {Global, OldV + V})
        end,

    Acc2 = [{PerIndex, V} | Acc1],

    do_aggregate_index_bucket_stats(Indexer, Acc2, Bucket, Rest);
do_aggregate_index_bucket_stats(_Indexer, Acc, _, Stats) ->
    {finalize_index_stats(Acc), Stats}.

finalize_index_stats(Acc) ->
    lists:keysort(1, Acc).

aggregate_index_stats_test() ->
    In = [{{<<"a">>, <<"idx1">>, <<"m1">>}, 1},
          {{<<"a">>, <<"idx1">>, <<"m2">>}, 2},
          {{<<"b">>, <<"idx2">>, <<"m1">>}, 3},
          {{<<"b">>, <<"idx2">>, <<"m2">>}, 4},
          {{<<"b">>, <<"idx3">>, <<"m1">>}, 5},
          {{<<"b">>, <<"idx3">>, <<"m2">>}, 6}],
    Out = aggregate_index_stats(indexer_gsi, In, [], []),

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
