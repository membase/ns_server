%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.
%%

% This module implements a concurrency throttle, so that if many processes
% have work to do but we want to limit the number concurrently executing,
% each process calls send_back_when_can_go/2, and it will receive a message
% when the process is allowed to execute. The process should then call
% is_done/1 to allow another process to go. The process is monitored and if
% if fails to call is_done/1 but dies, this module will notice and clean it up.
% If the process fails to call is_done/1 but runs forever, it's concurrency
% turn will last forever preventing other processes from their turns.

% Each process is granted a turn in the order it calls send_back_when_can_go/2

-module(concurrency_throttle).
-behaviour(gen_server).

-export([send_back_when_can_go/2, is_done/1]).

-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

start_link(MaxConcurrency) ->
    gen_server:start_link(?MODULE, MaxConcurrency, []).

-record(state, {
    count = 0,
    waiting_queue = queue:new(),
    monitor_dict = dict:new()
    }).

send_back_when_can_go(Server, Signal) ->
    gen_server:call(Server, {send_signal, Signal}, infinity).


is_done(Server) ->
    gen_server:call(Server, done, infinity).


init(Count) ->
    {ok, #state{count = Count}}.


handle_call({send_signal, Signal}, {Pid, _Tag},
            #state{count = 0, waiting_queue = Waiting} = State) ->
    {reply, ok, State#state{waiting_queue = queue:in({Pid, Signal}, Waiting)}};

handle_call({send_signal, Signal}, {Pid, _Tag},
            #state{count = Count, monitor_dict = MonDict} = State) ->
    MonRef = erlang:monitor(process, Pid),
    Pid ! Signal,
    {reply, ok, State#state{count = Count - 1,
                            monitor_dict = dict:store(Pid, MonRef, MonDict)}};

handle_call(done, {Pid, _Tag},
           #state{count = Count,
                  monitor_dict = MonDict} = State) ->
    true = erlang:demonitor(dict:fetch(Pid, MonDict), [flush]),
    MonDict2 = dict:erase(Pid, MonDict),
    State2 = signal_waiting(State#state{count = Count + 1,
                                        monitor_dict = MonDict2}),
    {reply, ok, State2}.

handle_cast(Msg, State) ->
    {stop, {error, {unexpected_cast, Msg}}, State}.

handle_info({'DOWN', _MonRef, _Type, Pid, _Info},
            #state{count = Count, monitor_dict = MonDict} = State) ->
    % a process we already signalled died before we got a done call.
    % Remove from dict and increment count.
    MonDict2 = dict:erase(Pid, MonDict),
    State2 = signal_waiting(State#state{count = Count + 1,
                                        monitor_dict = MonDict2}),
    {noreply, State2}.


signal_waiting(#state{count = Count,
                      waiting_queue = Waiting,
                      monitor_dict = MonDict} = State) ->
    case queue:out(Waiting) of
        {{value, {WaitingPid, Signal}}, Waiting2} ->
            % signal to next it can go
            % if WaitingPid died, we'll get a 'DOWN' message
            MonRef = erlang:monitor(process, WaitingPid),
            WaitingPid ! Signal,
            State#state{count = Count - 1,
                        monitor_dict = dict:store(WaitingPid, MonRef, MonDict),
                        waiting_queue = Waiting2};
        {empty, _W} ->
            % nothing waiting
            State
    end.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
