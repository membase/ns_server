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

%% This module implements a concurrency throttle, so that if many processes
%% have work to do but we want to limit the number concurrently executing,
%% each process calls send_back_when_can_go/2, and it will receive a message
%% when the process is allowed to execute. The process should then call
%% is_done/1 to allow another process to go. The process is monitored and if
%% if fails to call is_done/1 but dies, this module will notice and clean it up.
%% If the process fails to call is_done/1 but runs forever, it's concurrency
%% turn will last forever preventing other processes from their turns.
%
%% Each process is granted a turn in the order it calls send_back_when_can_go/2

-module(concurrency_throttle).
-behaviour(gen_server).

-export([send_back_when_can_go/2, send_back_when_can_go/3, is_done/1]).

-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("xdc_replicator.hrl").

start_link(MaxConcurrency) ->
    {ok, Pid} = gen_server:start_link(?MODULE, MaxConcurrency, []),
    ?xdcr_debug("concurrency throttle started: ~p", [Pid]),
    {ok, Pid}.

send_back_when_can_go(Server, Signal) ->
    send_back_when_can_go(Server, "NULL", Signal).

send_back_when_can_go(Server, LoadKey, Signal) ->
    gen_server:call(Server, {send_signal, {LoadKey, Signal}}, infinity).

is_done(Server) ->
    gen_server:call(Server, done, infinity).

init(Count) ->
    ?xdcr_debug("init concurrent throttle process, pid: ~p, "
                "# of available token: ~p", [self(), Count]),
    WaitingPool = dict:new(),
    ActivePool = dict:new(),
    TargetLoad = dict:new(),
    MonitorDict = dict:new(),
    {ok, #concurrency_throttle_state{count = Count,
                                     waiting_pool = WaitingPool,
                                     active_pool = ActivePool,
                                     target_load = TargetLoad,
                                     monitor_dict = MonitorDict}}.

handle_call({send_signal, {TargetNode, Signal}}, {Pid, _Tag},
            #concurrency_throttle_state{count = 0} = State) ->

    #concurrency_throttle_state{waiting_pool = WaitingPool,
                                target_load = TargetLoad} = State,

    NewWaitingPool = dict:store(Pid, {Signal, TargetNode}, WaitingPool),
    NewTargetLoad = case dict:is_key(TargetNode, TargetLoad) of
                        false ->
                            dict:store(TargetNode, 0, TargetLoad);
                        _ ->
                            TargetLoad
                    end,

    NewState = State#concurrency_throttle_state{
                 target_load = NewTargetLoad,
                 waiting_pool = NewWaitingPool},

    ?xdcr_debug("no token available, put (pid:~p, signal: ~p, targetnode: ~p) "
                "waiting pool", [Pid, Signal, TargetNode]),

    {reply, ok, NewState};

handle_call({send_signal, {TargetNode, Signal}}, {Pid, _Tag}, State) ->

    MonRef = erlang:monitor(process, Pid),

    #concurrency_throttle_state{count = Count,
                                waiting_pool = _WaitingPool,
                                active_pool = ActivePool,
                                target_load = TargetLoad,
                                monitor_dict = MonDict} = State,

    NewMonDict = dict:store(Pid, MonRef, MonDict),
    NewActivePool = dict:store(Pid, TargetNode, ActivePool),
    %% update target_load
    NewTargetLoad = case dict:is_key(TargetNode, TargetLoad) of
                        false ->
                            dict:store(TargetNode, 1, TargetLoad);
                        _ ->
                            NewLoad = dict:fetch(TargetNode, TargetLoad) + 1,
                            dict:store(TargetNode, NewLoad, TargetLoad)
                    end,
    NewCount = Count - 1,
    %% signal vb replicator
    Pid ! Signal,

    ?xdcr_debug("grant one token to rep (pid: ~p, targetnode: ~p), available tokens: ~p",
                [Pid, TargetNode, NewCount]),

    {reply, ok, State#concurrency_throttle_state{
                  count = NewCount,
                  monitor_dict = NewMonDict,
                  target_load = NewTargetLoad,
                  active_pool = NewActivePool}};

handle_call(done, {Pid, _Tag},
            #concurrency_throttle_state{count = Count, monitor_dict = MonDict,
                                        active_pool = ActivePool,
                                        target_load = TargetLoad} = State) ->

    true = erlang:demonitor(dict:fetch(Pid, MonDict), [flush]),
    %% update monitoring and active reps tables
    NewMonDict = dict:erase(Pid, MonDict),
    NewActivePool = dict:erase(Pid, ActivePool),
    %% update target_load
    TargetNode = dict:fetch(Pid, ActivePool),
    NewLoad = dict:fetch(TargetNode, TargetLoad) - 1,
    NewTargetLoad = case NewLoad > 0 of
                        true ->
                            dict:store(TargetNode, NewLoad, TargetLoad);
                        _ ->
                            dict:erase(TargetNode, TargetLoad)
                    end,

    NewCount = Count + 1,

    ?xdcr_debug("rep ~p to node ~p is done, available tokens: ~p",
                [Pid, TargetNode, NewCount]),

    State2 = signal_waiting(State#concurrency_throttle_state{
                              count = NewCount,
                              monitor_dict = NewMonDict,
                              target_load = NewTargetLoad,
                              active_pool = NewActivePool}),
    {reply, ok, State2}.

handle_cast(Msg, State) ->
    {stop, {error, {unexpected_cast, Msg}}, State}.

handle_info({'DOWN', _MonRef, _Type, Pid, _Info},
            #concurrency_throttle_state{
              count = Count, monitor_dict = MonDict} = State) ->
    %% a process we already signalled died before we got a done call.
    %% Remove from dict and increment count.
    MonDict2 = dict:erase(Pid, MonDict),
    State2 = signal_waiting(State#concurrency_throttle_state{
                              count = Count + 1,
                              monitor_dict = MonDict2}),
    {noreply, State2}.


signal_waiting(#concurrency_throttle_state{count = Count,
                                           waiting_pool = WaitingPool,
                                           active_pool = ActivePool,
                                           target_load = TargetLoad,
                                           monitor_dict = MonDict} = State) ->

    case dict:size(WaitingPool) of
        0 ->
            ?xdcr_debug("nothing to schedule, # of active reps: ~p, # of acrtive target nodes: ~p",
                        [dict:size(ActivePool), dict:size(TargetLoad)]),
            State;
        _ ->
            {WaitingPid, Signal, TargetNode} = choose_pid_to_schedule(WaitingPool,
                                                                      TargetLoad),
            %% signal to next it can go
            %% if WaitingPid died, we'll get a 'DOWN' message
            MonRef = erlang:monitor(process, WaitingPid),
            NewWaitingPool = dict:erase(WaitingPid, WaitingPool),
            NewActivePool = dict:store(WaitingPid, TargetNode, ActivePool),
            NewTargetLoad = case dict:is_key(TargetNode, TargetLoad) of
                                false ->
                                    dict:store(TargetNode, 1, TargetLoad);
                                _ ->
                                    NewLoad = dict:fetch(TargetNode, TargetLoad) + 1,
                                    dict:store(TargetNode, NewLoad, TargetLoad)
                            end,

            ?xdcr_debug("schedule a waiting rep (pid: ~p, target node: ~p) to be active",
                        [WaitingPid, TargetNode]),

            WaitingPid ! Signal,
            State#concurrency_throttle_state{
              count = Count - 1,
              monitor_dict = dict:store(WaitingPid, MonRef, MonDict),
              active_pool = NewActivePool,
              waiting_pool = NewWaitingPool,
              target_load = NewTargetLoad}
    end.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% based on laod table and table of waiting reps, choose one
%% replication to schedule such that the target node has the
%% minimum active replications
choose_pid_to_schedule(WaitingPool, TargetLoad) ->
    {MinimumPid, _Load} = dict:fold(
                           fun(Pid, {_, CurrNode}, {MinPid, MinLoad}) ->
                                   case dict:is_key(CurrNode, TargetLoad) of
                                       false ->
                                           {Pid, 0};
                                       _ ->
                                           CurrLoad = dict:fetch(CurrNode, TargetLoad),
                                           case CurrLoad < MinLoad of
                                               true ->
                                                   {Pid, CurrLoad};
                                               _  ->
                                                   {MinPid, MinLoad}
                                           end
                                   end
                           end,
                           %% the max # of active resp per node is the number of vbuckets
                           {0, 9999},
                           WaitingPool),

    {Signal, TargetNode} = dict:fetch(MinimumPid, WaitingPool),
    {MinimumPid, Signal, TargetNode}.
