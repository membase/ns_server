%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Centralized time service

-module(ns_tick).

-behaviour(gen_server).

-define(EVENT_MANAGER, ns_tick_event).
-define(INTERVAL, 1000).
-define(SERVER, ?MODULE).

-export([start_link/0, time/0]).

-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1,
         terminate/2]).

-export([tick/1]). % used internally via rpc

-record(state, {time}).

%%
%% API
%%

start_link() ->
    misc:start_singleton_gen_server(?MODULE, [], []).


time() ->
    gen_server:call({global, ?MODULE}, time).


%%
%% gen_server callbacks
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init([]) ->
    timer:send_interval(?INTERVAL, tick),
    {ok, #state{}}.


handle_call(time, _From, #state{time=Time} = State) ->
    {reply, Time, State}.


handle_cast(unhandled, unhandled) ->
    unhandled.


%% Called once per second on the node where the gen_server runs
handle_info(tick, State) ->
    Now = misc:time_to_epoch_ms_int(now()),
    rpc:eval_everywhere(?MODULE, tick, [Now]),
    {noreply, State#state{time=Now}}.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

%% Called on all nodes via RPC to send an event to the local event manager
tick(Now) ->
    gen_event:notify(?EVENT_MANAGER, {tick, Now}).
