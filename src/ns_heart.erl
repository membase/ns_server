%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

-module(ns_heart).

-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% gen_server handlers

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    timer:send_interval(1000, beat),
    {ok, empty_state}.

handle_call(_Request, _From, State) -> {reply, empty_reply, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(beat, State) ->
    ns_doctor:heartbeat(current_status()),
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API

%% Internal fuctions
current_status() ->
    NodeInfo = element(2, ns_info:basic_info()),
    MemcachedRunning = try ns_memcached:connected() of
                           Result -> Result
                       catch
                           _:_ -> false
                       end,
    lists:append([
                                                % If memcached is running, our connection to it will be up
        [proplists:property(memcached_running, MemcachedRunning)],
        NodeInfo]).
