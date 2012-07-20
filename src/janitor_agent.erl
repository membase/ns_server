%% @author Couchbase <info@couchbase.com>
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
-module(janitor_agent).

-behavior(gen_server).

-include("ns_common.hrl").

-define(WAIT_FOR_MEMCACHED_SECONDS, 5).

-define(APPLY_NEW_CONFIG_TIMEOUT, ns_config_ets_dup:get_timeout(janitor_agent_apply_config, 30000)).
%% NOTE: there's also ns_memcached timeout anyways
-define(DELETE_VBUCKET_TIMEOUT, ns_config_ets_dup:get_timeout(janitor_agent_delete_vbucket, 120000)).

-define(PREPARE_REBALANCE_TIMEOUT, ns_config_ets_dup:get_timeout(janitor_agent_prepare_rebalance, 30000)).

-define(SET_VBUCKET_STATE_TIMEOUT, ns_config_ets_dup:get_timeout(janitor_agent_set_vbucket_state, 30000)).

-define(GET_SRC_DST_REPLICATIONS_TIMEOUT, ns_config_ets_dup:get_timeout(janitor_agent_get_src_dst_replications, 30000)).

-record(state, {bucket_name :: bucket_name(),
                rebalance_pid :: undefined | pid(),
                rebalance_mref :: undefined | reference(),
                last_applied_vbucket_states :: undefined | list(),
                rebalance_only_vbucket_states :: list()}).

-export([wait_for_bucket_creation/2, query_states/3,
         apply_new_bucket_config/6,
         mark_bucket_warmed/2,
         delete_vbucket_copies/4,
         prepare_nodes_for_rebalance/3,
         this_node_replicator_triples/1,
         bulk_set_vbucket_state/4,
         set_vbucket_state/7,
         get_src_dst_vbucket_replications/2,
         get_src_dst_vbucket_replications/3]).

-export([start_link/1, wait_for_memcached_new_style/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

new_style_enabled() ->
    cluster_compat_mode:is_cluster_20().

wait_for_bucket_creation(Bucket, Nodes) ->
    case new_style_enabled() of
        true ->
            NodeRVs = wait_for_memcached_new_style(Nodes, Bucket, up, ?WAIT_FOR_MEMCACHED_SECONDS),
            BadNodes = [N || {N, R} <- NodeRVs,
                             case R of
                                 warming_up -> false;
                                 {ok, _} -> false;
                                 _ -> true
                             end],
            BadNodes;
        false ->
            wait_for_memcached_old_style(Nodes, Bucket, up, ?WAIT_FOR_MEMCACHED_SECONDS)
    end.

-spec wait_for_memcached_old_style([node()], bucket_name(), up | connected, non_neg_integer()) -> [node()].
wait_for_memcached_old_style(Nodes, Bucket, Type, SecondsToWait) when SecondsToWait > 0 ->
    ReadyNodes = ns_memcached:ready_nodes(Nodes, Bucket, Type, default),
    DownNodes = ordsets:subtract(ordsets:from_list(Nodes),
                                 ordsets:from_list(ReadyNodes)),
    case DownNodes of
        [] ->
            [];
        _ ->
            case SecondsToWait - 1 of
                0 ->
                    DownNodes;
                X ->
                    ?log_info("Waiting for ~p on ~p", [Bucket, DownNodes]),
                    timer:sleep(1000),
                    wait_for_memcached_old_style(Nodes, Bucket, Type, X)
            end
    end.

new_style_query_vbucket_states_loop(Node, Bucket, Type) ->
    case (catch gen_server:call(server_name(Bucket, Node), query_vbucket_states, infinity)) of
        {ok, _} = Msg ->
            Msg;
        false ->
            case Type of
                up ->
                    warming_up;
                connected ->
                    new_style_query_vbucket_states_loop_next_step(Node, Bucket, Type)
            end;
        Exc ->
            ?log_debug("Exception from query_vbucket_states of ~p:~p~n~p", [Bucket, Node, Exc]),
            new_style_query_vbucket_states_loop_next_step(Node, Bucket, Type)
    end.

new_style_query_vbucket_states_loop_next_step(Node, Bucket, Type) ->
    ?log_debug("Waiting for ~p on ~p", [Bucket, Node]),
    timer:sleep(1000),
    new_style_query_vbucket_states_loop(Node, Bucket, Type).

-spec wait_for_memcached_new_style([node()], bucket_name(), up | connected, non_neg_integer()) -> [{node(), warming_up | {ok, list()} | any()}].
wait_for_memcached_new_style(Nodes, Bucket, Type, SecondsToWait) ->
    Parent = self(),
    misc:executing_on_new_process(
      fun () ->
              erlang:process_flag(trap_exit, true),
              Ref = make_ref(),
              Me = self(),
              NodePids = [{Node, proc_lib:spawn_link(
                                   fun () ->
                                           timer:kill_after(SecondsToWait * 1000),
                                           RV = new_style_query_vbucket_states_loop(Node, Bucket, Type),
                                           Me ! {'EXIT', self(), {Ref, RV}},
                                           %% Nodes list can be reasonably
                                           %% big. Let's not slow down
                                           %% receive loop below due to
                                           %% extra garbage. It's O(N²)
                                           %% already
                                           erlang:unlink(Me)
                                   end)}
                          || Node <- Nodes],
              [receive
                   {'EXIT', Parent, Reason} ->
                       ?log_debug("Parent died ~p", [Reason]),
                       exit(Reason);
                   {'EXIT', P, Reason} = ExitMsg ->
                       case Reason of
                           {Ref, RV} ->
                               {Node, RV};
                           killed ->
                               {Node, ExitMsg};
                           _ ->
                               ?log_info("Got exception trying to query vbuckets of ~p bucket ~p~n~p", [Node, Bucket, Reason]),
                               {Node, ExitMsg}
                       end
               end || {Node, P} <- NodePids]
      end).


-spec query_states(bucket_name(), [node()], undefined | pos_integer()) -> {ok, [{node(), vbucket_id(), vbucket_state()}], [node()]}.
query_states(Bucket, Nodes, ReadynessWaitTimeout0) ->
    ReadynessWaitTimeout = case ReadynessWaitTimeout0 of
                               undefined -> ?WAIT_FOR_MEMCACHED_SECONDS;
                               _ -> ReadynessWaitTimeout0
                           end,
    case new_style_enabled() of
        true ->
            query_states_new_style(Bucket, Nodes, ReadynessWaitTimeout);
        false ->
            query_states_old_style(Bucket, Nodes, ReadynessWaitTimeout)
    end.

query_states_old_style(Bucket, Nodes, ReadynessWaitTimeout) ->
    BadNodes = wait_for_memcached_old_style(Nodes, Bucket, connected, ReadynessWaitTimeout),
    case BadNodes of
        [] ->
            {Replies, DownNodes} = ns_memcached:list_vbuckets_multi(Nodes, Bucket),
            {GoodReplies, BadReplies} = lists:partition(fun ({_, {ok, _}}) -> true;
                                                            (_) -> false
                                                        end, Replies),
            ErrorNodes = [Node || {Node, _} <- BadReplies],
            States = [{Node, VBucket, State} || {Node, {ok, Reply}} <- GoodReplies,
                                                {VBucket, State} <- Reply],
            {ok, States, ErrorNodes ++ DownNodes};
        _ ->
            {ok, [], BadNodes}
     end.

%% TODO: consider supporting partial janitoring
query_states_new_style(Bucket, Nodes, ReadynessWaitTimeout) ->
    NodeRVs = wait_for_memcached_new_style(Nodes, Bucket, connected, ReadynessWaitTimeout),
    BadNodes = [N || {N, R} <- NodeRVs,
                     case R of
                         {ok, _} -> false;
                         _ -> true
                     end],
    case BadNodes of
        [] ->
            RV = [{Node, VBucket, State}
                  || {Node, {ok, Pairs}} <- NodeRVs,
                     {VBucket, State} <- Pairs],
            {ok, RV, []};
        _ ->
            {ok, [], BadNodes}
    end.

mark_bucket_warmed(Bucket, Nodes) ->
    {Replies, BadNodes} = ns_memcached:mark_warmed(Nodes, Bucket),
    BadReplies = [{N, R} || {N, R} <- Replies,
                            %% unhandled returned by old nodes
                            R =/= ok andalso R =/= unhandled],

    case {BadReplies, BadNodes} of
        {[], []} ->
            ok;
        {_, _} ->
            ?log_error("Failed to mark bucket `~p` as warmed up."
                       "~nBadNodes:~n~p~nBadReplies:~n~p",
                       [Bucket, BadNodes, BadReplies]),
            {error, BadNodes, BadReplies}
    end.

apply_new_bucket_config(Bucket, Servers, Zombies, NewBucketConfig, IgnoredVBuckets, CurrentStates) ->
    case new_style_enabled() of
        true ->
            apply_new_bucket_config_new_style(Bucket, Servers, Zombies, NewBucketConfig, IgnoredVBuckets);
        false ->
            apply_new_bucket_config_old_style(Bucket, Servers, Zombies, NewBucketConfig, IgnoredVBuckets, CurrentStates)
    end.

apply_new_bucket_config_old_style(Bucket, _Servers, [] = _Zombies, NewBucketConfig, IgnoredVBuckets, CurrentStates) ->
    {map, NewMap} = lists:keyfind(map, 1, NewBucketConfig),
    IgnoredSet = sets:from_list(IgnoredVBuckets),
    NeededStates0 = [[{Master, VBucket, active} | [{Replica, VBucket, replica}
                                                   || Replica <- Replicas,
                                                      Replica =/= undefined]]
                     || {VBucket, [Master | Replicas]} <- misc:enumerate(NewMap, 0),
                        not sets:is_element(VBucket, IgnoredSet)],
    NeededStates = lists:sort(lists:append(NeededStates0)),
    FilteredCurrent = lists:sort([Triple
                                  || {_N, VBucket, _State} = Triple <- CurrentStates,
                                     not sets:is_element(VBucket, IgnoredSet)]),
    StatesToSet = ordsets:subtract(NeededStates, FilteredCurrent),
    UsedVBuckets = sets:from_list([{Node, VBucket} || {Node, VBucket, _} <- NeededStates]),
    StatesToDelete = [Triple
                      || {Node, VBucket, _State} = Triple <- FilteredCurrent,
                         not sets:is_element({Node, VBucket}, UsedVBuckets)],

    [ns_memcached:set_vbucket(Node, Bucket, VBucket, State)
     || {Node, VBucket, State} <- StatesToSet,
        Node =/= undefined],

    Replicas = ns_bucket:map_to_replicas(NewMap),
    ns_vbm_sup:set_src_dst_vbucket_replicas(Bucket, Replicas),

    [begin
         case VBucketCurrentState of
             dead ->
                 ok;
             _ ->
                 ns_memcached:set_vbucket(Node, Bucket, VBucket, dead)
         end,
         ns_memcached:delete_vbucket(Node, Bucket, VBucket)
     end || {Node, VBucket, VBucketCurrentState} <- StatesToDelete],
    ok.

apply_new_bucket_config_new_style(Bucket, Servers, [] = Zombies, NewBucketConfig, IgnoredVBuckets) ->
    {Replies, BadNodes} = gen_server:multi_call(Servers -- Zombies, server_name(Bucket),
                                                {apply_new_config, NewBucketConfig, IgnoredVBuckets},
                                                ?APPLY_NEW_CONFIG_TIMEOUT),
    BadReplies = [R || {_, RV} = R<- Replies,
                       RV =/= ok],
    case BadReplies =/= [] orelse BadNodes =/= [] of
        true ->
            ?log_info("~s:Some janitor state change requests have failed:~n~p~n~p", [Bucket, BadReplies, BadNodes]);
        false ->
            ok
    end,
    ok.

-spec do_delete_vbucket_new_style(bucket_name(), pid(), [node()], vbucket_id()) ->
                                         ok | {errors, [{node(), term()}]}.
delete_vbucket_copies(Bucket, RebalancerPid, Nodes, VBucket) ->
    case new_style_enabled() of
        true ->
            do_delete_vbucket_new_style(Bucket, RebalancerPid, Nodes, VBucket);
        false ->
            do_delete_vbucket_old_style(Bucket, Nodes, VBucket)
    end.

do_delete_vbucket_new_style(Bucket, RebalancerPid, Nodes, VBucket) ->
    {Replies, BadNodes} = gen_server:multi_call(Nodes, server_name(Bucket),
                                                {delete_vbucket, RebalancerPid, VBucket},
                                                ?DELETE_VBUCKET_TIMEOUT),
    BadReplies = [R || {_, RV} = R <- Replies,
                       RV =/= ok],
    case BadReplies =/= [] orelse BadNodes =/= [] of
        true ->
            {errors, [{N, bad_node} || N <- BadNodes] ++ BadReplies};
        false ->
            ok
    end.

do_delete_vbucket_old_style(Bucket, Nodes, VBucket) ->
    DeleteRVs = misc:parallel_map(
                  fun (CopyNode) ->
                          {CopyNode, (catch ns_memcached:delete_vbucket(CopyNode, Bucket, VBucket))}
                  end, Nodes, infinity),
    BadDeletes = [P || {_, RV} = P <- DeleteRVs, RV =/= ok],
    case BadDeletes of
        [] ->
            ok;
        _ ->
            {errors, BadDeletes}
    end.

prepare_nodes_for_rebalance(Bucket, Nodes, RebalancerPid) ->
    case new_style_enabled() of
        true ->
            do_prepare_nodes_for_rebalance(Bucket, Nodes, RebalancerPid);
        false ->
            ok
    end.

do_prepare_nodes_for_rebalance(Bucket, Nodes, RebalancerPid) ->
    {RVs, BadNodes} = gen_server:multi_call(Nodes, server_name(Bucket),
                                            {prepare_rebalance, RebalancerPid},
                                            ?PREPARE_REBALANCE_TIMEOUT),
    BadReplies = [{N, no_reply} || N <- BadNodes]
        ++ [Pair || {_N, Reply} = Pair <- RVs,
                    Reply =/= ok],
    case BadReplies of
        [] ->
            ok;
        _ ->
            {failed, BadReplies}
    end.

%% this is only called by
%% failover_safeness_level:build_local_safeness_info_new. Thus old
%% style doesn't have to be supported here.
%%
%% It's also ok to do 'dirty' reads, i.e. outside of janitor agent,
%% because stale data is ok.
this_node_replicator_triples(Bucket) ->
    case new_style_enabled() of
        true -> case replication_changes:get_incoming_replication_map(Bucket) of
                    not_running ->
                        [];
                    List ->
                        [{SrcNode, node(), VBs} || {SrcNode, VBs} <- List]
                end;
        false -> []
    end.

-spec bulk_set_vbucket_state(bucket_name(),
                             pid(),
                             vbucket_id(),
                             [{Node::node(), vbucket_state(), rebalance_vbucket_state(), Src::(node()|undefined)}])
                            -> ok.
bulk_set_vbucket_state(Bucket, RebalancerPid, VBucket, NodeVBucketStateRebalanceStateReplicateFromS) ->
    ?rebalance_info("Doing bulk vbucket ~p state change~n~p", [VBucket, NodeVBucketStateRebalanceStateReplicateFromS]),
    case new_style_enabled() of
        true ->
            RVs = misc:parallel_map(
                    fun ({Node, VBucketState, VBucketRebalanceState, ReplicateFrom}) ->
                            {Node, (catch set_vbucket_state(Bucket, Node, RebalancerPid, VBucket, VBucketState, VBucketRebalanceState, ReplicateFrom))}
                    end, NodeVBucketStateRebalanceStateReplicateFromS, infinity),
            NonOks = [Pair || {_Node, R} = Pair <- RVs,
                              R =/= ok],
            case NonOks of
                [] -> ok;
                _ ->
                    ?rebalance_debug("bulk vbucket state change failed for:~n~p", [NonOks]),
                    erlang:error({bulk_set_vbucket_state_failed, NonOks})
            end;
        false ->
            ns_vbucket_mover:run_code(RebalancerPid,
                                      fun () ->
                                              do_bulk_set_vbucket_state_old_style(RebalancerPid,
                                                                                  Bucket,
                                                                                  VBucket,
                                                                                  NodeVBucketStateRebalanceStateReplicateFromS)
                                      end)
    end.

do_bulk_set_vbucket_state_old_style(RebalancerPid, Bucket, VBucket, NodeVBucketStateRebalanceStateReplicateFromS) ->
    [ns_memcached:set_vbucket(Node, Bucket, VBucket, VBState)
     || {Node, VBState, _, _ReplicateFrom} <- NodeVBucketStateRebalanceStateReplicateFromS],
    DstSrcPairs = [{Node, ReplicateFrom}
                   || {Node, _VBState, _, ReplicateFrom} <- NodeVBucketStateRebalanceStateReplicateFromS],
    ok = ns_vbm_sup:set_vbucket_replications(RebalancerPid, Bucket, VBucket, DstSrcPairs).

set_vbucket_state(Bucket, Node, RebalancerPid, VBucket, VBucketState, VBucketRebalanceState, ReplicateFrom) ->
    ?rebalance_info("Doing vbucket ~p state change: ~p", [VBucket, {Node, VBucketState, VBucketRebalanceState, ReplicateFrom}]), 
    case new_style_enabled() of
        true ->
            ok = gen_server:call(server_name(Bucket, Node),
                                 {update_vbucket_state, RebalancerPid,
                                  VBucket, VBucketState, VBucketRebalanceState, ReplicateFrom},
                                ?SET_VBUCKET_STATE_TIMEOUT);
        false ->
            bulk_set_vbucket_state(Bucket, RebalancerPid, VBucket, [{Node, VBucketState, VBucketRebalanceState, ReplicateFrom}])
    end.

get_src_dst_vbucket_replications(Bucket, Nodes) ->
    get_src_dst_vbucket_replications(Bucket, Nodes, ?GET_SRC_DST_REPLICATIONS_TIMEOUT).

get_src_dst_vbucket_replications(Bucket, Nodes, Timeout) ->
    case new_style_enabled() of
        true ->
            {OkResults, FailedNodes} =
                gen_server:multi_call(Nodes, server_name(Bucket),
                                      get_incoming_replication_map,
                                      Timeout),
            Replications = [{Src, Dst, VB}
                            || {Dst, Pairs} <- OkResults,
                               {Src, VBs} <- Pairs,
                               VB <- VBs],
            {lists:sort(Replications), FailedNodes};
        false ->
            {lists:sort(ns_vbm_sup:replicators(Nodes, Bucket)), []}
    end.

server_name(Bucket, Node) ->
    {server_name(Bucket), Node}.

%% ----------- implementation -----------

start_link(Bucket) ->
    gen_server:start_link({local, server_name(Bucket)}, ?MODULE, Bucket, []).

init(BucketName) ->
    {ok, #state{bucket_name = BucketName}}.

handle_call(query_vbucket_states, _From, #state{bucket_name = BucketName} = State) ->
    %% NOTE: uses 'outer' memcached timeout of 60 seconds
    RV = (catch ns_memcached:local_connected_and_list_vbuckets(BucketName)),
    {reply, RV, State};
handle_call(get_incoming_replication_map, _From, #state{bucket_name = BucketName} = State) ->
    %% NOTE: has infinite timeouts but uses only local communication
    RV = replication_changes:get_incoming_replication_map(BucketName),
    {reply, RV, State};
handle_call({prepare_rebalance, _Pid}, _From,
            #state{last_applied_vbucket_states = undefined} = State) ->
    {reply, no_vbucket_states_set, State};
handle_call({prepare_rebalance, Pid}, _From,
            #state{bucket_name = BucketName} = State) ->
    ns_vbm_sup:kill_all_local_children(BucketName),
    State1 = State#state{rebalance_only_vbucket_states = [undefined || _ <- State#state.rebalance_only_vbucket_states]},
    {reply, ok, set_rebalance_mref(Pid, State1)};
handle_call({update_vbucket_state, Pid, _VBucket, _NormaState, _RebalanceState}, _From,
            #state{rebalance_pid = RPid} = State) when Pid =/= RPid ->
    {reply, wrong_rebalancer_pid, State};
handle_call({update_vbucket_state, _Pid, VBucket, NormalState, RebalanceState, ReplicateFrom}, _From,
            #state{bucket_name = BucketName,
                   last_applied_vbucket_states = WantedVBuckets,
                   rebalance_only_vbucket_states = RebalanceVBuckets} = State) ->
    NewWantedVBuckets = update_list_nth(VBucket + 1, WantedVBuckets, NormalState),
    NewRebalanceVBuckets = update_list_nth(VBucket + 1, RebalanceVBuckets, RebalanceState),
    NewState = State#state{last_applied_vbucket_states = NewWantedVBuckets,
                           rebalance_only_vbucket_states = NewRebalanceVBuckets},
    %% TODO: consider infinite timeout. It's local memcached after all
    ok = ns_memcached:set_vbucket(BucketName, VBucket, NormalState),
    CurrentReps = replication_changes:get_incoming_replication_map(BucketName),
    CurrentReps0 = [{Node, ordsets:del_element(VBucket, VBuckets)}
                    || {Node, VBuckets} <- CurrentReps],
    DesiredReps = case ReplicateFrom of
                      undefined ->
                          CurrentReps0;
                      _ ->
                          misc:ukeymergewith(fun ({Node, VBucketsA}, {_, VBucketsB}) ->
                                                     {Node, ordsets:union(VBucketsA, VBucketsB)}
                                             end, 1,
                                             CurrentReps0, [{ReplicateFrom, [VBucket]}])
                  end,
    ok = replication_changes:set_incoming_replication_map(BucketName, DesiredReps),
    {reply, ok, pass_vbucket_states_to_set_view_manager(NewState)};
handle_call({apply_new_config, NewBucketConfig, IgnoredVBuckets}, _From, #state{bucket_name = BucketName} = State) ->
    ns_vbm_sup:kill_all_local_children(BucketName),
    %% ?log_debug("handling apply_new_config:~n~p", [NewBucketConfig]),
    {ok, CurrentVBucketsList} = ns_memcached:list_vbuckets(BucketName),
    CurrentVBuckets = dict:from_list(CurrentVBucketsList),
    Map = proplists:get_value(map, NewBucketConfig),
    true = (Map =/= undefined),
    %% TODO: unignore ignored vbuckets
    [] = IgnoredVBuckets,
    {_, ToSet, ToDelete, NewWantedRev}
        = lists:foldl(
            fun (Chain, {VBucket, ToSet, ToDelete, PrevWanted}) ->
                    WantedState = case [Pos || {Pos, N} <- misc:enumerate(Chain, 0),
                                               N =:= node()] of
                                      [0] ->
                                          active;
                                      [_] ->
                                          replica;
                                      [] ->
                                          missing
                                  end,
                    ActualState = case dict:find(VBucket, CurrentVBuckets) of
                                      {ok, S} -> S;
                                      _ -> missing
                                  end,
                    NewWanted = [WantedState | PrevWanted],
                    case WantedState =:= ActualState of
                        true ->
                            {VBucket + 1, ToSet, ToDelete, NewWanted};
                        false ->
                            case WantedState of
                                missing ->
                                    {VBucket + 1, ToSet, [VBucket | ToDelete], NewWanted};
                                _ ->
                                    {VBucket + 1, [{VBucket, WantedState} | ToSet], ToDelete, NewWanted}
                            end
                    end
            end, {0, [], [], []}, Map),
    [ns_memcached:set_vbucket(BucketName, VBucket, StateToSet)
     || {VBucket, StateToSet} <- ToSet],
    WantedReplicas = [{Src, VBucket} || {Src, Dst, VBucket} <- ns_bucket:map_to_replicas(Map),
                                        Dst =:= node()],
    WantedReplications = [{Src, [VB || {_, VB} <- Pairs]}
                          || {Src, Pairs} <- misc:keygroup(1, lists:sort(WantedReplicas))],
    ok = replication_changes:set_incoming_replication_map(BucketName, WantedReplications),
    [case dict:find(VBucket, CurrentVBuckets) of
         {ok, dead} ->
             ns_memcached:set_vbucket(BucketName, VBucket, dead),
             ns_memcached:delete_vbucket(BucketName, VBucket);
         _ ->
             ns_memcached:delete_vbucket(BucketName, VBucket)
     end || VBucket <- ToDelete],
    NewWanted = lists:reverse(NewWantedRev),
    NewRebalance = [undefined || _ <- NewWantedRev],
    State2 = State#state{last_applied_vbucket_states = NewWanted,
                         rebalance_only_vbucket_states = NewRebalance},
    State3 = set_rebalance_mref(undefined, State2),
    {reply, ok, pass_vbucket_states_to_set_view_manager(State3)};
handle_call({delete_vbucket, RebalancerPid, VBucket}, _From, #state{bucket_name = BucketName,
                                                                    rebalance_pid = RealRebalancerPid} = State) ->
    case RebalancerPid =:= RealRebalancerPid of
        true ->
            {reply, ok = ns_memcached:delete_vbucket(BucketName, VBucket), State};
        false ->
            {reply, wrong_rebalancer_pid, State}
    end.

handle_cast(_, _State) ->
    erlang:error(cannot_do).

handle_info({'DOWN', MRef, _, _, _}, #state{rebalance_mref = RMRef,
                                            last_applied_vbucket_states = WantedVBuckets} = State)
  when MRef =:= RMRef ->
    ?log_info("Undoing temporary vbucket states caused by rebalance"),
    State2 = State#state{rebalance_only_vbucket_states = [undefined
                                                          || _ <- WantedVBuckets]},
    State3 = set_rebalance_mref(undefined, State2),
    {noreply, pass_vbucket_states_to_set_view_manager(State3)};
handle_info(Info, State) ->
    ?log_debug("Ignoring unexpected message: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

server_name(Bucket) ->
    list_to_atom("janitor_agent-" ++ Bucket).

pass_vbucket_states_to_set_view_manager(#state{bucket_name = BucketName,
                                               last_applied_vbucket_states = WantedVBuckets,
                                               rebalance_only_vbucket_states = RebalanceVBuckets} = State) ->
    ok = capi_set_view_manager:set_vbucket_states(BucketName,
                                                  WantedVBuckets,
                                                  RebalanceVBuckets),
    State.

set_rebalance_mref(Pid, State0) ->
    case State0#state.rebalance_mref of
        undefined ->
            ok;
        OldMRef ->
            erlang:demonitor(OldMRef, [flush])
    end,
    State = State0#state{rebalance_pid = Pid},
    case Pid of
        undefined ->
            State#state{rebalance_mref = undefined};
        _ ->
            State#state{rebalance_mref = erlang:monitor(process, Pid)}
    end.

update_list_nth(Index, List, Value) ->
    Tuple = list_to_tuple(List),
    Tuple2 = setelement(Index, Tuple, Value),
    tuple_to_list(Tuple2).
