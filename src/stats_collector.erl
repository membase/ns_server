%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

-module(stats_collector).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

-behaviour(gen_server).

-define(BUCKET_SIZE_UNIT, 1048576).
-define(STATS_TIMER, 1000).
-define(TOPKEYS_TIMER, 10000).

%% API
-export([start_link/0]).

-record(state, {}).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, _} = timer:send_interval(?STATS_TIMER, collect_stats),
    {ok, _} = timer:send_interval(?TOPKEYS_TIMER, collect_topkeys),
    {ok, #state{}}.

handle_call(Request, From, State) ->
    error_logger:info_msg("stats_collector:handle_call(~p, ~p, ~p)~n",
                          [Request, From, State]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    error_logger:info_msg("stats_collector:handle_cast(~p, ~p)~n",
                          [Msg, State]),
    {noreply, State}.

handle_info(collect_stats, State) ->
    collect_stats(),
    {noreply, State};
handle_info(collect_topkeys, State) ->
    collect_topkeys(),
    {noreply, State}.

terminate(Reason, _State) ->
    error_logger:info_msg("Stats collector termination notice: ~p~n",
                          [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

collect_stats() ->
    collect(fun collect_stats/4).

collect_topkeys() ->
    collect(fun collect_topkeys/4).

collect(F) ->
    try mc_pool:get_buckets_and_servers() of {Buckets, Servers} ->
        T = erlang:now(),
        BucketConfigs = dict:from_list(Buckets),
        lists:foreach(fun(Server = {Host, Port}) ->
                          case gen_tcp:connect(Host, Port,
                                     [binary, {packet, 0}, {active, false}],
                                     1000) of
                          {ok, Sock} ->
                              ok = auth(Sock),
                              F(T, Server, BucketConfigs, Sock),
                              ok = gen_tcp:close(Sock);
                          {error, _Err} -> error
                          end
                      end, Servers)
    catch _:Reason ->
        error_logger:info_msg("stats_collector:collect couldn't get buckets/servers: ~p~n",
                              [Reason]),
        {error, Reason}
    end.

foreach_bucket(F, Sock, Buckets) ->
    lists:foreach(fun (Bucket) ->
            {ok, RecvHeader, _RecvEntry, _NCB} = mc_client_binary:select_bucket(Sock, Bucket),
            case RecvHeader#mc_header.status of
            ?SUCCESS -> F(Bucket);
            ?KEY_ENOENT ->
                % Shouldn't get this any more now that we're controlling buckets
                error_logger:error_report("stats_collector:foreach_bucket missing bucket ~p~n",
                                          [Bucket])
            end
        end, Buckets).

collect_stats(T, {Host, Port}, BucketConfigs, Sock) ->
    MCBuckets = lists:filter(fun([C|_]) -> C =/= $_ end,
        list_buckets(Sock)), % ignore buckets starting with _ for now
    Buckets = dict:fetch_keys(BucketConfigs),
    {OldBuckets, CurrBuckets, NewBuckets} =
        listcomm(lists:sort(MCBuckets), lists:sort(Buckets)),
    lists:foreach(fun(B) ->
            error_logger:info_msg("Deleting bucket ~p from ~p:~p~n",
                                  [B, Host, Port]),
            delete_bucket(Sock, B)
        end, OldBuckets),
    lists:foreach(fun(B) ->
            Config = dict:fetch(B, BucketConfigs),
            Size = proplists:get_value(size_per_node, Config) * ?BUCKET_SIZE_UNIT,
            error_logger:info_msg("Creating bucket ~p with size ~p on ~p:~p~n",
                                  [B, Size, Host, Port]),
            create_bucket(Sock, B, Size)
        end, NewBuckets),
    foreach_bucket(fun(B) ->
            collect_stats(T, {Host, Port}, B,
                          dict:fetch(B, BucketConfigs), Sock)
        end, Sock, CurrBuckets).

collect_stats(T, {Host, Port}, Bucket, Config, Sock) ->
    WantedSize = proplists:get_value(size_per_node, Config) * ?BUCKET_SIZE_UNIT,
    Stats = dict:from_list(stats(Sock, "")),
    stats_aggregator:received_data(T, Host, Port, Bucket, Stats),
    CurrSize = list_to_integer(dict:fetch("engine_maxbytes", Stats)),
    if
        CurrSize =/= WantedSize ->
            error_logger:info_msg("Reconfiguring bucket ~p on ~p:~p from size ~p to ~p",
                                  [Bucket, Host, Port, CurrSize, WantedSize]),
            delete_bucket(Sock, Bucket),
            create_bucket(Sock, Bucket, WantedSize);
        true -> true
    end.

collect_topkeys(T, Server, BucketConfigs, Sock) when is_tuple(BucketConfigs) ->
    foreach_bucket(fun(B) -> collect_topkeys(T, Server, B, Sock) end,
                   Sock, dict:fetch_keys(BucketConfigs));

collect_topkeys(T, {Host, Port}, Bucket, Sock) ->
    Topkeys = stats(Sock, "topkeys"),
    stats_aggregator:received_topkeys(T, Host, Port, Bucket,
                                      parse_topkeys(Topkeys)).

%%#define TK_OPS(C) C(get_hits) C(get_misses) C(cmd_set) C(incr_hits) \
%%                   C(incr_misses) C(decr_hits) C(decr_misses) \
%%                   C(delete_hits) C(delete_misses) C(evictions)

parse_topkey_value(Value) ->
    Tokens = string:tokens(Value, ","),
    [GetHits, GetMisses, CmdSet, IncrHits, IncrMisses, DecrHits,
     DecrMisses, DeleteHits, DeleteMisses, Evictions, Ctime,
     _Atime] = lists:map(
        fun (S) ->
                [_K, V] = string:tokens(S, "="),
                list_to_integer(V)
        end,
        Tokens),
    Hits = GetHits + IncrHits + DecrHits + DeleteHits,
    Misses = GetMisses + IncrMisses + DecrMisses + DeleteMisses,
    Ops = Hits + Misses + CmdSet,
    Ratio = case Hits of
        0 -> 0;
        _ -> Hits / (Hits + Misses)
    end, % avoid divide by zero
    {Evictions / (Ctime + 1), Ratio, Ops / (Ctime + 1)}.

parse_topkeys(Topkeys) ->
    lists:map(
        fun ({Key, Value}) ->
                {Evictions, Ratio, Ops} = parse_topkey_value(Value),
                {Key, Evictions, Ratio, Ops}
        end,
        Topkeys).

%% Memcached higher level interface stuff

auth(Sock) ->
    Config = ns_config:get(),
    U = ns_config:search_prop(Config, bucket_admin, user),
    P = ns_config:search_prop(Config, bucket_admin, pass),
    auth(Sock, U, P).

auth(Sock, U, P) when is_list(U); is_list(P) ->
    % This command may not work unless bucket engine is running (and
    % creds are right).
    mc_client_binary:auth(Sock, {<<"PLAIN">>, {U, P}}).

list_buckets(Sock) ->
    {ok, #mc_header{status=0}, #mc_entry{data=BucketsBin}, _NCB} =
        mc_client_binary:list_buckets(Sock),
    case BucketsBin of
        undefined -> [];
        _ -> string:tokens(binary_to_list(BucketsBin), " ")
    end.

delete_bucket(Sock, Bucket) ->
    {ok, #mc_header{status=0}, _ME, _NCB} =
        mc_client_binary:delete_bucket(Sock, Bucket).

create_bucket(Sock, Bucket, Size) ->
    {ok, #mc_header{status=0}, _ME, _NCB} =
        mc_client_binary:create_bucket(Sock, Bucket,
                                       "cache_size=" ++ integer_to_list(Size)).

stats(Sock, Key) ->
    {ok, _H, _E, Stats} = mc_client_binary:cmd(?STAT, Sock,
                  fun (_MH, ME, CD) ->
                          [{binary_to_list(ME#mc_entry.key),
                            binary_to_list(ME#mc_entry.data)} | CD]
                  end,
                  [],
                  {#mc_header{}, #mc_entry{key=list_to_binary(Key)}}),
    Stats.

%% Compare two sorted lists
listcomm([], L2) -> {[], [], L2};
listcomm(L1, []) -> {L1, [], []};
listcomm(L1 = [H1|T1], L2 = [H2|T2]) ->
    if
        H1 == H2 ->
            {R1, R2, R3} = listcomm(T1, T2),
            {R1, [H1|R2], R3};
        H1 < H2 ->
            {R1, R2, R3} = listcomm(T1, L2),
            {[H1|R1], R2, R3};
        H1 > H2 ->
            {R1, R2, R3} = listcomm(L1, T2),
            {R1, R2, [H2|R3]}
    end.
