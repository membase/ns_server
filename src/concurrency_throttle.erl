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
%%
%% Each process is granted a turn in the order it calls send_back_when_can_go/2

-module(concurrency_throttle).
-behaviour(gen_server).

-include("ns_common.hrl").

-export([send_back_when_can_go/2, send_back_when_can_go/3, is_done/1]).
-export([change_tokens/2]).
-export([start_link/2, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

%% concurrency throttle state used by module concurrency_throttle
-record(concurrency_throttle_state, {
          %% parent process creating the throttle server
          parent,
          %% type of concurrency throttle
          type,
          %% total number of tokens
          total_tokens,
          %% number of available tokens
          avail_tokens,
          %% table of waiting requests to be scheduled
          %% (key = Pid, value = {Signal, LoadKey})
          waiting_pool,
          %% table of active, scheduled requests
          %% (key = Pid, value = LoadKey)
          active_pool,
          %% table of load at target node
          %% (key = TargetNode, value = number of active requests on that node)
          target_load,
          %% table of monitoring refs
          %% (key = Pid, value = monitoring reference)
          monitor_dict
         }).

start_link({MaxConcurrency, Type}, Parent) ->
    gen_server:start_link(?MODULE, {MaxConcurrency, Type, Parent}, []).

send_back_when_can_go(Server, Signal) ->
    send_back_when_can_go(Server, "NULL", Signal).

send_back_when_can_go(Server, LoadKey, Signal) ->
    gen_server:call(Server, {send_signal, {LoadKey, Signal}}, infinity).

is_done(Server) ->
    gen_server:call(Server, done, infinity).

change_tokens(Server, NewTokens) ->
    gen_server:call(Server, {change_tokens, NewTokens}, infinity).

init({Count, Type, Parent}) ->
    WaitingPool = dict:new(),
    ActivePool = dict:new(),
    TargetLoad = dict:new(),
    MonitorDict = dict:new(),
    {ok, #concurrency_throttle_state{parent = Parent,
                                     type = Type,
                                     total_tokens = Count,
                                     avail_tokens = Count,
                                     waiting_pool = WaitingPool,
                                     active_pool = ActivePool,
                                     target_load = TargetLoad,
                                     monitor_dict = MonitorDict}}.

handle_call({send_signal, {TargetNode, Signal}}, {Pid, _Tag},
            #concurrency_throttle_state{avail_tokens = AvailTokens} = State) when AvailTokens < 1 ->
    #concurrency_throttle_state{waiting_pool = WaitingPool,
                                target_load = TargetLoad} = State,

    %% no available token, put job into waiting pool
    NewWaitingPool = dict:store(Pid, {Signal, TargetNode, os:timestamp()}, WaitingPool),
    NewTargetLoad = case dict:is_key(TargetNode, TargetLoad) of
                        false ->
                            dict:store(TargetNode, 0, TargetLoad);
                        _ ->
                            TargetLoad
                    end,
    NewState = State#concurrency_throttle_state{target_load = NewTargetLoad,
                                                waiting_pool = NewWaitingPool},
    {reply, ok, update_status_to_parent(NewState)};

handle_call({send_signal, {TargetNode, Signal}}, {Pid, _Tag}, State) ->

    MonRef = erlang:monitor(process, Pid),

    #concurrency_throttle_state{avail_tokens = Count,
                                waiting_pool = _WaitingPool,
                                active_pool = ActivePool,
                                target_load = TargetLoad,
                                monitor_dict = MonDict} = State,

    NewMonDict = dict:store(Pid, MonRef, MonDict),
    NewActivePool = dict:store(Pid, TargetNode, ActivePool),
    %% update target_load
    NewTargetLoad = dict:update_counter(TargetNode, 1, TargetLoad),
    NewCount = Count - 1,
    %% signal vb replicator
    Pid ! Signal,

    NewState = State#concurrency_throttle_state{
                 avail_tokens = NewCount,
                 monitor_dict = NewMonDict,
                 target_load = NewTargetLoad,
                 active_pool = NewActivePool},

    {reply, ok, update_status_to_parent(NewState)};


handle_call({change_tokens, NewTokens}, {Pid, _Tag}, State) ->

    #concurrency_throttle_state{total_tokens = TotalTokens,
                                avail_tokens = AvailTokens,
                                waiting_pool = _WaitingPool,
                                active_pool = ActivePool} = State,

    case NewTokens == TotalTokens of
        true ->
            %% nothing has changed
            {reply, ok, State};
        _ ->
            %% Available tokens can be negative if users reduce total tokens
            %% in this case, no new jobs will be scheduled until enough tokens
            %% have been freed.
            NewAvailTokens = NewTokens - dict:size(ActivePool),
            State1 =  State#concurrency_throttle_state{total_tokens = NewTokens,
                                                       avail_tokens = NewAvailTokens},
            ?log_debug("number of total tokens changes from ~p to ~p, "
                       "number of available tokens changes from  ~p to ~p, reported by replicator: ~p",
                       [TotalTokens, NewTokens, AvailTokens, NewAvailTokens,Pid]),

            %% schedule more jobs if we have more available tokens
            NewState = if
                           NewAvailTokens > 0 ->
                               ?log_debug("Will signal ~p process to proceed", [NewAvailTokens]),
                               signal_waiting(State1, NewAvailTokens);
                           NewAvailTokens < 0 ->
                               ?log_debug("Will ask ~p processes to return token back", [-NewAvailTokens]),
                               ask_to_return_token(dict:to_list(ActivePool), -NewAvailTokens),
                               State1;
                           NewAvailTokens =:= 0 ->
                               State1
                       end,
            {reply, ok, update_status_to_parent(NewState)}
    end;

handle_call(done, {Pid, _Tag},
            #concurrency_throttle_state{monitor_dict = MonDict} = State) ->

    true = erlang:demonitor(dict:fetch(Pid, MonDict), [flush]),
    NewState = clean_concurr_throttle_state(Pid, normal, State),
    State2  = schedule_waiting_jobs(NewState),
    {reply, ok, update_status_to_parent(State2)}.

handle_cast(Msg, State) ->
    {stop, {error, {unexpected_cast, Msg}}, State}.

handle_info({'DOWN', _MonRef, Type, Pid, Info},
            #concurrency_throttle_state{monitor_dict = _MonDict} = State) ->
    NewState = clean_concurr_throttle_state(Pid, {Type, Info}, State),
    {noreply, schedule_waiting_jobs(NewState)}.


signal_waiting(#concurrency_throttle_state{} = State, 0) ->
    State;

signal_waiting(#concurrency_throttle_state{} = State, NumJobsToSchedule) ->

    #concurrency_throttle_state{avail_tokens = Count,
                                waiting_pool = WaitingPool,
                                active_pool = ActivePool,
                                target_load = TargetLoad,
                                monitor_dict = MonDict} = State,
    case dict:size(WaitingPool) of
        0 ->
            State;
        _ ->
            {WaitingPid, Signal, TargetNode} = choose_pid_to_schedule(WaitingPool,
                                                                      TargetLoad),
            %% signal to next it can go
            %% if WaitingPid died, we'll get a 'DOWN' message
            MonRef = erlang:monitor(process, WaitingPid),
            NewWaitingPool = dict:erase(WaitingPid, WaitingPool),
            NewActivePool = dict:store(WaitingPid, TargetNode, ActivePool),
            NewTargetLoad = dict:update_counter(TargetNode, 1, TargetLoad),

            WaitingPid ! Signal,
            NewState = State#concurrency_throttle_state{
                         avail_tokens = Count - 1,
                         monitor_dict = dict:store(WaitingPid, MonRef, MonDict),
                         active_pool = NewActivePool,
                         waiting_pool = NewWaitingPool,
                         target_load = NewTargetLoad},
            update_status_to_parent(NewState),
            signal_waiting(NewState, (NumJobsToSchedule - 1))
    end.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% based on laod table and table of waiting reps, choose one
%% replication to schedule such that the target node has the
%% minimum active replications
choose_pid_to_schedule(WaitingPool, TargetLoad) ->
    {MinimumPid, _Load, _MinTS} = dict:fold(
                            fun(Pid, {_, CurrNode, TS}, {MinPid, MinLoad, MinTS}) ->
                                    CurrLoad = case dict:find(CurrNode, TargetLoad) of
                                                   error ->
                                                       0;
                                                   {ok, XCurrLoad} ->
                                                       XCurrLoad
                                               end,
                                    if
                                        CurrLoad < MinLoad ->
                                            {Pid, CurrLoad, TS};
                                        CurrLoad =:= MinLoad andalso TS < MinTS ->
                                            {Pid, CurrLoad, TS};
                                        true ->
                                            {MinPid, MinLoad, MinTS}
                                    end
                            end,
                            %% the max # of active resp per node is the number of vbuckets
                            {0, 9999, 0},
                            WaitingPool),

    {Signal, TargetNode, _} = dict:fetch(MinimumPid, WaitingPool),
    {MinimumPid, Signal, TargetNode}.


clean_concurr_throttle_state(Pid, _Reason, #concurrency_throttle_state{
                                    avail_tokens = AvailTokens, monitor_dict = MonDict,
                                    active_pool = ActivePool,
                                    target_load = TargetLoad } = State) ->
    %% update monitoring and active reps dictionaries
    NewMonDict = dict:erase(Pid, MonDict),
    NewActivePool = dict:erase(Pid, ActivePool),
    %% update target_load dict
    TargetNode = dict:fetch(Pid, ActivePool),
    NewLoad = dict:fetch(TargetNode, TargetLoad) - 1,
    NewTargetLoad = case NewLoad > 0 of
                        true ->
                            dict:store(TargetNode, NewLoad, TargetLoad);
                        _ ->
                            dict:erase(TargetNode, TargetLoad)
                    end,

    NewState =  State#concurrency_throttle_state{
                  avail_tokens = AvailTokens + 1,
                  monitor_dict = NewMonDict,
                  active_pool = NewActivePool,
                  target_load = NewTargetLoad},

    NewState.

update_status_to_parent(#concurrency_throttle_state{parent = undefined} = State) ->
    State;
update_status_to_parent(#concurrency_throttle_state{
                           parent = Parent,
                           waiting_pool = WaitingPool,
                           active_pool = ActivePool} = State) ->
    NumActive = dict:size(ActivePool),
    NumWaiting = dict:size(WaitingPool),
    Parent ! {set_throttle_status, {NumActive, NumWaiting}},
    State.


schedule_waiting_jobs(#concurrency_throttle_state{avail_tokens = AvailTokens} = State) ->
    case AvailTokens > 0 of
        true ->
            signal_waiting(State, AvailTokens);
        _ ->
            ?log_debug("no available tokens (wait abs(~p) active jobs done to free tokens) "
                       "to schedule jobs", [AvailTokens]),
            State
    end.

ask_to_return_token(_, _TokensToReturn = 0) -> ok;
ask_to_return_token([{Pid , _Node} | Rest], TokensToReturn) ->
    Pid ! return_token_please,
    ask_to_return_token(Rest, TokensToReturn - 1);
ask_to_return_token([], _TokensToReturn) -> ok.
