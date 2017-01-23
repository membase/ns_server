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

-export([spawn_mover/4, mover/5]).

-include("ns_common.hrl").

spawn_mover(Bucket, VBucket, OldChain, NewChain) ->
    Parent = self(),
    Pid = proc_lib:spawn_link(ns_single_vbucket_mover, mover,
                              [Parent, Bucket, VBucket, OldChain, NewChain]),
    ?rebalance_debug("Spawned single vbucket mover: ~p (~p)",
                     [[Parent, Bucket, VBucket, OldChain, NewChain], Pid]),
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

%% We do a no-op here rather than filtering these out so that the
%% replication update will still work properly.
mover(Parent, Bucket, VBucket, [undefined | _] = OldChain, [NewNode | _] = NewChain) ->
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

mover(Parent, Bucket, VBucket, OldChain, NewChain) ->
    master_activity_events:note_vbucket_mover(self(), Bucket, hd(OldChain), VBucket, OldChain, NewChain),
    IndexAware = cluster_compat_mode:is_index_aware_rebalance_on(),
    misc:try_with_maybe_ignorant_after(
      fun () ->
              process_flag(trap_exit, true),
              mover_inner_dcp(Parent, Bucket, VBucket, OldChain, NewChain, IndexAware),
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

                    Shutdown =
                        case Reason of
                            shutdown ->
                                true;
                            {shutdown, _} ->
                                true;
                            _ ->
                                false
                        end,

                    case Shutdown of
                        true ->
                            ?log_debug("Got shutdown exit signal ~p. "
                                       "Assuming it's from our parent", [ExitMsg]),
                            exit(Reason);
                        false ->
                            ?log_error("Got unexpected exit signal ~p", [ExitMsg]),
                            exit({unexpected_exit, ExitMsg})
                    end
            end
    end.

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

mover_inner_dcp(Parent, Bucket, VBucket,
                [OldMaster|OldReplicas] = OldChain, [NewMaster|_] = NewChain, IndexAware) ->
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
    wait_dcp_data_move(Bucket, Parent, OldMaster, AllBuiltNodes, VBucket),
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
            dcp_takeover(Bucket, Parent, OldMaster, NewMaster, VBucket),
            master_activity_events:note_takeover_ended(Bucket, VBucket, OldMaster, NewMaster)
    end,

    %% set new master to active state
    set_vbucket_state(Bucket, NewMaster, Parent, VBucket, active,
                      undefined, undefined),

    %% we're safe if old and new masters are the same; basically our
    %% replication streams are already established
    case OldMaster =:= NewMaster of
        true ->
            ok;
        false ->
            %% Vbucket on the old master is dead.
            %% Cleanup replication streams from the old master to the
            %% new and old replica nodes.
            %% We need to cleanup streams to the old replicas as well
            %% to prevent race condition like the one described below.
            %%
            %% At the end of the vbucket move,
            %% update_replication_post_move performs bulk vbucket state
            %% update. Based on how the old and new chains are, one possible
            %% set of state transitions are as follows:
            %%  - change state of vbucket, say vb1, on old master to replica
            %%  - change state of vb1 on old replicas. This results in closing
            %%    of streams from old master to the old replicas.
            %% Ideally, we want all replication streams from the old master
            %% to close before we change the state of the vbucket on the
            %% old master. But, bulk vbucket state change is racy which causes
            %% other races. Consider this sequence which can occur
            %% if state of vb on old master changes before the replication
            %% streams from it are closed.
            %%  1. State of vb1 on old master changes to replica. Replication
            %%     stream from old master to the old replicas are still active.
            %%  2. Because of the state change, EP engine sends dcp stream
            %%     end to old replicas.
            %%  3. Old replica is in middle of processing the dcp stream end.
            %%     There is a few milisecond window when
            %%     ns-server has processed dcp stream end but EP engine has not.
            %%  4. Setup replication stream for some other vbucket comes in
            %%     during the above window. It tries to add back the
            %%     replication stream from old master to the old replicas.
            %%     Since EP engine has not processed the dcp stream end
            %%     yet, the stream add fails with eexist causing rebalance to
            %%     fail.
            %% Since state of the vb on old master is no longer active, we
            %% should not be trying to add a stream from it.
            %% If all replication streams from old master are closed
            %% here before the vbucket state changes on the old master,
            %% then we will not end up in race conditions like these.

            OldReplicaNodes = [N || N <- OldReplicas,
                                    N =/= undefined,
                                    N =/= NewMaster],
            CleanupNodes = lists:subtract(OldReplicaNodes, ReplicaNodes) ++
                ReplicaNodes,
            cleanup_old_streams(Bucket, CleanupNodes, Parent, VBucket)
    end.

set_vbucket_state(Bucket, Node, RebalancerPid, VBucket,
                  VBucketState, VBucketRebalanceState, ReplicateFrom) ->
    spawn_and_wait(
      fun () ->
              ok = janitor_agent:set_vbucket_state(Bucket, Node, RebalancerPid, VBucket,
                                                   VBucketState, VBucketRebalanceState, ReplicateFrom)
      end).

%% This ensures that all streams into new set of replicas (either replica
%% building streams or old replications) are closed. It's needed because
%% ep-engine doesn't like it when there are two consumer connections for the
%% same vbucket on a node.
%%
%% Note that some of the same streams appear to be cleaned up in
%% update_replication_post_move, but this is done in unpredictable order
%% there, so it's still possible to add a stream before the old one is
%% closed. In addition to that, it's also not enough to just clean up old
%% replications, because we also create rebalance-specific streams that can
%% lead to the same problems.
cleanup_old_streams(Bucket, Nodes, RebalancerPid, VBucket) ->
    Changes = [{Node, replica, undefined, undefined} || Node <- Nodes],
    spawn_and_wait(
      fun () ->
              ok = janitor_agent:bulk_set_vbucket_state(Bucket, RebalancerPid, VBucket, Changes)
      end).

dcp_takeover(Bucket, Parent, OldMaster, NewMaster, VBucket) ->
    spawn_and_wait(
      fun () ->
              ok = janitor_agent:dcp_takeover(Bucket, Parent, OldMaster, NewMaster, VBucket)
      end).

wait_dcp_data_move(Bucket, Parent, SrcNode, DstNodes, VBucket) ->
    spawn_and_wait(
      fun () ->
              ?rebalance_debug(
                 "Will wait for backfill on all opened streams for bucket = ~p partition ~p src node = ~p dest nodes = ~p",
                 [Bucket, VBucket, SrcNode, DstNodes]),
              case janitor_agent:wait_dcp_data_move(Bucket, Parent, SrcNode, DstNodes, VBucket) of
                  ok ->
                      ?rebalance_debug(
                         "DCP data is up to date for bucket = ~p partition ~p src node = ~p dest nodes = ~p",
                         [Bucket, VBucket, SrcNode, DstNodes]),
                      ok;
                  Error ->
                      erlang:error({dcp_wait_for_data_move_failed,
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
        ++ [{FutureMaster, pending, passive, SrcNode}
            || FutureMaster <- JustBackfillNodes],
    spawn_and_wait(
      fun () ->
              janitor_agent:bulk_set_vbucket_state(Bucket, Parent, VBucket, Changes)
      end).

%% @private
%% @doc {Src, Dst} pairs from a chain with unmapped nodes filtered out.
pairs([undefined | _]) ->
    [];
pairs([Master | Replicas]) ->
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
