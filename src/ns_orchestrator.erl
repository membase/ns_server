%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
%% Monitor and maintain the vbucket layout of each bucket.
%% There is one of these per bucket.
%%
-module(ns_orchestrator).

-behaviour(gen_fsm).

-include("ns_common.hrl").

%% Constants and definitions

-record(idle_state, {}).
-record(rebalancing_state, {rebalancer, progress::dict(), moves}).


%% API
-export([failover/1,
         needs_rebalance/0,
         rebalance_progress/0,
         remaining_moves/1,
         reset_progress/0,
         starting_moves/1,
         start_link/0,
         start_rebalance/2,
         stop_rebalance/0,
         update_progress/1,
         update_progress/2
         ]).

-define(SERVER, {global, ?MODULE}).

-define(REBALANCE_SUCCESSFUL, 1).
-define(REBALANCE_FAILED, 2).
-define(REBALANCE_NOT_STARTED, 3).
-define(REBALANCE_STARTED, 4).

%% gen_fsm callbacks
-export([code_change/4,
         init/1,
         handle_event/3,
         handle_info/3,
         handle_sync_event/4,
         terminate/3]).

%% States
-export([idle/3,
         rebalancing/2,
         rebalancing/3]).


%%
%% API
%%

start_link() ->
    misc:start_singleton(gen_fsm, ?MODULE, [], []).


-spec failover(atom()) -> ok.
failover(Node) ->
    gen_fsm:sync_send_event(?SERVER, {failover, Node}).


-spec needs_rebalance() -> boolean().
needs_rebalance() ->
    Bucket = "default",
    {_NumReplicas, _NumVBuckets, Map, Servers} = ns_bucket:config(Bucket),
    NumServers = length(Servers),
    %% Don't warn about missing replicas when you have fewer servers
    %% than your copy count!
    lists:any(
      fun (Chain) ->
              lists:member(
                undefined,
                lists:sublist(Chain, NumServers))
      end, Map) orelse
        ns_rebalancer:unbalanced(Map, Servers).


-spec rebalance_progress() -> {running, [{atom(), float()}]} | not_running.
rebalance_progress() ->
    try gen_fsm:sync_send_event(?SERVER, rebalance_progress, 2000) of
        Result -> Result
    catch
        Type:Err ->
            ?log_error("Couldn't talk to orchestrator: ~p", [{Type, Err}]),
            not_running
    end.


-spec start_rebalance([atom()], [atom()]) ->
                             ok | in_progress | already_balanced.
start_rebalance(KeepNodes, EjectNodes) ->
    gen_fsm:sync_send_event(?SERVER, {start_rebalance, KeepNodes,
                                      EjectNodes}).


-spec stop_rebalance() -> ok | not_rebalancing.
stop_rebalance() ->
    gen_fsm:sync_send_event(?SERVER, stop_rebalance).


%%
%% gen_fsm callbacks
%%

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.


init([]) ->
    process_flag(trap_exit, true),
    timer:send_interval(10000, janitor),
    self() ! check_initial,
    {ok, idle, #idle_state{}}.


handle_event(unhandled, unhandled, unhandled) ->
    unhandled.


handle_sync_event(unhandled, unhandled, unhandled, unhandled) ->
    unhandled.


handle_info(check_initial, StateName, StateData) ->
    Bucket = "default",
    {_, _, _, Servers} = ns_bucket:config(Bucket),
    case Servers == undefined orelse Servers == [] of
        true ->
            ns_log:log(?MODULE, ?REBALANCE_STARTED,
                       "Performing initial rebalance~n"),
            ns_cluster_membership:activate([node()]),
            timer:apply_after(0, ?MODULE, start_rebalance, [[node()], []]);
        false ->
            ok
    end,
    {next_state, StateName, StateData};
handle_info(janitor, idle, State) ->
    misc:flush(janitor),
    Bucket = "default",
    {_, _, Map, Servers} = ns_bucket:config(Bucket),
    %% Just block the gen_fsm while the janitor runs
    %% This way we don't have to worry about queuing request.
    ns_janitor:cleanup(Bucket, Map, Servers),
    {next_state, idle, State};
handle_info(janitor, StateName, StateData) ->
    misc:flush(janitor),
    {next_state, StateName, StateData};
handle_info({'EXIT', Pid, Reason}, rebalancing,
            #rebalancing_state{rebalancer=Pid}) ->
    Status = case Reason of
                 normal ->
                     ns_log:log(?MODULE, ?REBALANCE_SUCCESSFUL,
                                "Rebalance completed successfully.~n"),
                     none;
                 _ ->
                     ns_log:log(?MODULE, ?REBALANCE_FAILED,
                                "Rebalance exited with reason ~p~n", [Reason]),
                     {none, <<"Rebalance failed. See logs for detailed reason. "
                              "You can try rebalance again.">>}
             end,
    ns_config:set(rebalance_status, Status),
    {next_state, idle, #idle_state{}};
handle_info(Msg, StateName, StateData) ->
    ?log_warning("Got unexpected message ~p in state ~p with data ~p",
                 [Msg, StateName, StateData]),
    {next_state, StateName, StateData}.


terminate(_Reason, _StateName, _StateData) ->
    ok.


%%
%% States
%%

%% Synchronous idle events
idle({failover, Node}, _From, State) ->
    ?log_info("Failing over ~p", [Node]),
    Result = ns_rebalancer:failover("default", Node),
    {reply, Result, idle, State};
idle(rebalance_progress, _From, State) ->
    {reply, not_running, idle, State};
idle({start_rebalance, KeepNodes, EjectNodes}, _From,
            State) ->
    ns_log:log(?MODULE, ?REBALANCE_STARTED,
               "Starting rebalance, KeepNodes = ~p, EjectNodes = ~p~n",
               [KeepNodes, EjectNodes]),
    Bucket = "default",
    {_NumReplicas, _NumVBuckets, Map, Servers} = ns_bucket:config(Bucket),
    case {lists:sort(Servers), lists:sort(KeepNodes), EjectNodes,
          ns_rebalancer:unbalanced(Map, Servers)} of
        {S, S, [], false} ->
            ns_log:log(?MODULE, ?REBALANCE_NOT_STARTED,
              "Not rebalancing because the cluster is already balanced~n"),
            {reply, already_balanced, idle, State};
        _ ->
            Pid = spawn_link(
                    fun() ->
                            ns_rebalancer:rebalance(Bucket, KeepNodes,
                                                    EjectNodes, Map)
                    end),
            {reply, ok, rebalancing, #rebalancing_state{progress=dict:new(),
                                                        rebalancer=Pid}}
    end;
idle(stop_rebalance, _From, State) ->
    {reply, not_rebalancing, idle, State}.


%% Asynchronous rebalancing events
rebalancing({update_progress, Progress},
            #rebalancing_state{progress=Old} = State) ->
    NewProgress = dict:merge(fun (_, _, New) -> New end, Old, Progress),
    {next_state, rebalancing,
     State#rebalancing_state{progress=NewProgress}};
rebalancing(reset_progress, State) ->
    {next_state, rebalancing,
     State#rebalancing_state{progress=dict:new(), moves=undefined}};
rebalancing({remaining_moves, Node, M},
            #rebalancing_state{moves=Moves, progress=Progress} = State) ->
    N = 1.0 - dict:fetch(Node, Moves) / M,
    {next_state, rebalancing,
     State#rebalancing_state{progress=dict:store(Node, N, Progress)}};
rebalancing({starting_moves, M}, State) ->
    Progress = dict:map(fun (_, _) -> 0.0 end, M),
    {next_state, rebalancing, State#rebalancing_state{moves=M,
                                                      progress=Progress}}.


%% Synchronous rebalancing events
rebalancing({failover, _Node}, _From, State) ->
    {reply, rebalancing, rebalancing, State};
rebalancing(start_rebalance, _From, State) ->
    ns_log:log(?MODULE, ?REBALANCE_NOT_STARTED,
               "Not rebalancing because rebalance is already in progress.~n"),
    {reply, in_progress, rebalancing, State};
rebalancing(stop_rebalance, _From,
            #rebalancing_state{rebalancer=Pid} = State) ->
    Pid ! stop,
    {reply, ok, rebalancing, State};
rebalancing(rebalance_progress, _From,
            #rebalancing_state{progress = Progress} = State) ->
    {reply, {running, dict:to_list(Progress)}, rebalancing, State}.



%%
%% Internal functions
%%

%% Tell the orchestrator how many moves are remaining for each node.
-spec remaining_moves(dict()) -> ok.
remaining_moves(Moves) ->
    gen_fsm:send_event(?SERVER, {remaining_moves, Moves}).


-spec reset_progress() -> ok.
reset_progress() ->
    gen_fsm:send_event(?SERVER, reset_progress).


%% Tell the orchestrator about the set of moves we're starting.
-spec starting_moves(dict()) -> ok.
starting_moves(Moves) ->
    gen_fsm:send_event(?SERVER, {starting_moves, Moves}).


-spec update_progress(dict()) -> ok.
update_progress(Progress) ->
    gen_fsm:send_event(?SERVER, {update_progress, Progress}).


-spec update_progress([atom()], float()) -> ok.
update_progress(Nodes, Fraction) ->
    update_progress(dict:from_list([{Node, Fraction}
                                    || Node <- lists:usort(Nodes)])).
