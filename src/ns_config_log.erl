-module(ns_config_log).

-behaviour(gen_event).

-export([start_link/0, setup_handler/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

start_link() ->
    {ok, spawn_link(?MODULE, setup_handler, [])}.

setup_handler() ->
    gen_event:add_handler(ns_config_events, ns_config_log, ignored).

init(ignored) ->
    {ok, #state{}, hibernate}.

handle_event({K, V}, State) ->
    error_logger:info_msg("Received a config change: ~p -> ~p~n", [K, V]),
    {ok, State, hibernate}.

handle_call(Request, State) ->
    error_logger:info_msg("handle_call(~p, ~p)~n", [Request, State]),
    Reply = ok,
    {ok, Reply, State, hibernate}.

handle_info(Info, State) ->
    error_logger:info_msg("handle_info(~p, ~p)~n", [Info, State]),
    {ok, State, hibernate}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
