
-module(ns_doctor).

-define(STALE_TIME, 5000000). % 5 seconds in microseconds

-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
%% API
-export([heartbeat/1, get_nodes/0]).

-record(state, {nodes}).
-record(node, {status, last_heard}).

%% gen_server handlers

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, _Tref} = timer:send_interval(5000, garbage_collect),
    {ok, #state{nodes=dict:new()}}.

handle_call(get_nodes, _From, State) ->
    Statuses = dict:map(fun (_Name, #node{status=Status}) -> Status end,
                        State#state.nodes),
    {reply, Statuses, State}.

handle_cast({heartbeat, Name, Status}, State) ->
    Node = #node{status=Status, last_heard=erlang:now()},
    Nodes = dict:store(Name, Node, State#state.nodes),
    {noreply, State#state{nodes=Nodes}}.

handle_info(garbage_collect, State) ->
    Now = erlang:now(),
    Nodes = dict:filter(fun (_Name, #node{last_heard=LastHeard}) ->
                            timer:now_diff(Now, LastHeard) < ?STALE_TIME
                        end, State#state.nodes),
    {noreply, State#state{nodes=Nodes}}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API

heartbeat(Status) ->
    gen_server:cast({global, ?MODULE}, {heartbeat, erlang:node(), Status}).

get_nodes() ->
    gen_server:call({global, ?MODULE}, get_nodes).


