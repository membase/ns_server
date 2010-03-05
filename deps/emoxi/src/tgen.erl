% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(tgen).

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-behaviour(gen_server).

-export([start_link/0,
         is_traffic_bucket/2,
         traffic_start/0,
         traffic_stop/0,
         traffic_started/0,
         send_response/5]).

-export([system_joinable/0]).

% TODO: more random interval might be needed, per matt.

-define(TGEN_INTERVAL, 200). % In millisecs.
-define(TGEN_POOL,     "default").
-define(TGEN_BUCKET,   "test_application").
-define(TGEN_SIZE,     1). % In MB

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {timer}).

-include_lib("eunit/include/eunit.hrl").

start_link() ->
    gen_server:start_link({local, tgen}, ?MODULE, ignored, []).

is_traffic_bucket(PoolName, BucketName) ->
    PoolName =:= ?TGEN_POOL andalso
    BucketName =:= ?TGEN_BUCKET.

traffic_start() ->
    gen_server:cast(?MODULE, traffic_start).

traffic_stop() ->
    gen_server:cast(?MODULE, traffic_stop).

% Returns true/false depending if the traffic generator is started/stopped.

traffic_started() ->
    gen_server:call(?MODULE, traffic_started).

% -------------------------------------------------------

% Returns true if the system is considered joinable.  Eg, not
% part of another cluster and no buckets except for the default
% and traffic generator buckets.

system_joinable() ->
    Pools = mc_pool:pools_config_get(),
    PoolNames = proplists:get_keys(Pools),
    case lists:subtract(PoolNames, ["default", ?TGEN_POOL]) of
        [] ->
            Buckets =
                proplists:get_value(
                  buckets,
                  mc_pool:pool_config_get(Pools, ?TGEN_POOL)),
            BucketNames = proplists:get_keys(Buckets),
            case lists:subtract(BucketNames, ["default", ?TGEN_BUCKET]) of
                [] -> case ns_node_disco:nodes_wanted() of
                          [_OneNode] -> true;
                          _          -> false
                      end;
                _  -> false
            end;
        _ -> false
    end.

% ---------------------------------------------------------

init(ignored) ->
    {ok, #state{}}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_cast(traffic_start, #state{timer = undefined} = State) ->
    bucket_make(?TGEN_POOL, ?TGEN_BUCKET),
    timer:sleep(2000), % Wait a couple seconds to avoid spammy auth errors
    case timer:send_interval(?TGEN_INTERVAL, traffic_more) of
        {ok, TRef} -> {noreply, State#state{timer = TRef}};
        Error      -> ns_log:log(?MODULE, 0001, "timer failed: ~p", [Error]),
                      {noreply, State}
    end;

handle_cast(traffic_start, #state{timer = TRef} = State) ->
    timer:cancel(TRef),
    handle_cast(traffic_start, State#state{timer = undefined});

handle_cast(traffic_stop, #state{timer = undefined} = State) ->
    {noreply, State};

handle_cast(traffic_stop, #state{timer = TRef} = State) ->
    timer:cancel(TRef),
    {noreply, State#state{timer = undefined}}.

handle_call(traffic_started, _From, #state{timer = TRef} = State) ->
    {reply, TRef =/= undefined, State}.

handle_info(traffic_more, #state{timer = _TRef} = State) ->
    send_traffic(?TGEN_POOL, ?TGEN_BUCKET),
    {noreply, State};

handle_info(Info, State) ->
    error_logger:info_msg("tgen handle_info(~p, ~p)~n",
                          [Info, State]),
    {noreply, State}.

% ---------------------------------------------------------

bucket_make(PoolName, BucketName) ->
    BucketConfig = lists:keystore(size_per_node, 1,
                                  mc_bucket:bucket_config_default(),
                                  {size_per_node, ?TGEN_SIZE}),
    BucketConfig2 = lists:keystore(auth_plain, 1,
                                   BucketConfig,
                                   {auth_plain, {BucketName, BucketName}}),
    case mc_bucket:bucket_config_make(PoolName, BucketName, BucketConfig2) of
        true -> true; % Bucket's in config already.
        ok   -> ok    % Was just created, so ok can inform our caller.
    end.

send_traffic(PoolName, BucketName) ->
    case catch(mc_pool:get_bucket(PoolName, BucketName)) of
        {'EXIT', _} ->
            traffic_stop();
        {ok, Bucket} ->
            Addrs = mc_bucket:addrs(Bucket),
            traffic(Addrs)
    end,
    true.

bcast(Addrs, #mc_header{opcode = Opcode} = H, E) ->
    HE = {H, E},
    {NumFwd, Monitors} =
        lists:foldl(fun (Addr, Acc) ->
                            mc_downstream:accum(
                              mc_downstream:send(Addr, undefined,
                                                 Opcode, HE,
                                                 undefined, ?MODULE),
                              Acc)
                    end,
                    {0, []}, Addrs),
    mc_downstream:await_ok(NumFwd),
    mc_downstream:demonitor(Monitors),
    ok.

send_response(_Kind, _Out, _Cmd, _Head, _Body) ->
    % No-op because we're not really a proxy.
    true.

% ---------------------------------------------------------

traffic(Addrs) ->
    [Story | _] = misc:shuffle([miss1,
                                get1, set1,
                                incr1, decr1,
                                flush1, delete1]),
    traffic(Story, Addrs).

traffic(miss1, Addrs) ->
    H = #mc_header{opcode = ?GETK},
    E = #mc_entry{key = <<"key0">>},
    bcast(Addrs, H, E);

traffic(get1, Addrs) ->
    H = #mc_header{opcode = ?GET},
    E = #mc_entry{key = <<"key1">>},
    bcast(Addrs, H, E);

traffic(set1, Addrs) ->
    H = #mc_header{opcode = ?SET},
    E = #mc_entry{key = <<"key1">>, data = <<"val1">>},
    bcast(Addrs, H, E);

traffic(incr1, Addrs) ->
    H = #mc_header{opcode = ?INCREMENT},
    E = #mc_entry{key = <<"counter1">>, data = 1},
    bcast(Addrs, H, E);

traffic(decr1, Addrs) ->
    H = #mc_header{opcode = ?DECREMENT},
    E = #mc_entry{key = <<"counter1">>, data = 1},
    bcast(Addrs, H, E);

traffic(flush1, Addrs) ->
    H = #mc_header{opcode = ?FLUSH},
    E = #mc_entry{},
    bcast(Addrs, H, E);

traffic(delete1, Addrs) ->
    H = #mc_header{opcode = ?DELETE},
    E = #mc_entry{key = <<"miss">>},
    bcast(Addrs, H, E).

