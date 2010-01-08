% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(mc_pool_init).

-behaviour(gen_event).

-export([start_link/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

-include_lib("eunit/include/eunit.hrl").

% Noop process to get initialized in the supervision tree.
start_link() ->
    {ok, spawn_link(fun() ->
                       gen_event:add_handler(ns_config_events, ?MODULE, ignored)
                    end)}.

init(ignored) ->
    {ok, #state{}, hibernate}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_event({pools, V}, State) ->
    error_logger:info_msg("mc_pool_init config change: ~p~n", [V]),
    {ok, State, hibernate};

handle_event(_, State) ->
    {ok, State, hibernate}.

handle_call(Request, State) ->
    error_logger:info_msg("mc_pool_init handle_call(~p, ~p)~n",
                          [Request, State]),
    {ok, ok, State, hibernate}.

handle_info(Info, State) ->
    error_logger:info_msg("mc_pool_init handle_info(~p, ~p)~n",
                          [Info, State]),
    {ok, State, hibernate}.

