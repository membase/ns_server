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

-define(PREPARE_FLUSH_TIMEOUT, ns_config_ets_dup:get_timeout(janitor_agent_prepare_flush, 30000)).

-define(SET_VBUCKET_STATE_TIMEOUT, infinity).

-define(GET_SRC_DST_REPLICATIONS_TIMEOUT, ns_config_ets_dup:get_timeout(janitor_agent_get_src_dst_replications, 30000)).

-record(state, {bucket_name :: bucket_name(),
                rebalance_pid :: undefined | pid(),
                rebalance_mref :: undefined | reference(),
                rebalance_subprocesses = [] :: [{From :: term(), Worker :: pid()}],
                last_applied_vbucket_states :: undefined | list(),
                rebalance_only_vbucket_states :: list(),
                flushseq}).

-export([wait_for_bucket_creation/2, query_states/3,
         apply_new_bucket_config/5,
         mark_bucket_warmed/2,
         delete_vbucket_copies/4,
         prepare_nodes_for_rebalance/3,
         this_node_replicator_triples/1,
         bulk_set_vbucket_state/4,
         set_vbucket_state/7,
         get_src_dst_vbucket_replications/2,
         get_src_dst_vbucket_replications/3,
         initiate_indexing/5,
         wait_index_updated/5,
         create_new_checkpoint/4,
         mass_prepare_flush/2,
         complete_flush/3,
         get_replication_persistence_checkpoint_id/4,
         wait_checkpoint_persisted/5,
         get_tap_docs_estimate/4,
         get_tap_docs_estimate_many_taps/4,
         get_mass_tap_docs_estimate/3,
         wait_upr_data_move/5]).

-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

wait_for_bucket_creation(Bucket, Nodes) ->
    NodeRVs = wait_for_memcached(Nodes, Bucket, up, ?WAIT_FOR_MEMCACHED_SECONDS),
    BadNodes = [N || {N, R} <- NodeRVs,
                     case R of
                         warming_up -> false;
                         {ok, _} -> false;
                         _ -> true
                     end],
    BadNodes.

query_vbucket_states_loop(Node, Bucket, Type) ->
    case (catch gen_server:call(server_name(Bucket, Node), query_vbucket_states, infinity)) of
        {ok, _} = Msg ->
            Msg;
        false ->
            case Type of
                up ->
                    warming_up;
                connected ->
                    query_vbucket_states_loop_next_step(Node, Bucket, Type)
            end;
        Exc ->
            ?log_debug("Exception from query_vbucket_states of ~p:~p~n~p", [Bucket, Node, Exc]),
            query_vbucket_states_loop_next_step(Node, Bucket, Type)
    end.

query_vbucket_states_loop_next_step(Node, Bucket, Type) ->
    ?log_debug("Waiting for ~p on ~p", [Bucket, Node]),
    timer:sleep(1000),
    query_vbucket_states_loop(Node, Bucket, Type).

-spec wait_for_memcached([node()], bucket_name(), up | connected, non_neg_integer()) -> [{node(), warming_up | {ok, list()} | any()}].
wait_for_memcached(Nodes, Bucket, Type, SecondsToWait) ->
    Parent = self(),
    misc:executing_on_new_process(
      fun () ->
              erlang:process_flag(trap_exit, true),
              Ref = make_ref(),
              Me = self(),
              NodePids = [{Node, proc_lib:spawn_link(
                                   fun () ->
                                           {ok, TRef} = timer2:kill_after(SecondsToWait * 1000),
                                           RV = query_vbucket_states_loop(Node, Bucket, Type),
                                           Me ! {'EXIT', self(), {Ref, RV}},
                                           %% doing cancel is quite
                                           %% important. kill_after is
                                           %% not automagically
                                           %% canceled
                                           timer2:cancel(TRef),
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


complete_flush(Bucket, Nodes, Timeout) ->
    {Replies, BadNodes} = gen_server:multi_call(Nodes, server_name(Bucket), complete_flush, Timeout),
    {GoodReplies, BadReplies} = lists:partition(fun ({_N, R}) -> R =:= ok end, Replies),
    GoodNodes = [N || {N, _R} <- GoodReplies],
    {GoodNodes, BadReplies, BadNodes}.

%% TODO: consider supporting partial janitoring
-spec query_states(bucket_name(), [node()], undefined | pos_integer()) -> {ok, [{node(), vbucket_id(), vbucket_state()}], [node()]}.
query_states(Bucket, Nodes, undefined) ->
    query_states(Bucket, Nodes, ?WAIT_FOR_MEMCACHED_SECONDS);
query_states(Bucket, Nodes, ReadynessWaitTimeout) ->
    NodeRVs = wait_for_memcached(Nodes, Bucket, connected, ReadynessWaitTimeout),
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

-spec mark_bucket_warmed(Bucket::bucket_name(), [node()]) -> ok | {error, [node()], list()}.
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

process_apply_config_rv(Bucket, {Replies, BadNodes}, Call) ->
    BadReplies = [R || {_, RV} = R <- Replies,
                       RV =/= ok],
    case BadReplies =/= [] orelse BadNodes =/= [] of
        true ->
            ?log_info("~s:Some janitor state change requests (~p) have failed:~n~p~n~p", [Bucket, Call, BadReplies, BadNodes]),
            FailedNodes = [N || {N, _} <- BadReplies] ++ BadNodes,
            {error, {failed_nodes, FailedNodes}};
        false ->
            ok
    end.

apply_new_bucket_config(Bucket, Servers, [] = Zombies, NewBucketConfig, IgnoredVBuckets) ->
    case cluster_compat_mode:get_replication_topology() of
        star ->
            apply_new_bucket_config_star(Bucket, Servers, Zombies,
                                                   NewBucketConfig, IgnoredVBuckets);
        chain ->
            apply_new_bucket_config_chain(Bucket, Servers, Zombies,
                                                    NewBucketConfig, IgnoredVBuckets)
    end.

apply_new_bucket_config_chain(Bucket, Servers, Zombies, NewBucketConfig, IgnoredVBuckets) ->
    RV1 = gen_server:multi_call(Servers -- Zombies, server_name(Bucket),
                                {apply_new_config, NewBucketConfig, IgnoredVBuckets},
                                ?APPLY_NEW_CONFIG_TIMEOUT),
    case process_apply_config_rv(Bucket, RV1, apply_new_config) of
        ok ->
            RV2 = gen_server:multi_call(Servers -- Zombies, server_name(Bucket),
                                        {apply_new_config_replicas_phase, NewBucketConfig, IgnoredVBuckets},
                                        ?APPLY_NEW_CONFIG_TIMEOUT),
            process_apply_config_rv(Bucket, RV2, apply_new_config_replicas_phase);
        Other ->
            Other
    end.

apply_new_bucket_config_star(Bucket, Servers, Zombies, NewBucketConfig, IgnoredVBuckets) ->
    Map = proplists:get_value(map, NewBucketConfig),
    true = (Map =/= undefined),
    NumVBuckets = proplists:get_value(num_vbuckets, NewBucketConfig),
    true = is_integer(NumVBuckets),

    %% Since apply_new_config and apply_new_config_replica_phase calls expect
    %% vbucket maps and not the actual changes that has to be applied, we need
    %% to involve some trickery here. For every node we build something that
    %% looks like vbucket map. Map chain for a vbucket on master node looks
    %% like this [node]. This ensures that apply_new_config sets this vbucket
    %% to active on the node. Map chain for a replica vbucket looks like
    %% [master_node, replica_node] for every replica node. This ensures that
    %% apply_new_config sets the vbucket to replica state on replica_node and
    %% that apply_new_config_replica_phase sets up the replication correctly.
    AliveServers = Servers -- Zombies,
    NodeMaps0 = dict:from_list(
                  [{N, array:new([{size, NumVBuckets},
                                  {default, [undefined]}])} || N <- AliveServers]),

    NodeMaps1 =
        lists:foldl(
          fun ({VBucket, [Master | Replicas]}, Acc) ->
                  Acc1 = case lists:member(Master, AliveServers) of
                             true ->
                                 NodeMap0 = dict:fetch(Master, Acc),
                                 NodeMap1 = array:set(VBucket, [Master], NodeMap0),
                                 dict:store(Master, NodeMap1, Acc);
                             false ->
                                 Acc
                         end,

                  lists:foldl(
                    fun (Dst, Acc2) ->
                            case lists:member(Dst, AliveServers) of
                                true ->
                                    NodeMap2 = dict:fetch(Dst, Acc2),
                                    %% note that master may be undefined here;
                                    NodeMap3 = array:set(VBucket, [Master, Dst], NodeMap2),
                                    dict:store(Dst, NodeMap3, Acc2);
                                false ->
                                    Acc2
                            end
                    end, Acc1, Replicas)
          end, NodeMaps0, misc:enumerate(Map, 0)),

    NodeMaps = dict:map(
                 fun (_, NodeMapArr) ->
                         lists:keystore(map, 1, NewBucketConfig, {map, array:to_list(NodeMapArr)})
                 end, NodeMaps1),

    RV1 = misc:parallel_map(
            fun (Node) ->
                    {Node, catch gen_server:call({server_name(Bucket), Node},
                                                 {apply_new_config,
                                                  dict:fetch(Node, NodeMaps),
                                                  IgnoredVBuckets},
                                                 ?APPLY_NEW_CONFIG_TIMEOUT)}
            end, AliveServers, infinity),
    case process_apply_config_rv(Bucket, {RV1, []}, apply_new_config) of
        ok ->
            RV2 = misc:parallel_map(
                    fun (Node) ->
                            {Node,
                             catch gen_server:call({server_name(Bucket), Node},
                                                   {apply_new_config_replicas_phase,
                                                    dict:fetch(Node, NodeMaps),
                                                    IgnoredVBuckets},
                                                   ?APPLY_NEW_CONFIG_TIMEOUT)}
                    end, AliveServers, infinity),
            process_apply_config_rv(Bucket, {RV2, []}, apply_new_config_replicas_phase);
        Other ->
            Other
    end.

-spec delete_vbucket_copies(bucket_name(), pid(), [node()], vbucket_id()) ->
                                   ok | {errors, [{node(), term()}]}.
delete_vbucket_copies(Bucket, RebalancerPid, Nodes, VBucket) ->
    {Replies, BadNodes} = gen_server:multi_call(Nodes, server_name(Bucket),
                                                {if_rebalance, RebalancerPid,
                                                 {delete_vbucket, VBucket}},
                                                ?DELETE_VBUCKET_TIMEOUT),
    BadReplies = [R || {_, RV} = R <- Replies,
                       RV =/= ok],
    case BadReplies =/= [] orelse BadNodes =/= [] of
        true ->
            {errors, [{N, bad_node} || N <- BadNodes] ++ BadReplies};
        false ->
            ok
    end.

prepare_nodes_for_rebalance(Bucket, Nodes, RebalancerPid) ->
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
%% failover_safeness_level:build_local_safeness_info_new.
%%
%% It's also ok to do 'dirty' reads, i.e. outside of janitor agent,
%% because stale data is ok.
this_node_replicator_triples(Bucket) ->
    case replication_manager:get_incoming_replication_map(Bucket) of
        not_running ->
            [];
        List ->
            [{SrcNode, node(), VBs} || {SrcNode, VBs} <- List]
    end.

-spec bulk_set_vbucket_state(bucket_name(),
                             pid(),
                             vbucket_id(),
                             [{Node::node(), vbucket_state(), rebalance_vbucket_state(), Src::(node()|undefined)}])
                            -> ok.
bulk_set_vbucket_state(Bucket, RebalancerPid, VBucket, NodeVBucketStateRebalanceStateReplicateFromS) ->
    ?rebalance_info("Doing bulk vbucket ~p state change~n~p", [VBucket, NodeVBucketStateRebalanceStateReplicateFromS]),
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
    end.

set_vbucket_state(Bucket, Node, RebalancerPid, VBucket, VBucketState, VBucketRebalanceState, ReplicateFrom) ->
    ?rebalance_info("Doing vbucket ~p state change: ~p", [VBucket, {Node, VBucketState, VBucketRebalanceState, ReplicateFrom}]),
    ok = gen_server:call(server_name(Bucket, Node),
                         {if_rebalance, RebalancerPid,
                          {update_vbucket_state,
                           VBucket, VBucketState, VBucketRebalanceState, ReplicateFrom}},
                         ?SET_VBUCKET_STATE_TIMEOUT).

get_src_dst_vbucket_replications(Bucket, Nodes) ->
    get_src_dst_vbucket_replications(Bucket, Nodes, ?GET_SRC_DST_REPLICATIONS_TIMEOUT).

get_src_dst_vbucket_replications(Bucket, Nodes, Timeout) ->
    {OkResults, FailedNodes} =
        gen_server:multi_call(Nodes, server_name(Bucket),
                              get_incoming_replication_map,
                              Timeout),
    Replications = [{Src, Dst, VB}
                    || {Dst, Pairs} <- OkResults,
                       {Src, VBs} <- Pairs,
                       VB <- VBs],
    {lists:sort(Replications), FailedNodes}.

initiate_indexing(_Bucket, _Rebalancer, [] = _MaybeMaster, _ReplicaNodes, _VBucket) ->
    ok;
initiate_indexing(Bucket, Rebalancer, [NewMasterNode], _ReplicaNodes, _VBucket) ->
    ?rebalance_info("~s: Doing initiate_indexing call for ~s", [Bucket, NewMasterNode]),
    ok = gen_server:call(server_name(Bucket, NewMasterNode),
                         {if_rebalance, Rebalancer, initiate_indexing},
                         infinity).

wait_index_updated(Bucket, Rebalancer, NewMasterNode, _ReplicaNodes, VBucket) ->
    ?rebalance_info("~s: Doing wait_index_updated call for ~s (vbucket ~p)", [Bucket, NewMasterNode, VBucket]),
    ok = gen_server:call(server_name(Bucket, NewMasterNode),
                         {if_rebalance, Rebalancer,
                          {wait_index_updated, VBucket}},
                         infinity).

wait_upr_data_move(Bucket, Rebalancer, MasterNode, ReplicaNodes, VBucket) ->
    gen_server:call(server_name(Bucket, MasterNode),
                    {if_rebalance, Rebalancer,
                     {wait_upr_data_move, ReplicaNodes, VBucket}}, infinity).

%% returns checkpoint id which 100% contains all currently persisted
%% docs. Normally it's persisted_checkpoint_id + 1 (assuming
%% checkpoint after persisted one has some stuff persisted already)
get_replication_persistence_checkpoint_id(Bucket, Rebalancer, MasterNode, VBucket) ->
    ?rebalance_info("~s: Doing get_replication_persistence_checkpoint_id call for vbucket ~p on ~s", [Bucket, VBucket, MasterNode]),
    RV = gen_server:call(server_name(Bucket, MasterNode),
                         {if_rebalance, Rebalancer, {get_replication_persistence_checkpoint_id, VBucket}},
                         infinity),
    true = is_integer(RV),
    RV.

-spec create_new_checkpoint(bucket_name(), pid(), node(), vbucket_id()) -> {checkpoint_id(), checkpoint_id()}.
create_new_checkpoint(Bucket, Rebalancer, MasterNode, VBucket) ->
    ?rebalance_info("~s: Doing create_new_checkpoint call for vbucket ~p on ~s", [Bucket, VBucket, MasterNode]),
    {_PersistedCheckpointId, _OpenCheckpointId} =
        gen_server:call(server_name(Bucket, MasterNode),
                        {if_rebalance, Rebalancer, {create_new_checkpoint, VBucket}},
                        infinity).

-spec wait_checkpoint_persisted(bucket_name(), pid(), node(), vbucket_id(), checkpoint_id()) -> ok.
wait_checkpoint_persisted(Bucket, Rebalancer, Node, VBucket, WaitedCheckpointId) ->
    ok = gen_server:call({server_name(Bucket), Node},
                         {if_rebalance, Rebalancer, {wait_checkpoint_persisted, VBucket, WaitedCheckpointId}},
                         infinity).

initiate_servant_call(Server, Request) ->
    {ServantPid, Tag} = gen_server:call(Server, Request, infinity),
    MRef = erlang:monitor(process, ServantPid),
    {MRef, Tag}.

get_servant_call_reply({MRef, Tag}) ->
    receive
        {'DOWN', MRef, _, _, Reason} ->
            receive
                {Tag, Reply} ->
                    Reply
            after 0 ->
                    erlang:error({janitor_agent_servant_died, Reason})
            end
    end.

do_servant_call(Server, Request) ->
    get_servant_call_reply(initiate_servant_call(Server, Request)).

get_tap_docs_estimate(Bucket, SrcNode, VBucket, TapName) ->
    RV = do_servant_call({server_name(Bucket), SrcNode},
                         {get_tap_docs_estimate, VBucket, TapName}),
    {ok, _} = RV,
    RV.

-spec get_tap_docs_estimate_many_taps(bucket_name(), node(), vbucket_id(), [binary()]) ->
                                             [{ok, {non_neg_integer(), non_neg_integer(), binary()}}].
get_tap_docs_estimate_many_taps(Bucket, SrcNode, VBucket, TapNames) ->
    do_servant_call({server_name(Bucket), SrcNode},
                    {get_tap_docs_estimate_many_taps, VBucket, TapNames}).

get_mass_tap_docs_estimate(Bucket, Node, VBuckets) ->
    RV = do_servant_call({server_name(Bucket), Node},
                         {get_mass_tap_docs_estimate, VBuckets}),
    {ok, _} = RV,
    RV.

mass_prepare_flush(Bucket, Nodes) ->
    {Replies, BadNodes} = gen_server:multi_call(Nodes, server_name(Bucket), prepare_flush, ?PREPARE_FLUSH_TIMEOUT),
    {GoodReplies, BadReplies} = lists:partition(fun ({_N, R}) -> R =:= ok end, Replies),
    GoodNodes = [N || {N, _R} <- GoodReplies],
    {GoodNodes, BadReplies, BadNodes}.

server_name(Bucket, Node) ->
    {server_name(Bucket), Node}.

%% ----------- implementation -----------

start_link(Bucket) ->
    gen_server:start_link({local, server_name(Bucket)}, ?MODULE, Bucket, []).

init(BucketName) ->
    {ok, #state{bucket_name = BucketName,
                flushseq = read_flush_counter(BucketName)}}.

handle_call(prepare_flush, _From, #state{bucket_name = BucketName} = State) ->
    ?log_info("Preparing flush by disabling bucket traffic"),
    {reply, ns_memcached:disable_traffic(BucketName, infinity), State};
handle_call(complete_flush, _From, State) ->
    {reply, ok, consider_doing_flush(State)};
handle_call(query_vbucket_states, _From, #state{bucket_name = BucketName} = State) ->
    NewState = consider_doing_flush(State),
    %% NOTE: uses 'outer' memcached timeout of 60 seconds
    RV = (catch ns_memcached:local_connected_and_list_vbuckets(BucketName)),
    {reply, RV, NewState};
handle_call(get_incoming_replication_map, _From, #state{bucket_name = BucketName} = State) ->
    %% NOTE: has infinite timeouts but uses only local communication
    RV = replication_manager:get_incoming_replication_map(BucketName),
    {reply, RV, State};
handle_call({prepare_rebalance, _Pid}, _From,
            #state{last_applied_vbucket_states = undefined} = State) ->
    {reply, no_vbucket_states_set, State};
handle_call({prepare_rebalance, Pid}, _From,
            State) ->
    State1 = State#state{rebalance_only_vbucket_states = [undefined || _ <- State#state.rebalance_only_vbucket_states]},
    {reply, ok, set_rebalance_mref(Pid, State1)};
handle_call({if_rebalance, RebalancerPid, Subcall},
            From,
            #state{rebalance_pid = RealRebalancerPid} = State) ->
    case RealRebalancerPid =:= RebalancerPid of
        true ->
            handle_call(Subcall, From, State);
        false ->
            {reply, wrong_rebalancer_pid, State}
    end;
handle_call({update_vbucket_state, VBucket, NormalState, RebalanceState, ReplicateFrom}, _From,
            #state{bucket_name = BucketName,
                   last_applied_vbucket_states = WantedVBuckets,
                   rebalance_only_vbucket_states = RebalanceVBuckets} = State) ->
    NewWantedVBuckets = update_list_nth(VBucket + 1, WantedVBuckets, NormalState),
    NewRebalanceVBuckets = update_list_nth(VBucket + 1, RebalanceVBuckets, RebalanceState),
    NewState = State#state{last_applied_vbucket_states = NewWantedVBuckets,
                           rebalance_only_vbucket_states = NewRebalanceVBuckets},
    %% TODO: consider infinite timeout. It's local memcached after all
    ok = ns_memcached:set_vbucket(BucketName, VBucket, NormalState),
    ok = replication_manager:change_vbucket_replication(BucketName, VBucket, ReplicateFrom),
    {reply, ok, pass_vbucket_states_to_set_view_manager(NewState)};
handle_call({apply_new_config, NewBucketConfig, IgnoredVBuckets}, _From, #state{bucket_name = BucketName} = State) ->
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

    %% before changing vbucket states (i.e. activating or killing
    %% vbuckets) we must stop replications into those vbuckets
    WantedReplicas = [{Src, VBucket} || {Src, Dst, VBucket} <- ns_bucket:map_to_replicas_chain(Map),
                                        Dst =:= node()],
    WantedReplications = [{Src, [VB || {_, VB} <- Pairs]}
                          || {Src, Pairs} <- misc:keygroup(1, lists:sort(WantedReplicas))],
    ok = replication_manager:remove_undesired_replications(BucketName, WantedReplications),

    %% then we're ok to change vbucket states
    [ns_memcached:set_vbucket(BucketName, VBucket, StateToSet)
     || {VBucket, StateToSet} <- ToSet],

    %% and ok to delete vbuckets we want to delete
    [ns_memcached:delete_vbucket(BucketName, VBucket) || VBucket <- ToDelete],

    NewWanted = lists:reverse(NewWantedRev),
    NewRebalance = [undefined || _ <- NewWantedRev],
    State2 = State#state{last_applied_vbucket_states = NewWanted,
                         rebalance_only_vbucket_states = NewRebalance},
    State3 = set_rebalance_mref(undefined, State2),
    {reply, ok, pass_vbucket_states_to_set_view_manager(State3)};
handle_call({apply_new_config_replicas_phase, NewBucketConfig, IgnoredVBuckets},
            _From, #state{bucket_name = BucketName} = State) ->
    Map = proplists:get_value(map, NewBucketConfig),
    true = (Map =/= undefined),
    %% TODO: unignore ignored vbuckets
    [] = IgnoredVBuckets,
    WantedReplicas = [{Src, VBucket} || {Src, Dst, VBucket} <- ns_bucket:map_to_replicas_chain(Map),
                                        Dst =:= node()],
    WantedReplications = [{Src, [VB || {_, VB} <- Pairs]}
                          || {Src, Pairs} <- misc:keygroup(1, lists:sort(WantedReplicas))],
    ok = replication_manager:set_incoming_replication_map(BucketName, WantedReplications),
    {reply, ok, State};
handle_call({delete_vbucket, VBucket}, _From, #state{bucket_name = BucketName} = State) ->
    {reply, ok = ns_memcached:delete_vbucket(BucketName, VBucket), State};
handle_call({wait_index_updated, VBucket}, From, #state{bucket_name = Bucket} = State) ->
    State2 = spawn_rebalance_subprocess(
               State,
               From,
               fun () ->
                       capi_set_view_manager:wait_index_updated(Bucket, VBucket)
               end),
    {noreply, State2};
handle_call({wait_upr_data_move, ReplicaNodes, VBucket}, From, #state{bucket_name = Bucket} = State) ->
    State2 = spawn_rebalance_subprocess(
               State,
               From,
               fun () ->
                       upr_replicator:wait_for_data_move(ReplicaNodes, Bucket, VBucket)
               end),
    {noreply, State2};
handle_call(initiate_indexing, From, #state{bucket_name = Bucket} = State) ->
    State2 = spawn_rebalance_subprocess(
               State,
               From,
               fun () ->
                       ok = capi_set_view_manager:initiate_indexing(Bucket)
               end),
    {noreply, State2};
handle_call({create_new_checkpoint, VBucket},
            _From,
            #state{bucket_name = Bucket} = State) ->
    %% NOTE: this happens on current master of vbucket thus undefined
    %% persisted checkpoint id should not be possible here
    {ok, {PersistedCheckpointId, _}} = ns_memcached:get_vbucket_checkpoint_ids(Bucket, VBucket),
    {ok, OpenCheckpointId, _LastPersistedCkpt} = ns_memcached:create_new_checkpoint(Bucket, VBucket),
    {reply, {PersistedCheckpointId, OpenCheckpointId}, State};
handle_call({wait_checkpoint_persisted, VBucket, CheckpointId},
           From,
           #state{bucket_name = Bucket} = State) ->
    State2 = spawn_rebalance_subprocess(
               State,
               From,
               fun () ->
                       ?rebalance_debug("Going to wait for persistence of checkpoint ~B in vbucket ~B", [CheckpointId, VBucket]),
                       ok = do_wait_checkpoint_persisted(Bucket, VBucket, CheckpointId),
                       ?rebalance_debug("Done"),
                       ok
               end),
    {noreply, State2};
handle_call({get_replication_persistence_checkpoint_id, VBucket},
            _From,
            #state{bucket_name = Bucket} = State) ->
    %% NOTE: this happens on current master of vbucket thus undefined
    %% persisted checkpoint id should not be possible here
    {ok, {PersistedCheckpointId, OpenCheckpointId}} = ns_memcached:get_vbucket_checkpoint_ids(Bucket, VBucket),
    case PersistedCheckpointId + 1 < OpenCheckpointId of
        true ->
            {reply, PersistedCheckpointId + 1, State};
        false ->
            {ok, NewOpenCheckpointId, _LastPersistedCkpt} = ns_memcached:create_new_checkpoint(Bucket, VBucket),
            ?log_debug("After creating new checkpoint here's what we have: ~p (~p)", [{PersistedCheckpointId, OpenCheckpointId, NewOpenCheckpointId}, VBucket]),
            {reply, erlang:min(PersistedCheckpointId + 1, NewOpenCheckpointId - 1), State}
    end;
handle_call({get_tap_docs_estimate, _VBucketId, _TapName} = Req, From, State) ->
    handle_call_via_servant(
      From, State, Req,
      fun ({_, VBucketId, TapName}, #state{bucket_name = Bucket}) ->
              ns_memcached:get_tap_docs_estimate(Bucket, VBucketId, TapName)
      end);
handle_call({get_tap_docs_estimate_many_taps, _VBucketId, _TapName} = Req, From, State) ->
    handle_call_via_servant(
      From, State, Req,
      fun ({_, VBucketId, TapNames}, #state{bucket_name = Bucket}) ->
              [ns_memcached:get_tap_docs_estimate(Bucket, VBucketId, Name)
               || Name <- TapNames]
      end);
handle_call({get_mass_tap_docs_estimate, VBucketsR}, From, State) ->
    handle_call_via_servant(
      From, State, VBucketsR,
      fun (VBuckets, #state{bucket_name = Bucket}) ->
              ns_memcached:get_mass_tap_docs_estimate(Bucket, VBuckets)
      end).

handle_call_via_servant({FromPid, _Tag}, State, Req, Body) ->
    Tag = erlang:make_ref(),
    From = {FromPid, Tag},
    Pid = proc_lib:spawn(fun () ->
                                 gen_server:reply(From, Body(Req, State))
                         end),
    {reply, {Pid, Tag}, State}.


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
handle_info({subprocess_done, Pid, RV}, #state{rebalance_subprocesses = Subprocesses} = State) ->
    ?log_debug("Got done message from subprocess: ~p (~p)", [Pid, RV]),
    case lists:keyfind(Pid, 2, Subprocesses) of
        false ->
            {noreply, State};
        {From, _} = Pair ->
            gen_server:reply(From, RV),
            {noreply, State#state{rebalance_subprocesses = Subprocesses -- [Pair]}}
    end;
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
    [begin
         ?log_debug("Killing rebalance-related subprocess: ~p", [P]),
         erlang:unlink(P),
         exit(P, shutdown),
         misc:wait_for_process(P, infinity),
         gen_server:reply(From, rebalance_aborted)
     end || {From, P} <- State0#state.rebalance_subprocesses],
    State = State0#state{rebalance_pid = Pid,
                         rebalance_subprocesses = []},
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

spawn_rebalance_subprocess(#state{rebalance_subprocesses = Subprocesses} = State, From, Fun) ->
    Parent = self(),
    Pid = proc_lib:spawn_link(fun () ->
                                      RV = Fun(),
                                      Parent ! {subprocess_done, self(), RV}
                              end),
    State#state{rebalance_subprocesses = [{From, Pid} | Subprocesses]}.

flushseq_file_path(BucketName) ->
    {ok, DBSubDir} = ns_storage_conf:this_node_bucket_dbdir(BucketName),
    filename:join(DBSubDir, "flushseq").

read_flush_counter(BucketName) ->
    FlushSeqFile = flushseq_file_path(BucketName),
    case file:read_file(FlushSeqFile) of
        {ok, Contents} ->
            try list_to_integer(binary_to_list(Contents)) of
                FlushSeq ->
                    ?log_info("Got flushseq from local file: ~p", [FlushSeq]),
                    FlushSeq
            catch T:E ->
                    ?log_error("Parsing flushseq failed: ~p", [{T, E, erlang:get_stacktrace()}]),
                    read_flush_counter_from_config(BucketName)
            end;
        Error ->
            ?log_info("Loading flushseq failed: ~p. Assuming it's equal to global config.", [Error]),
            read_flush_counter_from_config(BucketName)
    end.

read_flush_counter_from_config(BucketName) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(BucketName),
    RV = proplists:get_value(flushseq, BucketConfig, 0),
    ?log_info("Initialized flushseq ~p from bucket config", [RV]),
    RV.

consider_doing_flush(State) ->
    BucketName = State#state.bucket_name,
    case ns_bucket:get_bucket(BucketName) of
        {ok, BucketConfig} ->
            ConfigFlushSeq = proplists:get_value(flushseq, BucketConfig, 0),
            MyFlushSeq = State#state.flushseq,
            case ConfigFlushSeq > MyFlushSeq of
                true ->
                    ?log_info("Config flushseq ~p is greater than local flushseq ~p. Going to flush", [ConfigFlushSeq, MyFlushSeq]),
                    perform_flush(State, BucketConfig, ConfigFlushSeq);
                false ->
                    case ConfigFlushSeq =/= MyFlushSeq of
                        true ->
                            ?log_error("That's weird. Config flushseq is lower than ours: ~p vs. ~p. Ignoring", [ConfigFlushSeq, MyFlushSeq]),
                            State#state{flushseq = ConfigFlushSeq};
                        _ ->
                            State
                    end
            end;
        not_present ->
            ?log_info("Detected that our bucket is actually dead"),
            State
    end.

perform_flush(#state{bucket_name = BucketName} = State, BucketConfig, ConfigFlushSeq) ->
    ?log_info("Doing local bucket flush"),
    {ok, VBStates} = ns_memcached:local_connected_and_list_vbuckets(BucketName),
    NewVBStates = lists:duplicate(proplists:get_value(num_vbuckets, BucketConfig), missing),
    RebalanceVBStates = lists:duplicate(proplists:get_value(num_vbuckets, BucketConfig), undefined),
    NewState = State#state{last_applied_vbucket_states = NewVBStates,
                           rebalance_only_vbucket_states = RebalanceVBStates,
                           flushseq = ConfigFlushSeq},
    ?log_info("Removing all vbuckets from indexes"),
    pass_vbucket_states_to_set_view_manager(NewState),
    ok = capi_set_view_manager:reset_master_vbucket(BucketName),
    ?log_info("Shutting down incoming replications"),
    ok = replication_manager:set_incoming_replication_map(BucketName, []),
    %% kill all vbuckets
    [ok = ns_memcached:sync_delete_vbucket(BucketName, VB)
     || {VB, _} <- VBStates],
    ?log_info("Local flush is done"),
    save_flushseq(BucketName, ConfigFlushSeq),
    NewState.

save_flushseq(BucketName, ConfigFlushSeq) ->
    ?log_info("Saving new flushseq: ~p", [ConfigFlushSeq]),
    Cont = list_to_binary(integer_to_list(ConfigFlushSeq)),
    misc:atomic_write_file(flushseq_file_path(BucketName), Cont).

do_wait_checkpoint_persisted(Bucket, VBucket, CheckpointId) ->
  case ns_memcached:wait_for_checkpoint_persistence(Bucket, VBucket, CheckpointId) of
      ok -> ok;
      {memcached_error, etmpfail, _} ->
          ?rebalance_debug("Got etmpfail waiting for checkpoint persistence. Will try again"),
          do_wait_checkpoint_persisted(Bucket, VBucket, CheckpointId)
  end.
