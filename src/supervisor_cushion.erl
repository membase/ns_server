%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% This module exists to slow down supervisors to prevent fast spins
%% on crashes.

-module(supervisor_cushion).

-behaviour(gen_server).
-behavior(ns_log_categorizing).

-define(FAST_CRASH, 1).

%% API
-export([start_link/5]).
-export([ns_log_cat/1, ns_log_code_string/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {name, delay, started}).

start_link(Name, Delay, M, F, A) ->
    gen_server:start_link(?MODULE, [Name, Delay, M, F, A], []).

init([Name, Delay, M, F, A]) ->
    process_flag(trap_exit, true),
    error_logger:info_msg("starting ~p with delay of ~p~n", [M, Delay]),
    Val = apply(M, F, A),
    error_logger:info_msg("~p:~p(~p) returned ~p~n", [M, F, A, Val]),
    {ok, #state{name=Name, delay=Delay, started=now()}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, Reason}, State) ->
    error_logger:info_msg("Cushion managed supervisor for ~p failed:  ~p~n",
                          [State#state.name, Reason]),
    maybe_sleep(State),
    exit({error, cushioned_supervisor, Reason});
handle_info(Info, State) ->
    error_logger:info_msg("Cushion got unexpected info supervising ~p: ~p~n",
                          [State#state.name, Info]),
    maybe_sleep(State),
    exit({error, cushioned_supervisor, Info}).

maybe_sleep(State) ->
    %% How long (in microseconds) has this service been running?
    Lifetime = timer:now_diff(now(), State#state.started),
    %% now_diff returns microseconds, so let's do the same.
    MinDelay = State#state.delay * 1000,
    %% If the restart was too soon, slow down a bit.
    case Lifetime < MinDelay of
        true ->
            ns_log:log(?MODULE, ?FAST_CRASH,
                       "Service ~p crashed in ~.2fs~n",
                       [State#state.name, Lifetime / 1000000]),
            timer:sleep(State#state.delay);
        _ -> ok %% default case, no delay
    end.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ns_log_cat(?FAST_CRASH) -> warn.

ns_log_code_string(?FAST_CRASH) -> "port crashed too soon after restart".
