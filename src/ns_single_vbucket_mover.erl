%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(ns_single_vbucket_mover).

-export([spawn_mover/5, mover/6]).

-include("ns_common.hrl").

spawn_mover(Bucket, VBucket,
            OldChain, NewChain, ReplType) ->
    Parent = self(),
    Pid = proc_lib:spawn_link(ns_single_vbucket_mover, mover,
                              [Parent, Bucket, VBucket, OldChain, NewChain, ReplType]),
    ?rebalance_debug("Spawned single vbucket mover: ~p (~p)",
                     [[Parent, Bucket, VBucket, OldChain, NewChain, ReplType], Pid]),
    Pid.

get_cleanup_list() ->
    case erlang:get(cleanup_list) of
        undefined -> [];
        X -> X
    end.

cleanup_list_add(Pid) ->
    List = get_cleanup_list(),
    List2 = ordsets:add_element(Pid, List),
    erlang:put(cleanup_list, List2).

cleanup_list_del(Pid) ->
    List = get_cleanup_list(),
    List2 = ordsets:del_element(Pid, List),
    erlang:put(cleanup_list, List2).

get_vbucket_repl_type(VBucket, {upr, [Partitions]}) ->
    case lists:member(VBucket, Partitions) of
        true ->
            tap;
        false ->
            upr
    end;
get_vbucket_repl_type(_, ReplType) ->
    ReplType.

%% We do a no-op here rather than filtering these out so that the
%% replication update will still work properly.
mover(Parent, Bucket, VBucket, [undefined | _] = OldChain, [NewNode | _] = NewChain, _) ->
    misc:try_with_maybe_ignorant_after(
      fun () ->
              process_flag(trap_exit, true),
              set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined),

              on_move_done(Parent, Bucket, VBucket, OldChain, NewChain)
      end,
      fun () ->
              misc:sync_shutdown_many_i_am_trapping_exits(get_cleanup_list())
      end),
    Parent ! {move_done, {VBucket, OldChain, NewChain}};

mover(Parent, Bucket, VBucket, OldChain, NewChain, ReplType) ->
    master_activity_events:note_vbucket_mover(self(), Bucket, hd(OldChain), VBucket, OldChain, NewChain),
    IndexAware = cluster_compat_mode:is_index_aware_rebalance_on(),
    VBucketReplType = get_vbucket_repl_type(VBucket, ReplType),
    misc:try_with_maybe_ignorant_after(
      fun () ->
              case {IndexAware, VBucketReplType} of
                  {_, upr} ->
                      mover_inner_upr(Parent, Bucket, VBucket, OldChain, NewChain, IndexAware);
                  {true, tap} ->
                      mover_inner(Parent, Bucket, VBucket, OldChain, NewChain);
                  {false, tap} ->
                      mover_inner_old_style(Parent, Bucket, VBucket, OldChain, NewChain)
              end,

              on_move_done(Parent, Bucket, VBucket, OldChain, NewChain)
      end,
      fun () ->
              misc:sync_shutdown_many_i_am_trapping_exits(get_cleanup_list())
      end),

    case IndexAware of
        false ->
            Parent ! {move_done, {VBucket, OldChain, NewChain}};
        true ->
            Parent ! {move_done_new_style, {VBucket, OldChain, NewChain}}
    end.

spawn_and_wait(Body) ->
    WorkerPid = proc_lib:spawn_link(Body),
    cleanup_list_add(WorkerPid),
    receive
        {'EXIT', From, Reason} = ExitMsg ->
            case From =:= WorkerPid andalso Reason =:= normal of
                true ->
                    cleanup_list_del(WorkerPid),
                    ok;
                false ->
                    self() ! ExitMsg,
                    ?log_error("Got unexpected exit signal ~p", [ExitMsg]),
                    exit({unexpected_exit, ExitMsg})
            end
    end.

wait_backfill_determination(Replicators) ->
    spawn_and_wait(
      fun () ->
              RVs = misc:parallel_map(
                      fun ({_DNode, Pid}) ->
                              ebucketmigrator_srv:had_backfill(Pid, infinity)
                      end, Replicators, infinity),
              ?log_debug("Had backfill rvs: ~p(~p)", [RVs, Replicators]),
              %% TODO: nicer error here instead of badmatch
              [] = _BadRVs = [RV || RV <- RVs,
                                    not is_boolean(RV)]
      end).

wait_backfill_complete(Replicators) ->
    Self = self(),

    spawn_and_wait(
      fun () ->
              RVs = misc:parallel_map(
                      fun ({N, Pid}) ->
                              {N, (catch ebucketmigrator_srv:wait_backfill_complete(Pid))}
                      end, Replicators, infinity),
              misc:letrec(
                [RVs, [], false],
                fun (Rec, [RV | RestRVs], BadRetvals, HadUnhandled) ->
                        case RV of
                            {_, ok} ->
                                Rec(Rec, RestRVs, BadRetvals, HadUnhandled);
                            {_, not_backfilling} ->
                                Rec(Rec, RestRVs, BadRetvals, HadUnhandled);
                            {_, unhandled} ->
                                Rec(Rec, RestRVs, BadRetvals, true);
                            _ ->
                                Rec(Rec, RestRVs, [RV | BadRetvals], HadUnhandled)
                        end;
                    (_Rec, [], [], HadUnhandled) ->
                        Self ! {had_unhandled, HadUnhandled};
                    (_Rec, [], BadRVs, _) ->
                        erlang:error({wait_backfill_complete_failed_for, BadRVs})
                end)
      end),
    receive
        {had_unhandled, HadUnhandledVal} ->
            HadUnhandledVal
    end.


wait_checkpoint_persisted_many(Bucket, Parent, FewNodes, VBucket, WaitedCheckpointId) ->
    spawn_and_wait(
      fun () ->
              RVs = misc:parallel_map(
                      fun (Node) ->
                              {Node, (catch janitor_agent:wait_checkpoint_persisted(Bucket, Parent, Node, VBucket, WaitedCheckpointId))}
                      end, FewNodes, infinity),
              NonOks = [P || {_N, V} = P <- RVs,
                             V =/= ok],
              case NonOks =:= [] of
                  true -> ok;
                  false ->
                      erlang:error({wait_checkpoint_persisted_failed, Bucket, VBucket, WaitedCheckpointId, NonOks})
              end
      end).

wait_index_updated(Bucket, Parent, NewNode, ReplicaNodes, VBucket) ->
    case ns_config:read_key_fast(rebalance_index_waiting_disabled, false) of
        false ->
            master_activity_events:note_wait_index_updated_started(Bucket, NewNode, VBucket),
            spawn_and_wait(
              fun () ->
                      ok = janitor_agent:wait_index_updated(Bucket, Parent, NewNode, ReplicaNodes, VBucket)
              end),
            master_activity_events:note_wait_index_updated_ended(Bucket, NewNode, VBucket);
        _ ->
            ok
    end.

maybe_inhibit_view_compaction(_Parent, _Node, _Bucket, _NewNode, false) ->
    ok;
maybe_inhibit_view_compaction(Parent, Node, Bucket, NewNode, true) ->
    inhibit_view_compaction(Parent, Node, Bucket, NewNode).

inhibit_view_compaction(Parent, Node, Bucket, NewNode) ->
    case cluster_compat_mode:rebalance_ignore_view_compactions() of
        false ->
            spawn_and_wait(
              fun () ->
                      InhibitedNodes = lists:usort([Node, NewNode]),
                      InhibitRVs = misc:parallel_map(
                                     fun (N) ->
                                             {N, ns_vbucket_mover:inhibit_view_compaction(Bucket, Parent, N)}
                                     end, InhibitedNodes, infinity),

                      [case IRV of
                           {N, {ok, MRef}} ->
                               [master_activity_events:note_compaction_inhibited(Bucket, ANode)
                                || ANode <- InhibitedNodes],
                               Parent ! {inhibited_view_compaction, N, MRef};
                           _ ->
                               ?log_debug("Got nack for inhibited_view_compaction. Thats normal: ~p", [IRV])
                       end || IRV <- InhibitRVs],
                      ok
              end);
        _ ->
            ok
    end.

maybe_initiate_indexing(_Bucket, _Parent, _JustBackfillNodes, _ReplicaNodes, _VBucket, false) ->
    ok;
maybe_initiate_indexing(Bucket, Parent, JustBackfillNodes, ReplicaNodes, VBucket, true) ->
    ok = janitor_agent:initiate_indexing(Bucket, Parent, JustBackfillNodes, ReplicaNodes, VBucket),
    master_activity_events:note_indexing_initiated(Bucket, JustBackfillNodes, VBucket).

mover_inner_upr(Parent, Bucket, VBucket,
                [OldMaster|_] = OldChain, [NewMaster|_] = NewChain, IndexAware) ->
    process_flag(trap_exit, true),

    maybe_inhibit_view_compaction(Parent, OldMaster, Bucket, NewMaster, IndexAware),

    %% build new chain as replicas of existing master
    {ReplicaNodes, JustBackfillNodes} =
        get_replica_and_backfill_nodes(OldMaster, NewChain),

    %% setup replication streams to replicas from the existing master
    set_initial_vbucket_state(Bucket, Parent, VBucket, OldMaster, ReplicaNodes, JustBackfillNodes),

    %% initiate indexing on new master (replicas are ignored for now)
    %% at this moment since the stream to new master is created (if there is a new master)
    %% ep-engine guarantees that it can support indexing
    maybe_initiate_indexing(Bucket, Parent, JustBackfillNodes, ReplicaNodes, VBucket, IndexAware),

    %% wait for backfill on all the opened streams
    AllBuiltNodes = JustBackfillNodes ++ ReplicaNodes,
    wait_upr_data_move(Bucket, Parent, OldMaster, AllBuiltNodes, VBucket),
    master_activity_events:note_backfill_phase_ended(Bucket, VBucket),

    %% notify parent that the backfill is done, so it can start rebalancing
    %% next vbucket
    Parent ! {backfill_done, {VBucket, OldChain, NewChain}},

    %% grab the seqno from the old master and wait till this seqno is
    %% persisted on all the replicas
    wait_master_seqno_persisted_on_replicas(Bucket, VBucket, Parent, OldMaster, AllBuiltNodes),

    case OldMaster =:= NewMaster of
        true ->
            %% if there's nothing to move, we're done
            ok;
        false ->
            case IndexAware of
                true ->
                    %% pause index on old master node
                    case cluster_compat_mode:is_index_pausing_on() of
                        true ->
                            system_stats_collector:increment_counter(index_pausing_runs, 1),
                            set_vbucket_state(Bucket, OldMaster, Parent, VBucket, active,
                                              paused, undefined),
                            wait_master_seqno_persisted_on_replicas(Bucket, VBucket, Parent, OldMaster,
                                                                    AllBuiltNodes);
                        false ->
                            ok
                    end,

                    wait_index_updated(Bucket, Parent, NewMaster, ReplicaNodes, VBucket),

                    ?rebalance_debug("Index is updated on new master. Bucket ~p, partition ~p",
                                     [Bucket, VBucket]);
                false ->
                    ok
            end,

            master_activity_events:note_takeover_started(Bucket, VBucket, OldMaster, NewMaster),
            upr_takeover(Bucket, Parent, OldMaster, NewMaster, VBucket),
            master_activity_events:note_takeover_ended(Bucket, VBucket, OldMaster, NewMaster)
    end,

    %% set new master to active state
    set_vbucket_state(Bucket, NewMaster, Parent, VBucket, active,
                      undefined, undefined).

set_vbucket_state(Bucket, Node, RebalancerPid, VBucket,
                  VBucketState, VBucketRebalanceState, ReplicateFrom) ->
    spawn_and_wait(
      fun () ->
              ok = janitor_agent:set_vbucket_state(Bucket, Node, RebalancerPid, VBucket,
                                                   VBucketState, VBucketRebalanceState, ReplicateFrom)
      end).

upr_takeover(Bucket, Parent, OldMaster, NewMaster, VBucket) ->
    spawn_and_wait(
      fun () ->
              ok = janitor_agent:upr_takeover(Bucket, Parent, OldMaster, NewMaster, VBucket)
      end).

wait_upr_data_move(Bucket, Parent, SrcNode, DstNodes, VBucket) ->
    spawn_and_wait(
      fun () ->
              ?rebalance_debug(
                 "Will wait for backfill on all opened streams for bucket = ~p partition ~p src node = ~p dest nodes = ~p",
                 [Bucket, VBucket, SrcNode, DstNodes]),
              case janitor_agent:wait_upr_data_move(Bucket, Parent, SrcNode, DstNodes, VBucket) of
                  ok ->
                      ?rebalance_debug(
                         "Upr data is up to date for bucket = ~p partition ~p src node = ~p dest nodes = ~p",
                         [Bucket, VBucket, SrcNode, DstNodes]),
                      ok;
                  Error ->
                      erlang:error({upr_wait_for_data_move_failed,
                                    Bucket, VBucket, SrcNode, DstNodes, Error})
              end
      end).

wait_master_seqno_persisted_on_replicas(Bucket, VBucket, Parent, MasterNode, ReplicaNodes) ->
    SeqNo = janitor_agent:get_vbucket_high_seqno(Bucket, Parent, MasterNode, VBucket),
    master_activity_events:note_seqno_waiting_started(Bucket, VBucket, SeqNo, ReplicaNodes),
    wait_seqno_persisted_many(Bucket, Parent, ReplicaNodes, VBucket, SeqNo),
    master_activity_events:note_seqno_waiting_ended(Bucket, VBucket, SeqNo, ReplicaNodes).

wait_seqno_persisted_many(Bucket, Parent, Nodes, VBucket, SeqNo) ->
    spawn_and_wait(
      fun () ->
              RVs = misc:parallel_map(
                      fun (Node) ->
                              {Node, (catch janitor_agent:wait_seqno_persisted(Bucket, Parent, Node, VBucket, SeqNo))}
                      end, Nodes, infinity),
              NonOks = [P || {_N, V} = P <- RVs,
                             V =/= ok],
              case NonOks =:= [] of
                  true -> ok;
                  false ->
                      erlang:error({wait_seqno_persisted_failed, Bucket, VBucket, SeqNo, NonOks})
              end
      end).

mover_inner(Parent, Bucket, VBucket,
            [Node|_] = OldChain, [NewNode|_] = NewChain) ->
    process_flag(trap_exit, true),

    inhibit_view_compaction(Parent, Node, Bucket, NewNode),

    % build new chain as replicas of existing master
    {ReplicaNodes, JustBackfillNodes} =
        get_replica_and_backfill_nodes(Node, NewChain),

    set_initial_vbucket_state(Bucket, Parent, VBucket, ReplicaNodes, JustBackfillNodes),

    AllBuiltNodes = JustBackfillNodes ++ ReplicaNodes,

    BuilderPid = new_ns_replicas_builder:spawn_link(
                   Bucket, VBucket, Node,
                   JustBackfillNodes, ReplicaNodes),
    cleanup_list_add(BuilderPid),
    ?rebalance_debug("child replicas builder for vbucket ~p is ~p", [VBucket, BuilderPid]),

    BuilderReplicators = new_ns_replicas_builder:get_replicators(BuilderPid),
    wait_backfill_determination(BuilderReplicators),
    %% after we've got reply from had_backfill we know vbucket cannot
    %% have 'pending' backfill that'll 'rewind' open checkpoint
    %% id. Thus we can create new checkpoint and poll for it's
    %% persistence on destination nodes
    %%

    ok = janitor_agent:initiate_indexing(Bucket, Parent, JustBackfillNodes, ReplicaNodes, VBucket),
    master_activity_events:note_indexing_initiated(Bucket, JustBackfillNodes, VBucket),

    WaitedCheckpointId = janitor_agent:get_replication_persistence_checkpoint_id(Bucket, Parent, Node, VBucket),
    ?rebalance_info("Will wait for checkpoint ~p on replicas", [WaitedCheckpointId]),

    HadUnhandled = wait_backfill_complete(BuilderReplicators),
    master_activity_events:note_backfill_phase_ended(Bucket, VBucket),

    case HadUnhandled of
        false ->
            %% we could handle wait_backfill_complete for all nodes,
            %% so we can report backfill as done
            Parent ! {backfill_done, {VBucket, OldChain, NewChain}};
        true ->
            %% could not handle it. Must be 2.0.0 node(s). We'll
            %% report backfill as done after checkpoint persisted
            %% event
            ok
    end,

    master_activity_events:note_checkpoint_waiting_started(Bucket, VBucket, WaitedCheckpointId, AllBuiltNodes),
    ok = wait_checkpoint_persisted_many(Bucket, Parent, AllBuiltNodes, VBucket, WaitedCheckpointId),
    master_activity_events:note_checkpoint_waiting_ended(Bucket, VBucket, WaitedCheckpointId, AllBuiltNodes),

    %% report backfill as done if it was not reported before
    case HadUnhandled of
        true ->
            Parent ! {backfill_done, {VBucket, OldChain, NewChain}};
        _ ->
            ok
    end,

    case Node =:= NewNode of
        true ->
            %% if there's nothing to move, we're done
            set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined);
        false ->
            %% pause index updates on old master node
            case cluster_compat_mode:is_index_pausing_on() of
                true ->
                    system_stats_collector:increment_counter(index_pausing_runs, 1),
                    set_vbucket_state(Bucket, Node, Parent, VBucket, active, paused, undefined),
                    SecondWaitedCheckpointId = janitor_agent:get_replication_persistence_checkpoint_id(Bucket, Parent, Node, VBucket),
                    master_activity_events:note_checkpoint_waiting_started(Bucket, VBucket, SecondWaitedCheckpointId, AllBuiltNodes),
                    ?rebalance_info("Will wait for checkpoint ~p on replicas", [SecondWaitedCheckpointId]),
                    ok = wait_checkpoint_persisted_many(Bucket, Parent, AllBuiltNodes, VBucket, SecondWaitedCheckpointId),
                    master_activity_events:note_checkpoint_waiting_ended(Bucket, VBucket, SecondWaitedCheckpointId, AllBuiltNodes);
                false ->
                    ok
            end,

            wait_index_updated(Bucket, Parent, NewNode, ReplicaNodes, VBucket),
            ?rebalance_info("Done waiting for index updating. Will shutdown replicator into ~p", [NewNode]),

            new_ns_replicas_builder:shutdown_replicator(BuilderPid, NewNode),
            ?rebalance_info("Going to do takeover"),
            ok = run_mover(Bucket, VBucket, Node, NewNode),
            set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined)
    end.

get_replica_and_backfill_nodes(MasterNode, [NewMasterNode|_] = NewChain) ->
    ReplicaNodes = [N || N <- NewChain,
                         N =/= MasterNode,
                         N =/= undefined,
                         N =/= NewMasterNode],
    JustBackfillNodes = [N || N <- [NewMasterNode],
                              N =/= MasterNode],
    true = (JustBackfillNodes =/= [undefined]),
    {ReplicaNodes, JustBackfillNodes}.

set_initial_vbucket_state(Bucket, Parent, VBucket, SrcNode, ReplicaNodes, JustBackfillNodes) ->
    Changes = [{Replica, replica, undefined, SrcNode}
               || Replica <- ReplicaNodes]
        ++ [{FutureMaster, replica, passive, SrcNode}
            || FutureMaster <- JustBackfillNodes],
    spawn_and_wait(
      fun () ->
              janitor_agent:bulk_set_vbucket_state(Bucket, Parent, VBucket, Changes)
      end).

set_initial_vbucket_state(Bucket, Parent, VBucket, ReplicaNodes, JustBackfillNodes) ->
    set_initial_vbucket_state(Bucket, Parent, VBucket, undefined, ReplicaNodes, JustBackfillNodes).

mover_inner_old_style(Parent, Bucket, VBucket,
                      [Node|_], [NewNode|_] = NewChain) ->
    process_flag(trap_exit, true),
    % build new chain as replicas of existing master
    {ReplicaNodes, JustBackfillNodes} =
        get_replica_and_backfill_nodes(Node, NewChain),

    set_initial_vbucket_state(Bucket, Parent, VBucket, ReplicaNodes, JustBackfillNodes),

    Self = self(),
    ReplicasBuilderPid = ns_replicas_builder:spawn_link(
                           Bucket, VBucket, Node,
                           ReplicaNodes, JustBackfillNodes,
                           fun () ->
                                   Self ! replicas_done
                           end),
    ?rebalance_debug("child replicas builder for vbucket ~p is ~p", [VBucket, ReplicasBuilderPid]),
    cleanup_list_add(ReplicasBuilderPid),
    receive
        {'EXIT', _, _} = ExitMsg ->
            ?log_info("Got exit message (parent is ~p). Exiting...~n~p", [Parent, ExitMsg]),
            %% This exit can be from some of our cleanup childs, thus
            %% we need to requeue exit message so that
            %% sync_shutdown_many higher up the stack can consume it
            %% for real
            self() ! ExitMsg,
            ExitReason = case ExitMsg of
                             {'EXIT', Parent, shutdown} -> shutdown;
                             _ -> {exited, ExitMsg}
                         end,
            exit(ExitReason);
        replicas_done ->
            %% and when all backfills are done and replication into
            %% new master is stopped we consider doing takeover
            ok
    end,
    if
        Node =:= NewNode ->
            %% if there's nothing to move, we're done
            set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined);
        true ->
            ok = run_mover(Bucket, VBucket, Node, NewNode),
            set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined),
            ok
    end.

run_mover(Bucket, V, N1, N2) ->
    case {ns_memcached:get_vbucket(N1, Bucket, V),
          ns_memcached:get_vbucket(N2, Bucket, V)} of
        {{ok, active}, {ok, ReplicaState}} when ReplicaState =:= replica orelse ReplicaState =:= pending ->
            {ok, Pid} = spawn_ebucketmigrator_mover(Bucket, V, N1, N2),
            wait_for_mover(Bucket, V, N1, N2, Pid)
    end.

wait_for_mover(Bucket, V, N1, N2, Pid) ->
    cleanup_list_add(Pid),
    receive
        {'EXIT', Pid, normal} ->
            cleanup_list_del(Pid),
            case {ns_memcached:get_vbucket(N1, Bucket, V),
                  ns_memcached:get_vbucket(N2, Bucket, V)} of
                {{ok, dead}, {ok, active}} ->
                    ok;
                E ->
                    exit({wrong_state_after_transfer, E, V})
            end;
        {'EXIT', Pid, Reason} ->
            cleanup_list_del(Pid),
            exit({mover_failed, Reason});
        {'EXIT', _Pid, shutdown} ->
            exit(shutdown);
        {'EXIT', _OtherPid, _Reason} = Msg ->
            ?log_debug("Got unexpected exit: ~p", [Msg]),
            self() ! Msg,
            exit({unexpected_exit, Msg});
        Msg ->
            ?rebalance_warning("Mover parent got unexpected message:~n"
                               "~p", [Msg]),
            wait_for_mover(Bucket, V, N1, N2, Pid)
    end.

spawn_ebucketmigrator_mover(Bucket, VBucket, SrcNode, DstNode) ->
    Args = ebucketmigrator_srv:build_args(SrcNode, Bucket,
                                          SrcNode, DstNode, [VBucket], true, true),
    case ebucketmigrator_srv:start_link(SrcNode, Args) of
        {ok, Pid} = RV ->
            ?log_debug("Spawned mover ~p ~p ~p -> ~p: ~p",
                       [Bucket, VBucket, SrcNode, DstNode, Pid]),
            RV;
        X -> X
    end.

%% @private
%% @doc {Src, Dst} pairs from a chain with unmapped nodes filtered out.
pairs(Chain) ->
    case cluster_compat_mode:get_replication_topology() of
        star ->
            pairs_star(Chain);
        chain ->
            pairs_chain(Chain)
    end.

pairs_chain(Chain) ->
    [Pair || {Src, Dst} = Pair <- misc:pairs(Chain), Src /= undefined,
             Dst /= undefined].

pairs_star([undefined | _]) ->
    [];
pairs_star([Master | Replicas]) ->
    [{Master, R} || R <- Replicas, R =/= undefined].

%% @private
%% @doc Perform post-move replication fixup.
update_replication_post_move(RebalancerPid, BucketName, VBucket, OldChain, NewChain) ->
    ChangeReplica = fun (Dst, Src) ->
                            {Dst, replica, undefined, Src}
                    end,
    %% destroy remnants of old replication chain
    DelChanges = [ChangeReplica(D, undefined) || {_, D} <- pairs(OldChain),
                                                 not lists:member(D, NewChain)],
    %% just start new chain of replications. Old chain is dead now
    AddChanges = [ChangeReplica(D, S) || {S, D} <- pairs(NewChain)],
    ok = janitor_agent:bulk_set_vbucket_state(BucketName, RebalancerPid,
                                              VBucket, AddChanges ++ DelChanges).

on_move_done(RebalancerPid, Bucket, VBucket, OldChain, NewChain) ->
    spawn_and_wait(
      fun () ->
              on_move_done_body(RebalancerPid, Bucket,
                                VBucket, OldChain, NewChain)
      end).

on_move_done_body(RebalancerPid, Bucket, VBucket, OldChain, NewChain) ->
    update_replication_post_move(RebalancerPid, Bucket, VBucket, OldChain, NewChain),

    OldCopies0 = OldChain -- NewChain,
    OldCopies = [OldCopyNode || OldCopyNode <- OldCopies0,
                                OldCopyNode =/= undefined],
    ?rebalance_info("Moving vbucket ~p done. Will delete it on: ~p", [VBucket, OldCopies]),
    case janitor_agent:delete_vbucket_copies(Bucket, RebalancerPid, OldCopies, VBucket) of
        ok ->
            ok;
        {errors, BadDeletes} ->
            ?log_error("Deleting some old copies of vbucket failed: ~p", [BadDeletes])
    end.
