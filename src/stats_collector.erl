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
    error_logger:info_message("stats_collector:handle_call(~p, ~p, ~p)~n",
                              [Request, From, State]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    error_logger:info_message("stats_collector:handle_cast(~p, ~p)~n",
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
    {Buckets, Servers} = mc_pool:get_buckets_and_servers(),
    T = erlang:now(),
    lists:foreach(fun(Server) -> collect(T, Server, Buckets) end, Servers).

collect(T, {Host, Port}, Buckets) ->
    case gen_tcp:connect(Host, Port,
                         [binary, {packet, 0}, {active, false}],
                         1000) of
        {ok, Sock} ->
            ok = auth(Sock),
            lists:foreach(fun(B) ->
                                 collect(T, {Host, Port}, B, Sock)
                          end,
                          Buckets),
            ok = gen_tcp:close(Sock);
        {error, Err} ->
            error_logger:info_msg("Error in collection:  ~p ~p ~p~n",
                                  [Err, Host, Port])
    end.

auth(Sock) ->
    Config = ns_config:get(),
    U = ns_config:search_prop(Config, bucket_admin, user),
    P = ns_config:search_prop(Config, bucket_admin, pass),
    auth(Sock, U, P).

auth(Sock, U, P) when is_list(U); is_list(P) ->
    % This command may not work unless bucket engine is running (and
    % creds are right).
    mc_client_binary:auth(Sock, {<<"PLAIN">>, {U, P}}).

collect(T, {Host, Port}, Bucket, Sock) ->
    {ok, _RecvHeader, _RecvEntry, _NCB} = mc_client_binary:select_bucket(Sock, Bucket),
    {ok, _H, _E, Stats} = mc_client_binary:cmd(?STAT, Sock,
                              fun (_MH, ME, CD) ->
                                      dict:store(binary_to_list(ME#mc_entry.key),
                                                 binary_to_list(ME#mc_entry.data),
                                                 CD)
                              end,
                              dict:new(),
                              {#mc_header{}, #mc_entry{}}),
    stats_aggregator:received_data(T, Host, Port, Bucket, Stats),
    {ok, _H, _E, Topkeys} = mc_client_binary:cmd(?STAT, Sock,
                              fun (_MH, ME, CD) ->
                                      dict:store(binary_to_list(ME#mc_entry.key),
                                                 binary_to_list(ME#mc_entry.data),
                                                 CD)
                              end,
                              dict:new(),
                              {#mc_header{}, #mc_entry{key = <<"topkeys">>}}),
    stats_aggregator:received_topkeys(T, Host, Port, Bucket,
                                      parse_topkeys(Topkeys)).

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
