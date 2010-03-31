%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

-module(ns_doctor).

-define(STALE_TIME, 5000000). % 5 seconds in microseconds

-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
%% API
-export([heartbeat/1, get_nodes/0]).

-record(state, {nodes}).

%% gen_server handlers

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{nodes=dict:new()}}.

handle_call(get_nodes, _From, State) ->
    Now = erlang:now(),
    Nodes = dict:map(fun (_, Node) ->
                             LastHeard = proplists:get_value(last_heard, Node),
                             case timer:now_diff(Now, LastHeard) > ?STALE_TIME of
                                     true -> [ stale | Node];
                                 false -> Node
                             end
                      end, State#state.nodes),
    {reply, Nodes, State}.

handle_cast({heartbeat, Name, Status}, State) ->
    Node = [{last_heard, erlang:now()} | Status],
    Nodes = dict:store(Name, Node, State#state.nodes),
    {noreply, State#state{nodes=Nodes}}.

handle_info(Info, State) ->
    error_logger:info_msg("ns_doctor: got unexpected message ~p in state ~p.~n",
                          [Info, State]),
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API

heartbeat(Status) ->
    gen_server:cast({global, ?MODULE}, {heartbeat, erlang:node(), Status}).

get_nodes() ->
    gen_server:call({global, ?MODULE}, get_nodes).


