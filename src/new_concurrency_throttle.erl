%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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

-module(new_concurrency_throttle).
-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").

-export([send_back_when_can_go/2, send_back_when_can_go/3, is_done/1]).
-export([change_tokens/2]).
-export([start_link/2, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

%% for debugging and diagnostics purposes
-export([get_waiters_and_monitors/1]).

-record(state, {update_status_tref :: reference() | undefined,
                type :: term(),
                parent :: pid() | undefined,
                total_tokens :: non_neg_integer(),
                %% Contains per destination counter that is bumped
                %% every time we schedule or queue something towards
                %% that destination
                %%
                %% Schema:
                %% {Dest, non_neg_integer()}
                load_counters,
                %% Associates Pid of waiters, message to send and pair
                %% {Counter, Dest}. The later is key and whole table
                %% is ordered set making it easy to find earliest
                %% waiter.
                %%
                %% Schema:
                %% {{non_neg_integer(), Dest}, Pid, Signal :: any()}
                waiters,
                %% Contains avail and gc_counter counters.
                %%
                %% 'avail' counter tracks available tokens of -<count
                %% of waiters> if there are no tokens left
                %%
                %% And tracks all waiters for token or holders of the
                %% tokens. Second field is 1 if Pid holds token and 0
                %% otherwise. Third field is monitor reference and
                %% fourth field holds waiters table key for processes
                %% waiting for token (i.e. so that if process waiting
                %% for token dies we can completely forget it).
                %%
                %% Schema:
                %% {avail|gc_counter, integer()}
                %%   | {Pid, 0|1, MonRef::reference(), WaitersKey::term()}
                monitors}).

%% we'll bother parent with our stats 5 times per second max
-define(UPDATE_STATE_TO_PARENT_DELAY, 200).

-define(PARENT_UPDATES_PER_GC, 50).

-define(OLD_LOAD_KEY_THRESHOLD, 64).

start_link({MaxConcurrency, Type}, Parent) ->
    gen_server:start_link(?MODULE, {MaxConcurrency, Type, Parent}, []).

send_back_when_can_go(Server, Signal) ->
    send_back_when_can_go(Server, [], Signal).

send_back_when_can_go(Server, LoadKey, Signal) ->
    gen_server:cast(Server, {send_signal, LoadKey, Signal, self()}).

is_done(Server) ->
    gen_server:cast(Server, {done, self()}).

change_tokens(Server, NewTokens) ->
    gen_server:call(Server, {change_tokens, NewTokens}, infinity).



terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init({Count, Type, Parent}) ->
    ?log_debug("init concurrent throttle process, pid: ~p, type: ~p"
               "# of available token: ~p", [self(), Type, Count]),
    true = (Count >= 0),

    LoadCountersTid = ets:new(ok, [set, protected]),
    WaitersTid = ets:new(ok, [ordered_set, protected]),
    MonitorsTid = ets:new(ok, [set, protected]),

    ets:insert(MonitorsTid, {avail, Count}),
    ets:insert(MonitorsTid, {gc_counter, 0}),

    {ok, #state{type = Type,
                parent = Parent,
                total_tokens = Count,
                load_counters = LoadCountersTid,
                waiters = WaitersTid,
                monitors = MonitorsTid}}.


handle_info(send_update_to_parent,
            #state{parent = Parent,
                   total_tokens = TotalTokens,
                   load_counters = LoadCountersTid,
                   waiters = WaitersTid,
                   monitors = MonitorsTid} = State) ->
    case Parent of
        undefined ->
            ok;
        _ ->
            [{_, Avail}] = ets:lookup(MonitorsTid, avail),
            ActiveCount = erlang:min(TotalTokens - Avail, TotalTokens),
            WaitingCount = -erlang:min(0, Avail),
            Parent ! {set_throttle_status, {ActiveCount, WaitingCount}}
    end,

    case ets:update_counter(MonitorsTid, gc_counter, {2, 1, ?PARENT_UPDATES_PER_GC - 1, 0}) of
        0 ->
            %% we've reached ?PARENT_UPDATES_PER_GC runs of
            %% send_update_to_parent. Let's drop all load_counters
            %% entries that are too much behind
            AllCounters = ets:tab2list(LoadCountersTid),
            HighestCounter = case ets:first(WaitersTid) of
                                 '$end_of_table' ->
                                     lists:max([C || {_, C} <- AllCounters]);
                                 {WCounter, _} ->
                                     WCounter
                             end,
            CountersToDrop = [{LK, C} || {LK, C} <- AllCounters,
                                         HighestCounter - C > ?OLD_LOAD_KEY_THRESHOLD],
            case CountersToDrop of
                [] ->
                    ok;
                _ ->
                    [ets:delete_object(LoadCountersTid, Pair)
                     || Pair <- CountersToDrop]
            end;
        _ ->
            ok
    end,

    {noreply, State#state{update_status_tref = undefined}};

handle_info({'DOWN', _MonRef, _, Pid, _}, State) ->
    handle_cast({done, Pid}, State).

handle_cast({done, Pid},
            #state{waiters = WaitersTid,
                   monitors = MonitorsTid} = State) ->
    [{_, TokenMarker, MonRef, WaitersKey}] = ets:lookup(MonitorsTid, Pid),
    ets:delete(MonitorsTid, Pid),
    erlang:demonitor(MonRef, [flush]),
    case TokenMarker of
        0 ->
            %% it's DOWN from process that has no token. Or done from
            %% process that was asked to return_token_please
            ets:delete(WaitersTid, WaitersKey);
        1 ->
            %% it's done or DOWN from process that has token
            NewAvail = ets:update_counter(MonitorsTid, avail, 1),
            if
                NewAvail > 0 ->
                    ok;
                true ->
                    %% we have a waiter to wake up
                    wakeup_one_waiter(WaitersTid, MonitorsTid)
            end
    end,
    {noreply, update_status_to_parent(State)};

handle_cast({send_signal, LoadKey, Signal, Pid},
            #state{load_counters = LoadCountersTid,
                   waiters = WaitersTid,
                   monitors = MonitorsTid} = State) ->
    LoadKeyCounter = try ets:update_counter(LoadCountersTid, LoadKey, 1)
                     catch error:badarg ->
                             %% it's brand-new LoadKey (target
                             %% node). Ensure it's not too small
                             %% counter to avoid unfairly sending all
                             %% load to it
                             Counts = [C || {_, C} <- ets:tab2list(LoadCountersTid)],
                             HighestCounter = lists:max([0 | Counts]),
                             XCounter = HighestCounter - (?OLD_LOAD_KEY_THRESHOLD div 2),
                             ets:insert(LoadCountersTid, {LoadKey, XCounter}),
                             XCounter
                     end,
    NewAvail = ets:update_counter(MonitorsTid, avail, -1),
    MonRef = erlang:monitor(process, Pid),
    if
        NewAvail < 0 ->
            ets:insert(MonitorsTid, {Pid, 0, MonRef, {LoadKeyCounter, LoadKey}}),
            ets:insert(WaitersTid, {{LoadKeyCounter, LoadKey}, Pid, Signal});
        true ->
            Pid ! Signal,
            ets:insert(MonitorsTid, {Pid, 1, MonRef, []})
    end,
    {noreply, update_status_to_parent(State)}.

wakeup_one_waiter(WaitersTid, MonitorsTid) ->
    %% we have a waiter to wake up
    Key = ets:first(WaitersTid),
    true = (Key =/= '$end_of_table'),
    [{_, NewPid, Signal}] = ets:lookup(WaitersTid, Key),
    NewPid ! Signal,
    ets:delete(WaitersTid, Key),
    %% mark entry in monitors table as having token
    ets:update_counter(MonitorsTid, NewPid, 1).

handle_call({change_tokens, NewTotalTokens}, _From,
            #state{waiters = WaitersTid,
                   total_tokens = OldTotalTokens,
                   monitors = MonitorsTid} = State)->
    true = (NewTotalTokens >= 0),
    case NewTotalTokens > OldTotalTokens of
        true ->
            ExtraTokens = NewTotalTokens - OldTotalTokens,
            WaitersCount = ets:info(WaitersTid, size),
            [wakeup_one_waiter(WaitersTid, MonitorsTid)
             || _ <- lists:seq(1, erlang:min(ExtraTokens, WaitersCount))],
            ets:update_counter(MonitorsTid, avail, erlang:max(0, ExtraTokens - WaitersCount));
        _ ->
            TokensToRemove = OldTotalTokens - NewTotalTokens,
            [{_, NowAvail}] = ets:lookup(MonitorsTid, avail),
            ToReturnTokens =
                if
                    NowAvail >= TokensToRemove ->
                        %% we have more tokens available than we need
                        %% to remove. So just decrease avail count
                        ets:update_counter(MonitorsTid, avail, -TokensToRemove),
                        0;
                    NowAvail > 0 ->
                        %% we don't have enough tokens available to
                        %% cover jump down. But there are some tokens
                        %% available. So we decrease avail count to
                        %% 0. And rest of tokens to remove is handled
                        %% via asking existing workers to return token
                        %% back
                        ets:update_counter(MonitorsTid, avail, -NowAvail),
                        TokensToRemove - NowAvail;
                    NowAvail =< 0 ->
                        %% we have no tokens available at all. So all
                        %% tokens that we need to remove must be
                        %% handled via asking existing workers to
                        %% return token back
                        TokensToRemove
                end,

            true = (ToReturnTokens =< OldTotalTokens - NowAvail),
            true = (ToReturnTokens =< OldTotalTokens),

            RunningPids = [P || {P, 1, _, _} <- ets:tab2list(MonitorsTid)],
            misc:letrec(
              [RunningPids, ToReturnTokens],
              fun (_Rec, [], TokensLeft) ->
                      %% ToReturnTokens cannot be greater than count
                      %% of current holders of tokens, so if we
                      %% handled everyone and there are still tokens
                      %% left "to remove" then something isn't right
                      0 = TokensLeft,
                      ok;
                  (_Rec, _, 0) ->
                      ok;
                  (Rec, [Pid | RestPids], TokensLeft) ->
                      Pid ! return_token_please,
                      %% for processes that we're asking to return
                      %% token back we want their token to be
                      %% "lost". So we mark them as if they're not
                      %% holding tokens. So that done or exit from
                      %% them doesn't increase avail count
                      %%
                      %% Second field is our marker. And per filter of
                      %% RunningPids above is 1. We decrement down to
                      %% 0.
                      ets:update_counter(MonitorsTid, Pid, -1),
                      Rec(Rec, RestPids, TokensLeft-1)
              end)
    end,

    {reply, ok, update_status_to_parent(State#state{total_tokens = NewTotalTokens})};
handle_call(get_state, _From, State) ->
    {reply, State, State}.


update_status_to_parent(#state{type = testing} = State) ->
    self() ! send_update_to_parent,
    State;
update_status_to_parent(#state{update_status_tref = undefined} = State) ->
    TR = erlang:send_after(?UPDATE_STATE_TO_PARENT_DELAY, self(), send_update_to_parent),
    State#state{update_status_tref = TR};
update_status_to_parent(State) ->
    State.


get_waiters_and_monitors(T) ->
    #state{waiters = WaitersTid,
           monitors = MonitorsTid} = gen_server:call(T, get_state, infinity),
    Waiters = ets:tab2list(WaitersTid),
    Monitors0 = ets:tab2list(MonitorsTid),
    {Monitors, SystemMonitorRecords} =
        lists:partition(
          fun (Tuple) ->
                  is_pid(erlang:element(1, Tuple))
          end, Monitors0),
    {Waiters, Monitors, SystemMonitorRecords}.

-ifdef(EUNIT).

basic_test_() ->
    {spawn, fun do_basic_test_run/0}.

do_basic_test_run() ->
    {ok, T} = ?MODULE:start_link({10, testing}, undefined),
    State = gen_server:call(T, get_state, infinity),
    ?assertMatch(#state{type = testing,
                        parent = undefined,
                        total_tokens = 10},
                 State),
    [] = ets:tab2list(State#state.load_counters),
    Childs = [proc_lib:spawn_link(fun start_test_worker/0) || _ <- lists:seq(1, 20)],
    [begin
         hd(Childs) ! {ask, T, 1, self(), false},
         receive
             X ->
                 P = hd(Childs),
                 {P, got_token} = X,
                 P ! put
         end
     end || _ <- lists:seq(1, 100)],

    FirstChilds = misc:enumerate(lists:sublist(Childs, 10)),
    [C ! {ask, T, Idx rem 2, self(), false} || {Idx, C} <- FirstChilds],
    [receive
         {C, got_token} -> ok
     end || {_, C} <- FirstChilds],

    NextChild = lists:nth(11, Childs),
    NextChild ! {ask, T, 1, self(), true},
    receive
        X ->
            {NextChild, requested_token} = X
    end,

    {Waiters, Monitors, SystemMonitorRecords} = get_waiters_and_monitors(T),

    ?assertEqual(1, length(Waiters)),
    ?assertEqual(11, length(Monitors)),
    ?assertEqual(2, length(SystemMonitorRecords)),

    {avail, -1} = lists:keyfind(avail, 1, SystemMonitorRecords),
    FirstChildPids = lists:sort([C || {_, C} <- FirstChilds]),
    PidsWithTokens = lists:sort([C || {C, 1, _, _} <- Monitors]),
    ?assertEqual(FirstChildPids, PidsWithTokens),
    ?assertEqual(10, length(PidsWithTokens)),

    ?assertEqual([NextChild], [C || {C, 0, _, _} <- Monitors]),

    hd(FirstChildPids) ! put,

    receive
        X2 ->
            {NextChild, got_token} = X2
    end,

    {_, _, SystemMonitorRecords2} = get_waiters_and_monitors(T),
    {avail, 0} = lists:keyfind(avail, 1, SystemMonitorRecords2),

    NextChild2 = lists:nth(12, Childs),
    NextChild2 ! {ask, T, 0, self(), true},
    receive
        X3 ->
            {NextChild2, requested_token} = X3
    end,

    {_, _, SystemMonitorRecords3} = get_waiters_and_monitors(T),
    {avail, -1} = lists:keyfind(avail, 1, SystemMonitorRecords3),

    receive
        X4 ->
            erlang:error({unexpected_msg, X4})
    after 0 ->
            ok
    end,

    FirstToKill = lists:nth(2, FirstChildPids),
    erlang:unlink(FirstToKill),
    erlang:exit(FirstToKill, exit),

    receive
        X5 ->
            {NextChild2, got_token} = X5
    end,

    SecondToKill = lists:nth(3, FirstChildPids),
    erlang:unlink(SecondToKill),
    erlang:exit(SecondToKill, exit),

    ThirdToKill = lists:nth(4, FirstChildPids),
    erlang:unlink(ThirdToKill),
    erlang:exit(ThirdToKill, exit),

    {_, _, SystemMonitorRecords4} = get_waiters_and_monitors(T),
    {avail, 2} = lists:keyfind(avail, 1, SystemMonitorRecords4),

    NextChild3 = lists:nth(13, Childs),
    NextChild3 ! {ask, T, 1, self(), false},
    receive
        X6 ->
            {NextChild3, got_token} = X6
    end,

    ok.

start_test_worker() ->
    receive
        {ask, T, LoadKey, Parent, AckSendToken} ->
            ?MODULE:send_back_when_can_go(T, LoadKey, go),
            case AckSendToken of
                true ->
                    Parent ! {self(), requested_token};
                _ ->
                    ok
            end,
            receive
                go ->
                    Parent ! {self(), got_token},
                    receive
                        put ->
                            ?MODULE:is_done(T)
                    end
            end
    end,
    start_test_worker().

-endif.
