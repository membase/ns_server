-module(node_disco_conf_events).

-behaviour(gen_event).

%% gen_event callbacks
-export([start_link/0, init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {disco}).

% start_link is required by gen_event, but *never* makes sense because
% the event handlers are not processes.
start_link() ->
    error.

init(DiscoPid) ->
    {ok, #state{disco=DiscoPid}, hibernate}.

handle_event(Event, State) ->
    error_logger:info_msg("Config change:  ~p~n", [Event]),
    {ok, State, hibernate}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State, hibernate}.

handle_info(_Info, State) ->
    {ok, State, hibernate}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

