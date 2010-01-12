% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(tgen).

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-behaviour(gen_event).

-export([start_link/0,
         traffic_start/0,
         traffic_stop/0,
         traffic_started/0,
         traffic_more/0]).

-define(TGEN_INTERVAL, 200). % In millisecs.
-define(TGEN_POOL,     "default").
-define(TGEN_BUCKET,   "test_application").
-define(TGEN_SIZE,     5). % In MB.

%% gen_event callbacks

-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {timer}).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

% Noop process to get initialized in the supervision tree.

start_link() ->
    {ok, spawn_link(fun() ->
                       gen_event:add_handler(ns_config_events,
                                             ?MODULE, ignored)
                    end)}.

traffic_start() ->
    gen_event:call(ns_config_events, ?MODULE, traffic_start).

traffic_stop() ->
    gen_event:call(ns_config_events, ?MODULE, traffic_stop).

% Returns true/false depending if the traffic generator is started/stopped.

traffic_started() ->
    gen_event:call(ns_config_events, ?MODULE, traffic_started).

% Sends a little more traffic against the test bucket, which is
% created if not already.

traffic_more() ->
    gen_event:call(ns_config_events, ?MODULE, traffic_more).

% ---------------------------------------------------------

init(ignored) ->
    {ok, #state{}}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_event({pools, Pools}, State) ->
    % Stop generating traffic if the target bucket disappears.
    case mc_bucket:bucket_config_get(Pools, ?TGEN_POOL, ?TGEN_BUCKET) of
        false -> {ok, _, State2} = handle_call(traffic_stop, State),
                 {ok, State2};
        _ -> {ok, State}
    end;

handle_event(_, State) ->
    {ok, State}.

handle_call(traffic_start, #state{timer = undefined} = State) ->
    bucket_make(?TGEN_POOL, ?TGEN_BUCKET),
    case timer:apply_interval(?TGEN_INTERVAL, ?MODULE,
                              traffic_more, []) of
        {ok, TRef} -> {ok, ok, State#state{timer = TRef}};
        Error      -> ns_log:log(?MODULE, 0001, "timer failed: ~p", [Error]),
                      {ok, ok, State}
    end;

handle_call(traffic_start, #state{timer = TRef} = State) ->
    timer:cancel(TRef),
    handle_call(traffic_start, State#state{timer = undefined});

handle_call(traffic_stop, #state{timer = undefined} = State) ->
    {ok, ok, State};

handle_call(traffic_stop, #state{timer = TRef} = State) ->
    timer:cancel(TRef),
    {ok, ok, State#state{timer = undefined}};

handle_call(traffic_started, #state{timer = TRef} = State) ->
    {ok, TRef =/= undefined, State};

handle_call(traffic_more, #state{timer = _TRef} = State) ->
    send_traffic(?TGEN_POOL, ?TGEN_BUCKET),
    {ok, ok, State};

handle_call(_, State) ->
    {ok, unknown, State}.

handle_info(Info, State) ->
    error_logger:info_msg("mc_pool_init handle_info(~p, ~p)~n",
                          [Info, State]),
    {ok, State}.

% ---------------------------------------------------------

bucket_make(PoolName, BucketName) ->
    BucketConfig = lists:keystore(size_per_node, 1,
                                  mc_bucket:bucket_config_default(),
                                  {size_per_node, ?TGEN_SIZE}),
    case mc_bucket:bucket_config_make(PoolName, BucketName, BucketConfig) of
        true -> true; % Bucket's in config already.
        ok   -> ok    % Was just created, so ok can inform our caller.
    end.

send_traffic(PoolName, BucketName) ->
    case catch(mc_pool:get_bucket(PoolName, BucketName)) of
        {'EXIT', _} ->
            ?debugVal({send_traffic, missing_bucket, PoolName, BucketName}),
            ok;
        Bucket ->
            Addrs = mc_bucket:addrs(Bucket),
            traffic(simple, Addrs)
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

traffic(simple, Addrs) ->
    H = #mc_header{opcode = ?GETK},
    E = #mc_entry{key = <<"miss">>},
    bcast(Addrs, H, E).

