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

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {prev_counters = [],
                prev_ts = 0}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
    ns_pubsub:subscribe_link(ns_tick_event),
    ets:new(index_stats_collector_names, [private, named_table]),
    {ok, #state{}}.

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

-define(I_GAUGES, [disk_size]).
-define(I_COUNTERS, [num_requests]).

%% do_recognize_name(<<"needs_restart">> = K) ->
%%     {gauge, K};
do_recognize_name(<<"num_connections">> = _K) ->
    {gauge, index_num_connections};
do_recognize_name(K) ->
    case binary:split(K, <<":">>, [global]) of
        [Bucket, Index, Metric] ->
            MaybeGauge = [Metric || NK <- ?I_GAUGES,
                                    NKT <- [atom_to_binary(NK, latin1)],
                                    NKT =:= Metric],
            MaybeCounter = [Metric || NK <- ?I_COUNTERS,
                                      NKT <- [atom_to_binary(NK, latin1)],
                                      NKT =:= Metric],
            case {MaybeGauge, MaybeCounter} of
                {[], []} -> undefined;
                {[Metric], []} ->
                    {gauge, {Bucket, Index, Metric}};
                {[], [Metric]} ->
                    {counter, {Bucket, Index, Metric}}
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

massage_stats([], AccGauges, AccCounters) ->
    {AccGauges, AccCounters};
massage_stats([{K, V} | Rest], AccGauges, AccCounters) ->
    case recognize_name(K) of
        undefined ->
            massage_stats(Rest, AccGauges, AccCounters);
        {counter, NewK} ->
            massage_stats(Rest, AccGauges, [{NewK, list_to_integer(binary_to_list(V))} | AccCounters]);
        {gauge, NewK} ->
            massage_stats(Rest, [{NewK, list_to_integer(binary_to_list(V))} | AccGauges], AccCounters)
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
    URL = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/stats", [Port])),
    User = ns_config_auth:get_user(special),
    Pwd = ns_config_auth:get_password(special),
    Headers = menelaus_rest:add_basic_auth([], User, Pwd),
    RV = lhttpc:request(binary_to_list(URL), "GET", Headers, [], 30000, []),
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
    {StatsGauges, StatsCounters0} = massage_stats(get_stats(), [], []),
    StatsCounters = lists:sort(StatsCounters0),
    Stats0 = diff_counters(1000.0 / TSDiff, StatsCounters, PrevCounters, []),
    Stats = lists:merge(Stats0, lists:sort(StatsGauges)),
    {Stats, StatsCounters}.

aggregate_index_stats([]) ->
    [];
aggregate_index_stats([{B, {_B, _I, K}, V} = Triple | Rest]) ->
    [Triple | aggregate_index_stats_loop(B, [{B, K, V}], Rest)].

aggregate_index_stats_loop(B, Acc, [{B2, {_B, _I, K}, V} = Triple | Rest] = List) ->
    case B =:= B2 of
        true ->
            Acc2 = case lists:keyfind(K, 2, Acc) of
                       false ->
                           [{B, K, V} | Acc];
                       {_B, _K, AccV} ->
                           lists:keyreplace(K, 2, Acc, {B, K, AccV + V})
                   end,
            [Triple | aggregate_index_stats_loop(B, Acc2, Rest)];
        false ->
            lists:reverse(Acc) ++ aggregate_index_stats(List)
    end;
aggregate_index_stats_loop(_B, Acc, []) ->
    lists:reverse(Acc).

aggregate_index_stats_test() ->
    In = [{{<<"a">>, <<"idx1">>, <<"m1">>}, 1},
          {{<<"a">>, <<"idx1">>, <<"m2">>}, 2},
          {{<<"b">>, <<"idx2">>, <<"m1">>}, 3},
          {{<<"b">>, <<"idx2">>, <<"m2">>}, 4},
          {{<<"b">>, <<"idx3">>, <<"m1">>}, 5},
          {{<<"b">>, <<"idx3">>, <<"m2">>}, 6}],
    In1 = [{B, K, V} || {{B, _, _} = K, V} <- In],
    Out = aggregate_index_stats(In1),
    ?assertEqual([{<<"a">>, {<<"a">>, <<"idx1">>, <<"m1">>}, 1},
                  {<<"a">>, {<<"a">>, <<"idx1">>, <<"m2">>}, 2},
                  {<<"a">>, <<"m1">>, 1},
                  {<<"a">>, <<"m2">>, 2},
                  {<<"b">>, {<<"b">>, <<"idx2">>, <<"m1">>}, 3},
                  {<<"b">>, {<<"b">>, <<"idx2">>, <<"m2">>}, 4},
                  {<<"b">>, {<<"b">>, <<"idx3">>, <<"m1">>}, 5},
                  {<<"b">>, {<<"b">>, <<"idx3">>, <<"m2">>}, 6},
                  {<<"b">>, <<"m1">>, 3+5},
                  {<<"b">>, <<"m2">>, 4+6}],
                 Out).

handle_info({tick, TS0}, #state{prev_counters = PrevCounters,
                                prev_ts = PrevTS}) ->
    TS = latest_tick(TS0, 0),
    {Stats, NewCounters} = grab_stats(PrevCounters, TS - PrevTS),
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
    NumConnections = proplists:get_value(index_num_connections, Stats, 0),
    index_status_keeper:update(NumConnections, Indexes),
    BucketStats = aggregate_index_stats([{B, K, V} || {{B, _, _} = K, V} <- Stats]),
    PerBucketStats = misc:keygroup(1, BucketStats),
    [begin
         Values = lists:keysort(1, [{format_k(K), V} || {_, K, V} <- S]),
         gen_event:notify(ns_stats_event,
                          {stats, "@index-"++binary_to_list(B),
                           #stat_entry{timestamp = TS,
                                       values = Values}})
     end || {B, S} <- PerBucketStats],
    {noreply, #state{prev_counters = NewCounters,
                     prev_ts = TS}};
handle_info(_Info, State) ->
    {noreply, State}.

format_k({_Bucket, Index, Metric}) ->
    iolist_to_binary([<<"index/">>, Index, "/", Metric]);
format_k(Metric) when is_binary(Metric) ->
    iolist_to_binary([<<"index/">>, Metric]).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
