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
    {status, index_needs_restart};
do_recognize_name(_Indexer, <<"num_connections">>) ->
    {status, index_num_connections};
do_recognize_name(Indexer, K) ->
    MaybeService = [SS || SS <- Indexer:get_service_stats(),
                          atom_to_binary(SS, latin1) =:= K],
    case MaybeService of
        [] ->
            do_recognize_bucket_metric(Indexer, K);
        _ ->
            %% These are service related stats.
            NewKey = list_to_binary(Indexer:service_stat_prefix() ++
                                        binary_to_list(K)),
            {service, NewKey}
    end.

do_recognize_bucket_metric(Indexer, K) ->
    case binary:split(K, <<":">>, [global]) of
        [Bucket, Index, Metric] ->
            Type = find_type(Metric, [{gauge, Indexer:get_gauges()},
                                      {counter, Indexer:get_counters()}]),

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

massage_stats(_Indexer, _Ets, [], AccGauges, AccCounters, AccStatus, AccSS) ->
    {AccGauges, AccCounters, AccStatus, AccSS};
massage_stats(Indexer, Ets, [{K, V} | Rest], AccGauges, AccCounters,
              AccStatus, AccSS) ->
    case recognize_name(Indexer, Ets, K) of
        undefined ->
            massage_stats(Indexer, Ets, Rest, AccGauges, AccCounters, AccStatus,
                          AccSS);
        {counter, NewK} ->
            massage_stats(Indexer, Ets, Rest, AccGauges,
                          [{NewK, V} | AccCounters], AccStatus, AccSS);
        {gauge, NewK} ->
            massage_stats(Indexer, Ets, Rest, [{NewK, V} | AccGauges],
                          AccCounters, AccStatus, AccSS);
        {service, NewK} ->
            massage_stats(Indexer, Ets, Rest, AccGauges, AccCounters,
                          AccStatus, [{NewK, V} | AccSS]);
        {status, NewK} ->
            massage_stats(Indexer, Ets, Rest, AccGauges, AccCounters,
                          [{NewK, V} | AccStatus], AccSS)
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
    {Gauges0, Counters, Status, SS} = massage_stats(Indexer, ets_name(Indexer),
                                                    GrabbedStats,
                                                    [], [], [], []),
    Gauges = Indexer:compute_gauges(Gauges0) ++ Gauges0,

    {Stats, SortedCounters} =
        base_stats_collector:calculate_counters(TS, Gauges, Counters, PrevCounters, PrevTS),

    index_status_keeper:update(Indexer, Status),
    ServiceStats1 = Indexer:compute_service_stats(SS) ++ SS,
    ServiceStats = [{Indexer:service_event_name(),
                     finalize_index_stats(ServiceStats1)}],
    Prefix = Indexer:prefix(),
    AggregatedStats =
        [{Prefix ++ binary_to_list(Bucket), Values} ||
            {Bucket, Values} <- aggregate_index_stats(Indexer, Stats, KnownBuckets, Defaults)] ++ ServiceStats,
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
