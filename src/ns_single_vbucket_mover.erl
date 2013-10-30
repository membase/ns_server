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

spawn_mover(Bucket, VBucket,
            OldChain, NewChain) ->
    Parent = self(),
    Pid = proc_lib:spawn_link(ns_single_vbucket_mover, mover,
                              [Parent, Bucket, VBucket, OldChain, NewChain]),
    ?rebalance_debug("Spawned single vbucket mover: ~p (~p)", [[Parent, Bucket, VBucket, OldChain, NewChain], Pid]),
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
    ok = janitor_agent:set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined),
    Parent ! {move_done, {VBucket, OldChain, NewChain}};

mover(Parent, Bucket, VBucket, OldChain, NewChain) ->
    master_activity_events:note_vbucket_mover(self(), Bucket, hd(OldChain), VBucket, OldChain, NewChain),
    IndexAware = cluster_compat_mode:is_index_aware_rebalance_on(),
    misc:try_with_maybe_ignorant_after(
      fun () ->
              case IndexAware of
                  true ->
                      mover_inner(Parent, Bucket, VBucket, OldChain, NewChain);
                  false ->
                      mover_inner_old_style(Parent, Bucket, VBucket, OldChain, NewChain)
              end
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
                              ebucketmigrator_srv:had_backfill(Pid, 30000)
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
    case ns_config_ets_dup:unreliable_read_key(rebalance_index_waiting_disabled, false) of
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

inhibit_view_compaction(Parent, Node, Bucket, NewNode) ->
    case cluster_compat_mode:rebalance_ignore_view_compactions() of
        false ->
            spawn_and_wait(
              fun () ->
                      InhibitedNodes = lists:usort([Node, NewNode]),
                      InhibitRVs = misc:parallel_map(
                                     fun (N) ->
                                             {N, compaction_daemon:inhibit_view_compaction(Bucket, N, Parent)}
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
            ok = janitor_agent:set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined);
        false ->
            %% pause index updates on old master node
            case cluster_compat_mode:is_index_pausing_on() of
                true ->
                    system_stats_collector:increment_counter(index_pausing_runs, 1),
                    janitor_agent:set_vbucket_state(Bucket, Node, Parent, VBucket, active, paused, undefined),
                    SecondWaitedCheckpointId = janitor_agent:get_replication_persistence_checkpoint_id(Bucket, Parent, Node, VBucket),
                    master_activity_events:note_checkpoint_waiting_started(Bucket, VBucket, SecondWaitedCheckpointId, AllBuiltNodes),
                    ok = wait_checkpoint_persisted_many(Bucket, Parent, AllBuiltNodes, VBucket, SecondWaitedCheckpointId),
                    master_activity_events:note_checkpoint_waiting_ended(Bucket, VBucket, SecondWaitedCheckpointId, AllBuiltNodes);
                false ->
                    ok
            end,

            wait_index_updated(Bucket, Parent, NewNode, ReplicaNodes, VBucket),

            new_ns_replicas_builder:shutdown_replicator(BuilderPid, NewNode),
            ok = run_mover(Bucket, VBucket, Node, NewNode),
            ok = janitor_agent:set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined)
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

set_initial_vbucket_state(Bucket, Parent, VBucket, ReplicaNodes, JustBackfillNodes) ->
    Changes = [{Replica, replica, undefined, undefined}
               || Replica <- ReplicaNodes]
        ++ [{FutureMaster, replica, passive, undefined}
            || FutureMaster <- JustBackfillNodes],
    janitor_agent:bulk_set_vbucket_state(Bucket, Parent, VBucket, Changes).

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
            ok = janitor_agent:set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined);
        true ->
            ok = run_mover(Bucket, VBucket, Node, NewNode),
            ok = janitor_agent:set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined),
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
    Args0 = ebucketmigrator_srv:build_args(SrcNode, Bucket,
                                           SrcNode, DstNode, [VBucket], true),
    %% start ebucketmigrator on source node
    Args = [SrcNode | Args0],
    case apply(ebucketmigrator_srv, start_link, Args) of
        {ok, Pid} = RV ->
            ?log_debug("Spawned mover ~p ~p ~p -> ~p: ~p",
                       [Bucket, VBucket, SrcNode, DstNode, Pid]),
            RV;
        X -> X
    end.
