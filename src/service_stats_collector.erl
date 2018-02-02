%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2015-2018 Couchbase, Inc.
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
-module(service_stats_collector).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").

-include("ns_stats.hrl").

%% API
-export([start_link/1, service_prefix/1, service_event_name/1]).

%% callbacks
-export([init/1, handle_info/2, grab_stats/1, process_stats/5]).

-record(state, {service :: atom(),
                default_stats,
                buckets}).

-record(stats_accumulators, {
          gauges = [],
          counters = [],
          sys_gauges = [],
          sys_counters = [],
          status = []
         }).

server_name(Service) ->
    list_to_atom(?MODULE_STRING "-" ++ atom_to_list(Service:get_type())).

ets_name(Service) ->
    list_to_atom(?MODULE_STRING "_names-" ++ atom_to_list(Service:get_type())).

start_link(Service) ->
    base_stats_collector:start_link({local, server_name(Service)}, ?MODULE,
                                    Service).

service_prefix(Service) ->
    "@" ++ atom_to_list(Service:get_type()) ++ "-".

service_stat_prefix(Service) ->
    atom_to_list(Service:get_type()) ++ "_".

service_event_name(Service) ->
    "@" ++ atom_to_list(Service:get_type()).

init(Service) ->
    ets:new(ets_name(Service), [protected, named_table]),

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
    Defaults = [{Service:global_index_stat(atom_to_binary(Stat, latin1)), 0}
                || Stat <- Service:get_gauges() ++ Service:get_counters() ++
                       Service:get_computed()],


    {ok, #state{service = Service,
                buckets = Buckets,
                default_stats = finalize_stats(Defaults)}}.

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

do_recognize_name(_Service, <<"needs_restart">>) ->
    {#stats_accumulators.status, index_needs_restart};
do_recognize_name(_Service, <<"num_connections">>) ->
    {#stats_accumulators.status, index_num_connections};
do_recognize_name(Service, K) ->
    Type = find_type(K, [{#stats_accumulators.sys_gauges,
                          Service:get_service_gauges()},
                         {#stats_accumulators.sys_counters,
                          Service:get_service_counters()}]),
    case Type of
        not_found ->
            do_recognize_bucket_metric(Service, K);
        _ ->
            NewKey = list_to_binary(service_stat_prefix(Service) ++
                                        binary_to_list(K)),
            {Type, NewKey}
    end.

do_recognize_bucket_metric(Service, K) ->
    case binary:split(K, <<":">>, [global]) of
        [Bucket, Item, Metric] ->
            Type = find_type(Metric, [{#stats_accumulators.gauges,
                                       Service:get_gauges()},
                                      {#stats_accumulators.counters,
                                       Service:get_counters()}]),

            case Type of
                not_found ->
                    undefined;
                _ ->
                    {Type, {Bucket, Item, Metric}}
            end;
        _ ->
            undefined
    end.

recognize_name(Service, Ets, K) ->
    case ets:lookup(Ets, K) of
        [{K, Type, NewK}] ->
            {Type, NewK};
        [{K, undefined}] ->
            undefined;
        [] ->
            case do_recognize_name(Service, K) of
                undefined ->
                    ets:insert(Ets, {K, undefined}),
                    undefined;
                {Type, NewK} ->
                    ets:insert(Ets, {K, Type, NewK}),
                    {Type, NewK}
            end
    end.

massage_stats(Service, Ets, GrabbedStats) ->
    massage_stats(Service, Ets, GrabbedStats, #stats_accumulators{}).

massage_stats(_Service, _Ets, [], Acc) ->
    Acc;
massage_stats(Service, Ets, [{K, V} | Rest], Acc) ->
    case recognize_name(Service, Ets, K) of
        undefined ->
            massage_stats(Service, Ets, Rest, Acc);
        {Pos, NewK} ->
            massage_stats(
              Service, Ets, Rest,
              setelement(Pos, Acc, [{NewK, V} | element(Pos, Acc)]))
    end.

grab_stats(#state{service = Service}) ->
    case ns_cluster_membership:should_run_service(ns_config:latest(),
                                                  Service:get_type(), node()) of
        true ->
            do_grab_stats(Service);
        false ->
            []
    end.

do_grab_stats(Service) ->
    case Service:grab_stats() of
        {ok, {[_|_] = Stats}} ->
            Stats;
        {ok, Other} ->
            ?log_error("Got invalid stats response for ~p:~n~p",
                       [Service, Other]),
            [];
        {error, _} ->
            []
    end.

process_stats(TS, GrabbedStats, PrevCounters, PrevTS,
              #state{service = Service,
                     buckets = KnownBuckets,
                     default_stats = Defaults} = State) ->
    MassagedStats =
        massage_stats(Service, ets_name(Service), GrabbedStats),

    CalculateStats =
        fun (GaugesPos, CountersPos, ComputeGauges) ->
                Gauges0 = element(GaugesPos, MassagedStats),
                Gauges = Service:ComputeGauges(Gauges0) ++ Gauges0,
                Counters = element(CountersPos, MassagedStats),
                base_stats_collector:calculate_counters(TS, Gauges, Counters, PrevCounters, PrevTS)
        end,

    service_status_keeper:update(Service,
                                 MassagedStats#stats_accumulators.status),

    {Stats, SortedBucketCounters} =
        CalculateStats(#stats_accumulators.gauges, #stats_accumulators.counters, compute_gauges),
    {ServiceStats1, SortedServiceCounters} =
        CalculateStats(#stats_accumulators.sys_gauges, #stats_accumulators.sys_counters,
                       compute_service_gauges),

    ServiceStats = [{service_event_name(Service),
                     finalize_stats(ServiceStats1)}],
    Prefix = service_prefix(Service),
    AggregatedStats =
        [{Prefix ++ binary_to_list(Bucket), Values} ||
            {Bucket, Values} <-
                aggregate_stats(Service, Stats, KnownBuckets, Defaults)] ++
        ServiceStats,

    AllCounters = SortedBucketCounters ++ SortedServiceCounters,
    SortedCounters = lists:sort(AllCounters),
    {AggregatedStats, SortedCounters, State}.

aggregate_stats(Service, Stats, Buckets, Defaults) ->
    do_aggregate_stats(Service, Stats, Buckets, Defaults, []).

do_aggregate_stats(_Service, [], Buckets, Defaults, Acc) ->
    [{B, Defaults} || B <- Buckets] ++ Acc;
do_aggregate_stats(Service, [{{Bucket, _, _}, _} | _] = Stats,
                   Buckets, Defaults, Acc) ->
    {BucketStats, RestStats} =
        aggregate_bucket_stats(Service, Bucket, Stats, Defaults),

    OtherBuckets = lists:delete(Bucket, Buckets),
    do_aggregate_stats(Service, RestStats, OtherBuckets, Defaults,
                       [{Bucket, BucketStats} | Acc]).

aggregate_bucket_stats(Service, Bucket, Stats, Defaults) ->
    do_aggregate_bucket_stats(Service, Defaults, Bucket, Stats).

do_aggregate_bucket_stats(_Service, Acc, _, []) ->
    {finalize_stats(Acc), []};
do_aggregate_bucket_stats(Service, Acc, Bucket,
                          [{{Bucket, Item, Name}, V} | Rest]) ->
    Global = Service:global_index_stat(Name),
    PerItem = Service:per_index_stat(Item, Name),

    Acc1 =
        case lists:keyfind(Global, 1, Acc) of
            false ->
                [{Global, V} | Acc];
            {_, OldV} ->
                lists:keyreplace(Global, 1, Acc, {Global, OldV + V})
        end,

    Acc2 = [{PerItem, V} | Acc1],

    do_aggregate_bucket_stats(Service, Acc2, Bucket, Rest);
do_aggregate_bucket_stats(_Service, Acc, _, Stats) ->
    {finalize_stats(Acc), Stats}.

finalize_stats(Acc) ->
    lists:keysort(1, Acc).

aggregate_stats_test() ->
    In = [{{<<"a">>, <<"idx1">>, <<"m1">>}, 1},
          {{<<"a">>, <<"idx1">>, <<"m2">>}, 2},
          {{<<"b">>, <<"idx2">>, <<"m1">>}, 3},
          {{<<"b">>, <<"idx2">>, <<"m2">>}, 4},
          {{<<"b">>, <<"idx3">>, <<"m1">>}, 5},
          {{<<"b">>, <<"idx3">>, <<"m2">>}, 6}],
    Out = aggregate_stats(service_index, In, [], []),

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
