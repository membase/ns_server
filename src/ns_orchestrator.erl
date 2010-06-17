%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% Monitor and maintain the vbucket layout of each bucket.
%% There is one of these per bucket.

-module(ns_orchestrator).

-behaviour(gen_server).

%% Constants and definitions

-define(INTERVAL, 5000).

-record(state, {bucket, janitor, rebalancer, rebalance_progress}).

%% API
-export([start_link/1]).

-export([needs_rebalance/1, rebalance_progress/1, start_rebalance/3, stop_rebalance/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

%% API
start_link(Bucket) ->
    gen_server:start_link(server(Bucket), ?MODULE, Bucket, []).

needs_rebalance(Bucket) ->
    {_NumReplicas, _NumVBuckets, Map, Servers} = ns_bucket:config(Bucket),
    lists:any(fun (N) -> N == undefined end, lists:append(Map)) orelse
        unbalanced(histograms(Map, Servers)).

rebalance_progress(Bucket) ->
    gen_server:call(server(Bucket), rebalance_progress).

start_rebalance(Bucket, KeepNodes, EjectNodes) ->
    gen_server:call(server(Bucket), {start_rebalance, KeepNodes, EjectNodes}).

stop_rebalance(Bucket) ->
    gen_server:call(server(Bucket), stop_rebalance).

%% gen_server callbacks
init(Bucket) ->
    {ok, #state{bucket=Bucket}}.

handle_call(rebalance_progress, _from, State = #state{rebalance_progress = Progress}) ->
    {reply, Progress, State};
handle_call(rebalance_status, _From, State = #state{rebalancer=undefined}) ->
    {reply, not_running, State};
handle_call(rebalance_status, _From, State) ->
    {reply, running, State};
handle_call({start_rebalance, KeepNodes, EjectNodes}, _From, State = #state{bucket=Bucket, rebalancer=undefined}) ->
    {_NumReplicas, _NumVBuckets, Map, Servers} = ns_bucket:config(Bucket),
    Histograms = histograms(Map, Servers),
    case {lists:sort(Servers), lists:sort(KeepNodes), EjectNodes,
          unbalanced(Histograms)} of
        {S, S, [], false} ->
            {reply, already_balanced, State};
        _ ->
            {ok, Pid, Ref} = misc:spawn_link_safe(fun () -> do_rebalance(Bucket, KeepNodes, EjectNodes, Map) end),
            {reply, ok, State#state{rebalancer={Pid, Ref}, rebalance_progress=undefined}}
    end;
handle_call({start_rebalance, _, _}, _From, State) ->
    {reply, in_progress, State};
handle_call(stop_rebalance, _From, State = #state{rebalancer={Pid, Ref}}) ->
    Pid ! stop,
    Reply = receive {Ref, Reason} -> Reason end,
    {reply, Reply, State#state{rebalancer=undefined}};
handle_call(stop_rebalance, _From, State) ->
    {reply, not_rebalancing, State};
handle_call(Request, From, State) ->
    error_logger:info_msg("~p:handle_call(~p, ~p, ~p)~n",
                          [?MODULE, Request, From, State]),
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(Msg, State) ->
    error_logger:info_msg("~p:handle_cast(~p, ~p)~n",
                          [?MODULE, Msg, State]),
    {noreply, State}.

handle_info({rebalance_progress, Progress}, State) ->
    {noreply, State#state{rebalance_progress = Progress}};
handle_info(Msg, State) ->
    error_logger:info_msg("~p:handle_info(~p, ~p)~n",
                          [?MODULE, Msg, State]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Internal functions
assign(Histogram, AvoidNodes) ->
    Histogram1 = lists:keysort(2, Histogram),
    case lists:splitwith(fun ({N, _}) -> lists:member(N, AvoidNodes) end, Histogram1) of
        {Head, [{Node, N}|Rest]} ->
            {Node, Head ++ [{Node, N+1}|Rest]};
        {_, []} ->
            {undefined, Histogram1}
    end.

do_rebalance(Bucket, KeepNodes, EjectNodes, Map) ->
    AliveNodes = ns_node_disco:nodes_actual_proper(),
    RemapNodes = EjectNodes -- AliveNodes, % No active node, promote a replica
    lists:foreach(fun (N) -> ns_cluster:shun(N) end, RemapNodes),
    EvacuateNodes = EjectNodes -- RemapNodes, % Nodes we can move data off of
    error_logger:info_msg("~p:do_rebalance(~p, ~p, ~p, ~p):~nAliveNodes = ~p, RemapNodes = ~p, EvacuateNodes = ~p~n",
                          [?MODULE, Bucket, KeepNodes, EjectNodes, Map, AliveNodes, RemapNodes, EvacuateNodes]),
    Map1 = [promote_replicas(Bucket, V, RemapNodes, Chain) ||
               {V, Chain} <- misc:enumerate(Map, 0)],
    Histograms1 = histograms(Map1, KeepNodes),
    error_logger:info_msg("~p:do_rebalance(~p, ~p, ~p, ~p):~nMap1 = ~p~nHistograms1 = ~p~n",
                          [?MODULE, Bucket, KeepNodes, EjectNodes, Map, Map1, Histograms1]),
    {Map2, Histograms2} = evacuate_masters(Bucket, EvacuateNodes, Map1, Histograms1),
    error_logger:info_msg("~p:do_rebalance(~p, ~p, ~p, ~p):~nMap2 = ~p~nHistograms2 = ~p~n",
                          [?MODULE, Bucket, KeepNodes, EjectNodes, Map, Map2, Histograms2]),
    {Map3, _} = move_replicas(Bucket, EjectNodes, Map2, Histograms2),
    lists:foreach(fun (N) -> ns_cluster:shun(N) end, EvacuateNodes),
    ns_bucket:set_servers(Bucket, KeepNodes),
    ns_bucket:set_map(Bucket, Map3),
    ns_janitor:cleanup(Bucket, Map3, KeepNodes).

evacuate_masters(Bucket, EvacuateNodes, Map, Histograms) ->
    evacuate_masters(Bucket, EvacuateNodes, Map, Histograms, 0, []).

evacuate_masters(_, _, [], Histograms, _, NewMapReversed) ->
    {lists:reverse(NewMapReversed), Histograms};
evacuate_masters(Bucket, EvacuateNodes, [Chain|MapTail], Histograms, V, NewMapReversed) ->
    [OldMaster|Replicas] = Chain,
    {Chain1, Histograms1} =
        case {OldMaster, lists:member(OldMaster, EvacuateNodes)} of
            {undefined, _} ->
                [MasterHistogram|ReplicaHistograms] = Histograms,
                {NewMaster, MasterHistogram1} = assign(MasterHistogram, Chain),
                {[NewMaster|Replicas], [MasterHistogram1|ReplicaHistograms]};
            {_, true} ->
                [MasterHistogram|ReplicaHistograms] = Histograms,
                {NewMaster, MasterHistogram1} = assign(MasterHistogram, Chain),
                ok = ns_vbm_sup:move(Bucket, V, OldMaster, NewMaster),
                {[NewMaster|Replicas], [MasterHistogram1|ReplicaHistograms]};
            {_, false} ->
                {Chain, Histograms}
        end,
    evacuate_masters(Bucket, EvacuateNodes, MapTail, Histograms1, V+1, [Chain1|NewMapReversed]).

move_replicas(Bucket, EjectNodes, Map, Histograms) ->
    move_replicas(Bucket, EjectNodes, Map, Histograms, 0, []).

move_replicas(_, _, [], Histograms, _, NewMapReversed) ->
    {lists:reverse(NewMapReversed), Histograms};
move_replicas(Bucket, EjectNodes, [Chain|MapTail], Histograms, V, NewMapReversed) ->
    %% Split off the masters - we don't want to move them!
    {[Master|Replicas], [MHist|RHists]} = {Chain, Histograms},
    ChainHist = lists:zip(Replicas, RHists),
    {Replicas1, RHists1} =
        lists:unzip(
          lists:map(fun ({undefined, Histogram}) ->
                            assign(Histogram, Chain ++ EjectNodes);
                        (X = {OldNode, Histogram}) ->
                            case lists:member(OldNode, EjectNodes) of
                                true ->
                                    assign(Histogram, Chain ++ EjectNodes);
                                false ->
                                    X
                            end
                    end, ChainHist)),
    move_replicas(Bucket, EjectNodes, MapTail, [MHist|RHists1], V + 1, [[Master|Replicas1]|NewMapReversed]).

promote_replicas(Bucket, V, RemapNodes, Chain) ->
    [OldMaster|_] = Chain,
    NotBad = fun (Node) -> not lists:member(Node, RemapNodes) end,
    NewChain = lists:takewhile(NotBad, lists:dropwhile(NotBad, RemapNodes)), % TODO garbage collect orphaned pending buckets later
    NewChainExtended = NewChain ++ lists:duplicate(length(Chain) - length(NewChain), undefined),
    case NewChainExtended of
        [OldMaster|_] ->
            %% No need to promote
            NewChainExtended;
        [undefined|_] ->
            error_logger:error_msg("~p:promote_replicas(~p, ~p, ~p, ~p): No master~n", [?MODULE, Bucket, V, RemapNodes, Chain]),
            NewChainExtended;
        [_|_] ->
            NewChainExtended
    end.

histograms(Map, Servers) ->
    Histograms = [lists:keydelete(undefined, 1, misc:uniqc(lists:sort(L))) || L <- misc:rotate(Map)],
    lists:map(fun (H) ->
                      Missing = [{N, 0} || N <- Servers, not lists:keymember(N, 1, H)],
                      Missing ++ H
              end, Histograms).

server(Bucket) ->
    {global, list_to_atom(lists:flatten(io_lib:format("~s-~s", [?MODULE, Bucket])))}.

%% returns true iff the max vbucket count in any class on any server is >2 more than the min
unbalanced(Histograms) ->
    case [N || Histogram <- Histograms, {_, N} <- Histogram] of
        [] -> true;
        Counts -> lists:max(Counts) - lists:min(Counts) > 2
    end.
