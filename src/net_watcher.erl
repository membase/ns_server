%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

-module(net_watcher).

-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-export([current_address/0]).

-record(state, {current_address, timer}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, Timer} = timer:send_interval(5000, check_addr),
    {ok, #state{current_address=addr_util:get_my_address(),
                timer=Timer}}.

handle_call(current_address, _From, State) ->
    {reply, State#state.current_address, State}.

handle_cast(Msg, _State) ->
    exit({unhandled, Msg}).

handle_info(check_addr, State) ->
    PrevAddr = State#state.current_address,
    case addr_util:get_my_address() of
        PrevAddr ->
            {noreply, State};
        NewAddress ->
            ns_log:log(?MODULE, 0001, "IP address on node ~p changed from ~p to ~p",
                       [node(), PrevAddr, NewAddress]),
            gen_event:notify(ns_network_events, {new_addr, NewAddress}),
            {noreply, State#state{current_address=NewAddress}}
    end.

terminate(_Reason, State) ->
    timer:cancel(State#state.timer),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

current_address() ->
    gen_server:call(?MODULE, current_address).
