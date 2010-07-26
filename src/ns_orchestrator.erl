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
-record(rebalancing_state, {rebalancer, progress=[], moves}).


%% API
-export([failover/1,
         needs_rebalance/0,
         rebalance_progress/0,
         start_link/0,
         start_rebalance/2,
         stop_rebalance/0]).

-define(SERVER, {global, ?MODULE}).

-define(REBALANCE_SUCCESSFUL, 1).
-define(REBALANCE_FAILED, 2).
-define(REBALANCE_NOT_STARTED, 3).
-define(REBALANCE_STARTED, 4).

-type histogram() :: [{atom(), non_neg_integer()}].
-type map() :: [[non_neg_integer()]].
-type move_counts() :: [{atom(), non_neg_integer()}].
-type moves() :: [{non_neg_integer(), atom(), atom()}].

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
        unbalanced(histograms(Map, Servers)).


-spec rebalance_progress() -> {running, [{atom(), float()}]} | not_running.
rebalance_progress() ->
    try gen_fsm:sync_send_event(?SERVER, rebalance_progress, 2000) of
        Result -> Result
    catch
        Type:Err ->
            ?log_error("Couldn't talk to orchestrator: ~p", [{Type, Err}]),
            not_running
    end.


-spec start_rebalance([atom()], [atom()]) -> ok | in_progress.
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
handle_info({Ref, Reason}, rebalancing,
            #rebalancing_state{rebalancer={_Pid, Ref}}) ->
    Status = case Reason of
                 {'EXIT', _, normal} ->
                     ns_log:log(?MODULE, ?REBALANCE_SUCCESSFUL,
                                "Rebalance completed successfully.~n"),
                     none;
                 {'EXIT', _, R} ->
                     ns_log:log(?MODULE, ?REBALANCE_FAILED,
                                "Rebalance exited with reason ~p~n", [R]),
                     {none, <<"Rebalance failed. See logs for detailed reason. You can try rebalance again.">>};
                 _ ->
                     ns_log:log(?MODULE, ?REBALANCE_FAILED,
                                "Rebalance failed with reason ~p~n", [Reason]),
                     {none, <<"Rebalance failed. See logs for detailed reason. You can try rebalance again.">>}
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
    Bucket = "default",
    {_, _, Map, Servers} = ns_bucket:config(Bucket),
    %% Promote replicas of vbuckets on this node
    Map1 = promote_replicas(Bucket, Map, [Node]),
    ns_bucket:set_map(Bucket, Map1),
    ns_bucket:set_servers(Bucket, lists:delete(Node, Servers)),
    lists:foreach(fun (N) ->
                          ns_vbm_sup:kill_dst_children(N, Bucket, Node)
                  end, lists:delete(Node, Servers)),
    {reply, ok, idle, State};
idle(rebalance_progress, _From, State) ->
    {reply, not_running, idle, State};
idle({start_rebalance, KeepNodes, EjectNodes}, _From,
            State) ->
    ns_log:log(?MODULE, ?REBALANCE_STARTED,
               "Starting rebalance, KeepNodes = ~p, EjectNodes = ~p~n",
               [KeepNodes, EjectNodes]),
    Bucket = "default",
    {_NumReplicas, _NumVBuckets, Map, Servers} = ns_bucket:config(Bucket),
    Histograms = histograms(Map, Servers),
    case {lists:sort(Servers), lists:sort(KeepNodes), EjectNodes,
          unbalanced(Histograms)} of
        {S, S, [], false} ->
            ns_log:log(?MODULE, ?REBALANCE_NOT_STARTED,
              "Not rebalancing because the cluster is already balanced~n"),
            {reply, already_balanced, idle, State};
        _ ->
            {ok, Pid, Ref} =
                misc:spawn_link_safe(
                  fun () ->
                          spawn_link(
                            fun() ->
                                    do_rebalance(Bucket, KeepNodes, EjectNodes,
                                                 Map, 2)
                            end)
                  end),
            {reply, ok, rebalancing, #rebalancing_state{rebalancer={Pid, Ref},
                                                        progress=[]}}
    end;
idle(stop_rebalance, _From, State) ->
    {reply, not_rebalancing, State}.


%% Asynchronous rebalancing events
rebalancing({update_progress, Progress},
            #rebalancing_state{progress=Old} = State) ->
    {next_state, rebalancing,
     State#rebalancing_state{progress=lists:ukeymerge(1, Progress, Old)}};
rebalancing(reset_progress, State) ->
    {next_state, rebalancing,
     State#rebalancing_state{progress=[], moves=undefined}};
rebalancing({remaining_moves, M},
            #rebalancing_state{moves=Moves, progress=Progress} = State) ->
    P = [{Node, 1.0 - N / dict:fetch(Node, Moves)} || {Node, N} <- M],
    {next_state, rebalancing,
     State#rebalancing_state{progress=lists:ukeymerge(1, P, Progress)}};
rebalancing({starting_moves, M}, State) ->
    {next_state, rebalancing, State#rebalancing_state{moves=dict:from_list(M)}}.


%% Synchronous rebalancing events
rebalancing({failover, _Node}, _From, State) ->
    {reply, rebalancing, rebalancing, State};
rebalancing(start_rebalance, _From, State) ->
    ns_log:log(?MODULE, ?REBALANCE_NOT_STARTED,
               "Not rebalancing because rebalance is already in progress.~n"),
    {reply, in_progress, rebalancing, State};
rebalancing(stop_rebalance, _From,
            #rebalancing_state{rebalancer={Pid, _Ref}} = State) ->
    Pid ! stop,
    {reply, ok, rebalancing, State};
rebalancing(rebalance_progress, _From,
            #rebalancing_state{rebalancer = {_Pid, _Ref},
                               progress = Progress} = State) ->
    {reply, {running, Progress}, rebalancing, State}.



%%
%% Internal functions
%%
apply_moves(_, [], Map) ->
    Map;
apply_moves(I, [{V, _, New}|Tail], Map) ->
    Chain = lists:nth(V+1, Map),
    NewChain = misc:nthreplace(I, New, Chain),
    apply_moves(I, Tail, misc:nthreplace(V+1, NewChain, Map)).

assign(Histogram, AvoidNodes) ->
    Histogram1 = lists:keysort(2, Histogram),
    case lists:splitwith(fun ({N, _}) -> lists:member(N, AvoidNodes) end,
                         Histogram1) of
        {Head, [{Node, N}|Rest]} ->
            {Node, Head ++ [{Node, N+1}|Rest]};
        {_, []} ->
            {undefined, Histogram1}
    end.

balance_nodes(Bucket, Map, Histograms, I) when is_integer(I) ->
    VNF = [{V, lists:nth(I, Chain), lists:sublist(Chain, I-1)} ||
              {V, Chain} <- misc:enumerate(Map, 0)],
    Hist = lists:nth(I, Histograms),
    balance_nodes(Bucket, VNF, Hist, []);
balance_nodes(Bucket, VNF, Hist, Moves) ->
    {MinNode, MinCount} = misc:keymin(2, Hist),
    {MaxNode, MaxCount} = misc:keymax(2, Hist),
    case MaxCount - MinCount > 1 of
        true ->
            %% Get the first vbucket that is on MaxNode and for which MinNode is not forbidden
            case lists:splitwith(
                   fun ({_, N, F}) ->
                           N /= MaxNode orelse
                               lists:member(MinNode, F)
                   end, VNF) of
                {Prefix, [{V, N, F}|Tail]} ->
                    N = MaxNode,
                    VNF1 = Prefix ++ [{V, MinNode, F}|Tail],
                    Hist1 = lists:keyreplace(MinNode, 1, Hist, {MinNode, MinCount + 1}),
                    Hist2 = lists:keyreplace(MaxNode, 1, Hist1, {MaxNode, MaxCount - 1}),
                    balance_nodes(Bucket, VNF1, Hist2, [{V, MaxNode, MinNode}|Moves]);
                X ->
                    error_logger:info_msg("~p:balance_nodes(~p, ~p, ~p): No further moves (~p)~n",
                                          [?MODULE, VNF, Hist, Moves, X]),
                    Moves
            end;
        false ->
            Moves
    end.


%% Count the number of moves remaining from each node.
-spec count_moves(moves()) -> move_counts().
count_moves(Moves) ->
    M = lists:flatmap(fun ({_, Old, New}) -> [Old, New] end, Moves),
    misc:uniqc(lists:sort([N || N <- M, N /= undefined])).


do_rebalance(Bucket, KeepNodes, EjectNodes, Map, Tries) ->
    try
        ns_config:set(rebalance_status, running),
        AllNodes = KeepNodes ++ EjectNodes,
        reset_progress(),
        update_progress(AllNodes, 0.0),
        ns_bucket:set_servers(Bucket, AllNodes),
        AliveNodes = ns_node_disco:nodes_actual_proper(),
        RemapNodes = EjectNodes -- AliveNodes, % No active node, promote a replica
        lists:foreach(fun (N) -> ns_cluster:leave(N) end, RemapNodes),
        maybe_stop(),
        EvacuateNodes = EjectNodes -- RemapNodes, % Nodes we can move data off of
        Map1 = promote_replicas(Bucket, Map, RemapNodes),
        ns_bucket:set_map(Bucket, Map1),
        update_progress(RemapNodes, 1.0),
        maybe_stop(),
        Histograms1 = histograms(Map1, KeepNodes),
        Moves1 = master_moves(Bucket, EvacuateNodes, Map1, Histograms1),
        starting_moves(Moves1),
        Map2 = perform_moves(Bucket, Map1, Moves1),
        update_progress(EvacuateNodes, 1.0),
        maybe_stop(),
        Histograms2 = histograms(Map2, KeepNodes),
        Moves2 = balance_nodes(Bucket, Map2, Histograms2, 1),
        starting_moves(Moves2),
        Map3 = perform_moves(Bucket, Map2, Moves2),
        update_progress(KeepNodes, 0.9),
        maybe_stop(),
        Histograms3 = histograms(Map3, KeepNodes),
        Map4 = new_replicas(Bucket, EjectNodes, Map3, Histograms3),
        ns_bucket:set_map(Bucket, Map4),
        maybe_stop(),
        Histograms4 = histograms(Map4, KeepNodes),
        ChainLength = length(lists:nth(1, Map4)),
        Map5 = lists:foldl(
                 fun (I, M) ->
                         Moves = balance_nodes(Bucket, M, Histograms4, I),
                         apply_moves(I, Moves, M)
                 end, Map4, lists:seq(2, ChainLength)),
        ns_bucket:set_servers(Bucket, KeepNodes),
        ns_bucket:set_map(Bucket, Map5),
        %% Push out the config with the new map in case this node is being removed
        ns_config_rep:push(),
        maybe_stop(),
        %% Leave myself last
        LeaveNodes = lists:delete(node(), EvacuateNodes),
        lists:foreach(fun (N) ->
                              ns_cluster_membership:deactivate([N]),
                              ns_cluster:leave(N)
                      end, LeaveNodes),
        case lists:member(node(), EvacuateNodes) of
            true ->
                ns_cluster_membership:deactivate([node()]),
                ns_cluster:leave();
            false ->
                ok
        end
    catch
        throw:stopped ->
            fixup_replicas(Bucket, KeepNodes, EjectNodes),
            exit(stopped);
        exit:Reason ->
            case Tries of
                0 ->
                    exit(Reason);
                _ ->
                    error_logger:warning_msg(
                      "Rebalance received exit: ~p, retrying.~n", [Reason]),
                    timer:sleep(1500),
                    do_rebalance(Bucket, KeepNodes, EjectNodes, Map, Tries - 1)
            end
    end.

%% Ensure there are replicas for any unreplicated buckets if we stop
fixup_replicas(Bucket, KeepNodes, EjectNodes) ->
    {_, _, Map, _} = ns_bucket:config(Bucket),
    Histograms = histograms(Map, KeepNodes),
    Map1 = new_replicas(Bucket, EjectNodes, Map, Histograms),
    ns_bucket:set_servers(Bucket, KeepNodes ++ EjectNodes),
    ns_bucket:set_map(Bucket, Map1).

master_moves(Bucket, EvacuateNodes, Map, Histograms) ->
    master_moves(Bucket, EvacuateNodes, Map, Histograms, 0, []).

master_moves(_, _, [], _, _, Moves) ->
    Moves;
master_moves(Bucket, EvacuateNodes, [[OldMaster|_]|MapTail], Histograms, V,
                 Moves) ->
    [MHist|RHists] = Histograms,
    case (OldMaster == undefined) orelse lists:member(OldMaster, EvacuateNodes) of
        true ->
            {NewMaster, MHist1} = assign(MHist, []),
            master_moves(Bucket, EvacuateNodes, MapTail, [MHist1|RHists],
                             V+1, [{V, OldMaster, NewMaster}|Moves]);
        false ->
            master_moves(Bucket, EvacuateNodes, MapTail, Histograms, V+1,
                             Moves)
    end.

maybe_stop() ->
    receive stop ->
            throw(stopped)
    after 0 ->
            ok
    end.

new_replicas(Bucket, EjectNodes, Map, Histograms) ->
    new_replicas(Bucket, EjectNodes, Map, Histograms, 0, []).

new_replicas(_, _, [], _, _, NewMapReversed) ->
    lists:reverse(NewMapReversed);
new_replicas(Bucket, EjectNodes, [Chain|MapTail], Histograms, V,
              NewMapReversed) ->
    %% Split off the masters - we don't want to move them!
    {[Master|Replicas], [MHist|RHists]} = {Chain, Histograms},
    ChainHist = lists:zip(Replicas, RHists),
    {Replicas1, RHists1} =
        lists:unzip(
          lists:map(fun ({undefined, Histogram}) ->
                            assign(Histogram, [Master|EjectNodes]);
                        (X = {OldNode, Histogram}) ->
                            case lists:member(OldNode, EjectNodes) of
                                true ->
                                    assign(Histogram, Chain ++ EjectNodes);
                                false ->
                                    X
                            end
                        end, ChainHist)),
    new_replicas(Bucket, EjectNodes, MapTail, [MHist|RHists1], V + 1,
                  [[Master|Replicas1]|NewMapReversed]).


-spec perform_moves(string(), map(), moves()) -> map().
perform_moves(Bucket, Map, []) ->
    ns_bucket:set_map(Bucket, Map),
    Map;
perform_moves(Bucket, Map, [{V, Old, New}|Moves] = Remaining) ->
    try maybe_stop()
    catch
        throw:stopped ->
            ns_bucket:set_map(Bucket, Map),
            throw(stopped)
    end,
    remaining_moves(Remaining),
    [Old|Replicas] = lists:nth(V+1, Map),
    case {Old, New} of
        {X, X} ->
            perform_moves(Bucket, Map, Moves);
        {_, _} ->
            Map1 = misc:nthreplace(V+1, [New|lists:duplicate(length(Replicas),
                                                           undefined)], Map),
            case Old of
                undefined ->
                    %% This will fail if another node is restarting.
                    %% The janitor will catch it later if it does.
                    catch ns_memcached:set_vbucket_state(New, Bucket, V, active);
                _ ->
                    ns_vbm_sup:move(Bucket, V, Old, New)
            end,
            perform_moves(Bucket, Map1, Moves)
    end.

promote_replicas(Bucket, Map, RemapNodes) ->
    [promote_replica(Bucket, Chain, RemapNodes, V) ||
        {V, Chain} <- misc:enumerate(Map, 0)].

promote_replica(Bucket, Chain, RemapNodes, V) ->
    [OldMaster|_] = Chain,
    Bad = fun (Node) -> lists:member(Node, RemapNodes) end,
    NotBad = fun (Node) -> not lists:member(Node, RemapNodes) end,
    NewChain = lists:takewhile(NotBad, lists:dropwhile(Bad, Chain)), % TODO garbage collect orphaned pending buckets later
    NewChainExtended = NewChain ++ lists:duplicate(length(Chain) - length(NewChain), undefined),
    case NewChainExtended of
        [OldMaster|_] ->
            %% No need to promote
            NewChainExtended;
        [undefined|_] ->
            error_logger:error_msg("~p:promote_replicas(~p, ~p, ~p, ~p): No master~n", [?MODULE, Bucket, V, RemapNodes, Chain]),
            NewChainExtended;
        [NewMaster|_] ->
            %% The janitor will catch it if this fails.
            catch ns_memcached:set_vbucket_state(NewMaster, V, active),
            NewChainExtended
    end.

histograms(Map, Servers) ->
    Histograms = [lists:keydelete(
                    undefined, 1,
                    misc:uniqc(
                      lists:sort(
                        [N || N<-L,
                              lists:member(N, Servers)]))) ||
                     L <- misc:rotate(Map)],
    lists:map(fun (H) ->
                      Missing = [{N, 0} || N <- Servers,
                                           not lists:keymember(N, 1, H)],
                      Missing ++ H
              end, Histograms).


%% Tell the orchestrator how many moves are remaining for each node.
-spec remaining_moves(moves()) -> ok.
remaining_moves(Moves) ->
    gen_fsm:send_event(?SERVER, {remaining_moves, count_moves(Moves)}).


-spec reset_progress() -> ok.
reset_progress() ->
    gen_fsm:send_event(?SERVER, reset_progress).


%% Tell the orchestrator about the set of moves we're starting.
-spec starting_moves(moves()) -> ok.
starting_moves(Moves) ->
    gen_fsm:send_event(?SERVER, {starting_moves, count_moves(Moves)}).


%% returns true iff the max vbucket count in any class on any server is >2 more than the min
-spec unbalanced([histogram()]) -> boolean().
unbalanced(Histograms) ->
    lists:any(fun (Histogram) ->
                      case [N || {_, N} <- Histogram] of
                          [] -> false;
                          Counts -> lists:max(Counts) - lists:min(Counts) > 2
                      end
              end, Histograms).


-spec update_progress([atom()], float()) -> ok.
update_progress(Nodes, Fraction) ->
    Progress = [{Node, Fraction} || Node <- lists:usort(Nodes)],
    gen_fsm:send_event(?SERVER, {update_progress, Progress}).
