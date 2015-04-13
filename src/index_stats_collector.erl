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

-behaviour(gen_server).

-include("ns_common.hrl").

-include("ns_stats.hrl").

%% API
-export([start_link/0]).
-export([per_index_stat/2, global_index_stat/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {prev_counters = [],
                prev_ts = 0,
                default_stats,
                buckets}).

-define(I_GAUGES, [disk_size, data_size, num_docs_pending, items_count]).
-define(I_COUNTERS, [num_requests, num_rows_returned, num_docs_indexed,
                     scan_bytes_read, total_scan_duration]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
    ns_pubsub:subscribe_link(ns_tick_event),
    ets:new(index_stats_collector_names, [protected, named_table]),

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
    Defaults = [{global_index_stat(atom_to_binary(Stat, latin1)), 0}
                || Stat <- ?I_GAUGES ++ ?I_COUNTERS],


    {ok, #state{buckets = Buckets,
                default_stats = Defaults}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

latest_tick(TS, NumDropped) ->
    receive
        {tick, TS1} ->
            latest_tick(TS1, NumDropped + 1)
    after 0 ->
            if NumDropped > 0 ->
                    ?stats_warning("Dropped ~b ticks", [NumDropped]);
               true ->
                    ok
            end,
            TS
    end.

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

do_recognize_name(<<"needs_restart">>) ->
    {status, index_needs_restart};
do_recognize_name(<<"num_connections">>) ->
    {status, index_num_connections};
do_recognize_name(K) ->
    case binary:split(K, <<":">>, [global]) of
        [Bucket, Index, Metric] ->
            Type = find_type(Metric, [{gauge, ?I_GAUGES},
                                      {counter, ?I_COUNTERS}]),

            case Type of
                not_found ->
                    undefined;
                _ ->
                    {Type, {Bucket, Index, Metric}}
            end;
        _ ->
            undefined
    end.

recognize_name(K) ->
    case ets:lookup(index_stats_collector_names, K) of
        [{K, Type, NewK}] ->
            {Type, NewK};
        [{K, undefined}] ->
            undefined;
        [] ->
            case do_recognize_name(K) of
                undefined ->
                    ets:insert(index_stats_collector_names, {K, undefined}),
                    undefined;
                {Type, NewK} ->
                    ets:insert(index_stats_collector_names, {K, Type, NewK}),
                    {Type, NewK}
            end
    end.

massage_stats([], AccGauges, AccCounters, AccStatus) ->
    {AccGauges, AccCounters, AccStatus};
massage_stats([{K, V} | Rest], AccGauges, AccCounters, AccStatus) ->
    case recognize_name(K) of
        undefined ->
            massage_stats(Rest, AccGauges, AccCounters, AccStatus);
        {counter, NewK} ->
            massage_stats(Rest, AccGauges, [{NewK, V} | AccCounters], AccStatus);
        {gauge, NewK} ->
            massage_stats(Rest, [{NewK, V} | AccGauges], AccCounters, AccStatus);
        {status, NewK} ->
            massage_stats(Rest, AccGauges, AccCounters, [{NewK, V} | AccStatus])
    end.

get_stats() ->
    case ns_cluster_membership:should_run_service(ns_config:latest_config_marker(), index, node()) of
        true ->
            do_get_stats();
        false ->
            []
    end.

do_get_stats() ->
    Port = ns_config:search(ns_config:latest_config_marker(), {node, node(), indexer_http_port}, 9102),
    URL = lists:flatten(io_lib:format("http://127.0.0.1:~B/stats", [Port])),
    User = ns_config_auth:get_user(special),
    Pwd = ns_config_auth:get_password(special),
    Headers = menelaus_rest:add_basic_auth([], User, Pwd),
    RV = rest_utils:request(indexer, URL, "GET", Headers, [], 30000),
    case RV of
        {ok, {{200, _}, _Headers, BodyRaw}} ->
            case (catch ejson:decode(BodyRaw)) of
                {[_|_] = Stats} ->
                    Stats;
                Err ->
                    ?log_error("Failed to parse query stats: ~p", [Err]),
                    []
            end;
        _ ->
            ?log_error("Ignoring. Failed to grab stats: ~p", [RV]),
            []
    end.

diff_counters(_InvTSDiff, [], _PrevCounters, Acc) ->
    lists:reverse(Acc);
diff_counters(InvTSDiff, [{K, V} | RestCounters] = Counters, PrevCounters, Acc) ->
    case PrevCounters of
        %% NOTE: K is bound
        [{K, OldV} | RestPrev] ->
            D = (V - OldV) * InvTSDiff,
            diff_counters(InvTSDiff, RestCounters, RestPrev, [{K, D} | Acc]);
        [{PrevK, _} | RestPrev] when PrevK < K->
            diff_counters(InvTSDiff, Counters, RestPrev, Acc);
        _ ->
            diff_counters(InvTSDiff, RestCounters, PrevCounters, [{K, 0} | Acc])
    end.

grab_stats(PrevCounters, TSDiff) ->
    {StatsGauges, StatsCounters0, Status} = massage_stats(get_stats(), [], [], []),
    StatsCounters = lists:sort(StatsCounters0),
    Stats0 = diff_counters(1000.0 / TSDiff, StatsCounters, PrevCounters, []),
    Stats = lists:merge(Stats0, lists:sort(StatsGauges)),
    {Stats, StatsCounters, Status}.

aggregate_index_stats(Stats, Buckets, Defaults) ->
    do_aggregate_index_stats(Stats, Buckets, Defaults, []).

do_aggregate_index_stats([], Buckets, Defaults, Acc) ->
    [{B, Defaults} || B <- Buckets] ++ Acc;
do_aggregate_index_stats([{{Bucket, _, _}, _} | _] = Stats,
                         Buckets, Defaults, Acc) ->
    {BucketStats, RestStats} = aggregate_index_bucket_stats(Bucket, Stats, Defaults),

    OtherBuckets = lists:delete(Bucket, Buckets),
    do_aggregate_index_stats(RestStats, OtherBuckets, Defaults,
                             [{Bucket, BucketStats} | Acc]).

aggregate_index_bucket_stats(Bucket, Stats, Defaults) ->
    do_aggregate_index_bucket_stats(Defaults, Bucket, Stats).

do_aggregate_index_bucket_stats(Acc, _, []) ->
    {finalize_index_bucket_stats(Acc), []};
do_aggregate_index_bucket_stats(Acc, Bucket, [{{Bucket, Index, Name}, V} | Rest]) ->
    Global = global_index_stat(Name),
    PerIndex = per_index_stat(Index, Name),

    Acc1 =
        case lists:keyfind(Global, 1, Acc) of
            false ->
                [{Global, V} | Acc];
            {_, OldV} ->
                lists:keyreplace(Global, 1, Acc, {Global, OldV + V})
        end,

    Acc2 = [{PerIndex, V} | Acc1],

    do_aggregate_index_bucket_stats(Acc2, Bucket, Rest);
do_aggregate_index_bucket_stats(Acc, _, Stats) ->
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
    Out = aggregate_index_stats(In, [], []),

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

handle_info({tick, TS0}, #state{prev_counters = PrevCounters,
                                prev_ts = PrevTS,
                                buckets = KnownBuckets,
                                default_stats = Defaults} = State) ->
    TS = latest_tick(TS0, 0),
    {Stats, NewCounters, Status} = grab_stats(PrevCounters, TS - PrevTS),
    Indexes = lists:foldl(
                fun ({{B, I, _K}, _V}, Acc) ->
                        case Acc of
                            %% B is bound already
                            [{B, BL} | RestAcc] ->
                                case BL of
                                    %% I is bound already
                                    [I | _] ->
                                        Acc;
                                    _ ->
                                        [{B, [I | BL]} | RestAcc]
                                end;
                            _ ->
                                [{B, [I]} | Acc]
                        end;
                    ({_K, _V}, Acc) ->
                        Acc
                end, [], Stats),
    NumConnections = proplists:get_value(index_num_connections, Status, 0),
    NeedsRestart = proplists:get_value(index_needs_restart, Status, false),
    index_status_keeper:update(NumConnections, NeedsRestart, Indexes),

    lists:foreach(
      fun ({Bucket, BucketStats}) ->
              gen_event:notify(ns_stats_event,
                               {stats, "@index-"++binary_to_list(Bucket),
                                #stat_entry{timestamp = TS,
                                            values = BucketStats}})
      end, aggregate_index_stats(Stats, KnownBuckets, Defaults)),

    {noreply, State#state{prev_counters = NewCounters,
                          prev_ts = TS}};
handle_info({buckets, NewBuckets}, State) ->
    NewBuckets1 = lists:map(fun list_to_binary/1, NewBuckets),
    {noreply, State#state{buckets = NewBuckets1}};
handle_info(_Info, State) ->
    {noreply, State}.

per_index_stat(Index, Metric) ->
    iolist_to_binary([<<"index/">>, Index, $/, Metric]).

global_index_stat(StatName) ->
    iolist_to_binary([<<"index/">>, StatName]).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
