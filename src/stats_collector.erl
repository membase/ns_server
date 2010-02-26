-module(stats_collector).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0]).

-record(state, {tref}).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, Tref} = timer:send_interval(1000, collect),
    {ok, #state{tref=Tref}}.

handle_call(Request, From, State) ->
    error_logger:info_msg("stats_collector:handle_call(~p, ~p, ~p)~n",
                          [Request, From, State]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    error_logger:info_msg("stats_collector:handle_cast(~p, ~p)~n",
                          [Msg, State]),
    {noreply, State}.

handle_info(collect, State) ->
    collect(),
    {noreply, State}.

terminate(Reason, _State) ->
    error_logger:info_msg("Stats collector termination notice: ~p~n",
                          [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

collect() ->
    try mc_pool:get_buckets_and_servers() of {Buckets, Servers} ->
        T = erlang:now(),
        BucketConfigs = dict:from_list(Buckets),
        lists:foreach(fun(Server) -> collect(T, Server, BucketConfigs) end,
                      Servers),
        ok
    catch _:Reason ->
        error_logger:info_msg("stats_collector:collect couldn't get buckets/servers: ~p~n",
                              [Reason]),
        {error, Reason}
    end.

collect(T, {Host, Port}, BucketConfigs) ->
    case gen_tcp:connect(Host, Port,
                         [binary, {packet, 0}, {active, false}],
                         1000) of
        {ok, Sock} ->
            ok = auth(Sock),
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
                    Size = proplists:get_value(size_per_node, Config) * 1048576,
                    error_logger:info_msg("Creating bucket ~p with size ~p on ~p:~p~n",
                                          [B, Size, Host, Port]),
                    create_bucket(Sock, B, Size)
                end, NewBuckets),
            lists:foreach(fun(B) ->
                    collect(T, {Host, Port}, B,
                            dict:fetch(B, BucketConfigs), Sock)
                end,
                CurrBuckets),
            ok = gen_tcp:close(Sock);
        {error, _Err} -> error
    end.

collect(T, {Host, Port}, Bucket, Config, Sock) ->
    WantedSize = proplists:get_value(size_per_node, Config) * 1048576,
    {ok, RecvHeader, _RecvEntry, _NCB} = mc_client_binary:select_bucket(Sock, Bucket),
    case RecvHeader#mc_header.status of
        ?SUCCESS ->
            Stats = stats(Sock, ""),
            stats_aggregator:received_data(T, Host, Port, Bucket, Stats),
            Topkeys = stats(Sock, "topkeys"),
            stats_aggregator:received_topkeys(T, Host, Port, Bucket,
                                              parse_topkeys(Topkeys)),
            CurrSize = list_to_integer(dict:fetch("engine_maxbytes", Stats)),
            if
                CurrSize =/= WantedSize ->
                    error_logger:info_msg("Reconfiguring bucket ~p on ~p:~p from size ~p to ~p",
                                          [Bucket, Host, Port, CurrSize, WantedSize]),
                    delete_bucket(Sock, Bucket),
                    create_bucket(Sock, Bucket, WantedSize);
                true -> true
            end,
            ok;
        ?KEY_ENOENT ->
            % Shouldn't get this any more now that we're controlling buckets
            error_logger:error_report("stats_collector:collect missing bucket ~p~n",
                                      [Bucket]),
            {missing_bucket, Bucket}
    end.

parse_topkey_value(Value) ->
    Tokens = string:tokens(Value, ","),
    Pairs = lists:map(
        fun (S) ->
                [K, V] = string:tokens(S, "="),
                {N, []} = string:to_integer(V),
                {K, N}
        end,
        Tokens),
    dict:from_list(Pairs).

parse_topkeys(Topkeys) ->
    dict:map(
        fun (_Key, Value) ->
                parse_topkey_value(Value)
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
                          dict:store(binary_to_list(ME#mc_entry.key),
                                     binary_to_list(ME#mc_entry.data),
                                     CD)
                  end,
                  dict:new(),
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
