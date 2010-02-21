-module(ns_address_change_handler).

-behaviour(gen_event).

-export([start_link/0, add_handler/0]).

-export([init/1, handle_event/2, handle_call/2, 
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

start_link() ->
    exit(unhandled).

add_handler() ->
    exit(unhandled).

init([]) ->
    {ok, #state{}}.

handle_event({new_addr, _NewAddress}, State) ->
    ok = network_changed(os:type()),
    {ok, State};
handle_event(Event, State) ->
    error_logger:info_msg("~p ignoring ~p~n", [?MODULE, Event]),
    {ok, State}.

handle_call(_Request, _State) ->
    exit(unhandled).

handle_info(_Info, _State) ->
    exit(unhandled).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Responses here.

network_changed({unix,_}) ->
    ok;
network_changed({win32,_}) ->
    case application:get_env(ns_server, restart_script) of
        {ok, Val} -> os:cmd(Val), ok;
        undefined -> error_logger:info_msg("restart_script not defined.~n")
    end;
network_changed(Other) ->
    error_logger:info_msg("Unknown OS type: ~p~n", [Other]).
