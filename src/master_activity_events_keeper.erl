%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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
-module(master_activity_events_keeper).

-behaviour(gen_server).

%% API
-export([start_link/0, get_history/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-include("ns_common.hrl").

-record(state, {ring}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_history() ->
    gen_server:call(?MODULE, get_history).

init(_) ->
    Self = self(),
    ns_pubsub:subscribe_link(master_activity_events,
                             fun (Event, _Ignored) ->
                                     gen_server:cast(Self, {note, Event})
                             end, []),
    {ok, #state{ring=ringbuffer:new(4096)}}.

handle_call(get_history, _From, State) ->
    {reply, ringbuffer:to_list(State#state.ring), State}.

handle_cast({note, Event}, #state{ring = Ring} = State) ->
    NewState = State#state{ring = ringbuffer:add(Event, Ring)},
    {noreply, NewState}.

handle_info(_Info, _State) ->
    exit(unexpected).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
