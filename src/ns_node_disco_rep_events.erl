-module(ns_node_disco_rep_events).

-behaviour(gen_event).

%% API
-export([start_link/0, add_handler/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

start_link() ->
    {error, invalid_usage}.

add_handler() ->
    gen_event:add_handler(ns_node_disco_events, ?MODULE, []).

init([]) ->
    {ok, #state{}}.

handle_event({ns_node_disco_events, _O, _N}, State) ->
    error_logger:info_msg("Detecteda new node.  Moving config around.~n"),
    ns_config_rep:pull(),
    ns_config_rep:push(),
    {ok, State}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
