% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(tgen).

-behaviour(gen_event).

-export([start_link/0,
         traffic_start/0,
         traffic_stop/0,
         traffic_more/0]).

-define(TGEN_INTERVAL, 200). % In millisecs.
-define(TGEN_POOL,   "default").
-define(TGEN_BUCKET, "test_application").
-define(TGEN_PASSWD, "test_application").

%% gen_event callbacks

-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {timer}).

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

% Sends a little more traffic against the test bucket, which is
% created if not already.

traffic_more() ->
    gen_event:call(ns_config_events, ?MODULE, traffic_more).

% ---------------------------------------------------------

send_traffic(_PoolName, _BucketName) ->
    true.

bucket_make(PoolName, BucketName) ->
    case mc_bucket:bucket_config_make(PoolName, BucketName) of
        true -> true; % Bucket's in config already.
        _    -> delay % Was just created, so tell our caller.
    end.

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
    case timer:apply_interval(?TGEN_INTERVAL, ?MODULE,
                              traffic_more, []) of
        {ok, TRef} -> {ok, ok, State#state{timer = TRef}};
        Error      -> ns_log:log(?MODULE, 0001, "timer failed: ~p", [Error]),
                      {ok, ok, State}
    end;
handle_call(traffic_start, #state{timer = _TRef} = State) ->
    {ok, ok, State};

handle_call(traffic_stop, #state{timer = undefined} = State) ->
    {ok, ok, State};
handle_call(traffic_stop, #state{timer = TRef} = State) ->
    timer:cancel(TRef),
    {ok, ok, State#state{timer = undefined}};

handle_call(traffic_more, #state{timer = TRef} = State) ->
    case TRef of
        undefined -> {ok, ok, State};
        _ -> (bucket_make(?TGEN_POOL, ?TGEN_BUCKET) andalso
              send_traffic(?TGEN_POOL, ?TGEN_BUCKET)),
             {ok, ok, State}
    end.

handle_info(Info, State) ->
    error_logger:info_msg("mc_pool_init handle_info(~p, ~p)~n",
                          [Info, State]),
    {ok, State}.

