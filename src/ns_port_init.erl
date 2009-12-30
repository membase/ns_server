-module(ns_port_init).

-behaviour(gen_event).

-export([start_link/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

% Noop process to get initialized in the supervision tree.
start_link() ->
    {ok, spawn_link(fun() ->
                       gen_event:add_handler(ns_config_events, ?MODULE, ignored)
                    end)}.

init(ignored) ->
    {ok, #state{}, hibernate}.

handle_event({port_servers, List}, State) ->
    % TODO: Port server stuff
    error_logger:info_msg("Changing port servers: ~p...~n", [List]),
    {ok, State, hibernate};
handle_event(_Stuff, State) ->
    {ok, State, hibernate}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State, hibernate}.

handle_info(Info, State) ->
    error_logger:info_msg("Unhandled port init message: ~p...~n", [Info]),
    {ok, State, hibernate}.

terminate(Reason, _State) ->
    error_logger:info_msg("ns_port_init terminating: ~p...~n", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
