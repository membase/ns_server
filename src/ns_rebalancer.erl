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
-module(ns_rebalancer).

-include("ns_common.hrl").

-type histogram() :: [{atom(), non_neg_integer()}].
-type map() :: [[atom()]].
-type move_counts() :: [{atom(), non_neg_integer()}].
-type moves() :: [{non_neg_integer(), atom(), atom()}].

-export([failover/2, rebalance/5, unbalanced/2]).


%%
%% API
%%

-spec failover(string(), atom()) -> ok.
failover(Bucket, Node) ->
    {_, _, Map, Servers} = ns_bucket:config(Bucket),
    %% Promote replicas of vbuckets on this node
    Map1 = promote_replicas(Bucket, Map, [Node]),
    ns_bucket:set_map(Bucket, Map1),
    ns_bucket:set_servers(Bucket, lists:delete(Node, Servers)),
    lists:foreach(fun (N) ->
                          ns_vbm_sup:kill_dst_children(N, Bucket, Node)
                  end, lists:delete(Node, Servers)).


-spec rebalance(string(), [atom()], [atom()], map(), non_neg_integer()) -> ok.
rebalance(Bucket, KeepNodes, EjectNodes, Map, Tries) ->
    try
        ns_config:set(rebalance_status, running),
        AllNodes = KeepNodes ++ EjectNodes,
        ns_orchestrator:reset_progress(),
        ns_orchestrator:update_progress(AllNodes, 0.0),
        ns_bucket:set_servers(Bucket, AllNodes),
        AliveNodes = ns_node_disco:nodes_actual_proper(),
        RemapNodes = EjectNodes -- AliveNodes, % No active node, promote a replica
        lists:foreach(fun (N) -> ns_cluster:leave(N) end, RemapNodes),
        maybe_stop(),
        EvacuateNodes = EjectNodes -- RemapNodes, % Nodes we can move data off of
        Map1 = promote_replicas(Bucket, Map, RemapNodes),
        ns_bucket:set_map(Bucket, Map1),
        ns_orchestrator:update_progress(RemapNodes, 1.0),
        maybe_stop(),
        Histograms1 = histograms(Map1, KeepNodes),
        Moves1 = master_moves(Bucket, EvacuateNodes, Map1, Histograms1),
        ns_orchestrator:starting_moves(count_moves(Moves1)),
        Map2 = perform_moves(Bucket, Map1, Moves1),
        ns_orchestrator:update_progress(EvacuateNodes, 1.0),
        maybe_stop(),
        Histograms2 = histograms(Map2, KeepNodes),
        Moves2 = balance_nodes(Bucket, Map2, Histograms2, 1),
        ns_orchestrator:starting_moves(count_moves(Moves2)),
        Map3 = perform_moves(Bucket, Map2, Moves2),
        ns_orchestrator:update_progress(KeepNodes, 0.9),
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
                    ?log_warning("Rebalance received exit: ~p, retrying.",
                                 [Reason]),
                    timer:sleep(1500),
                    rebalance(Bucket, KeepNodes, EjectNodes, Map, Tries - 1)
            end
    end.


%% returns true iff the max vbucket count in any class on any server is >2 more than the min
-spec unbalanced(map(), [atom()]) -> boolean().
unbalanced(Map, Servers) ->
    lists:any(fun (Histogram) ->
                      case [N || {_, N} <- Histogram] of
                          [] -> false;
                          Counts -> lists:max(Counts) - lists:min(Counts) > 2
                      end
              end, histograms(Map, Servers)).


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


-spec count_moves(moves()) -> move_counts().
count_moves(Moves) ->
    M = lists:flatmap(fun ({_, Old, New}) -> [Old, New] end, Moves),
    misc:uniqc(lists:sort([N || N <- M, N /= undefined])).


%% Ensure there are replicas for any unreplicated buckets if we stop
fixup_replicas(Bucket, KeepNodes, EjectNodes) ->
    {_, _, Map, _} = ns_bucket:config(Bucket),
    Histograms = histograms(Map, KeepNodes),
    Map1 = new_replicas(Bucket, EjectNodes, Map, Histograms),
    ns_bucket:set_servers(Bucket, KeepNodes ++ EjectNodes),
    ns_bucket:set_map(Bucket, Map1).


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


-spec master_moves(string(), [atom()], map(), [histogram()]) -> moves().
master_moves(Bucket, EvacuateNodes, Map, Histograms) ->
    master_moves(Bucket, EvacuateNodes, Map, Histograms, 0, []).

-spec master_moves(string(), [atom()], map(), [histogram()], non_neg_integer(),
                   moves()) -> moves().
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


-spec maybe_stop() -> ok | no_return().
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
    ns_orchestrator:remaining_moves(count_moves(Remaining)),
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
