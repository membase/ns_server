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

spawn_mover(Node, Bucket, VBucket,
            OldChain, NewChain) ->
    Parent = self(),
    Pid = proc_lib:spawn_link(ns_single_vbucket_mover, mover,
                              [Parent, Node, Bucket, VBucket, OldChain, NewChain]),
    ?rebalance_debug("Spawned single vbucket mover: ~p (~p)", [[Parent, Node, Bucket, VBucket, OldChain, NewChain], Pid]),
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
mover(Parent, undefined = Node, Bucket, VBucket, OldChain, [NewNode | _NewChainRest] = NewChain) ->
    ok = janitor_agent:set_vbucket_state(Bucket, NewNode, Parent, VBucket, active, undefined, undefined),
    Parent ! {move_done, {Node, VBucket, OldChain, NewChain}};

mover(Parent, Node, Bucket, VBucket, OldChain, NewChain) ->
    master_activity_events:note_vbucket_mover(self(), Bucket, Node, VBucket, OldChain, NewChain),
    misc:try_with_maybe_ignorant_after(
      fun () ->
              mover_inner(Parent, Node, Bucket, VBucket, OldChain, NewChain)
      end,
      fun () ->
              misc:sync_shutdown_many_i_am_trapping_exits(get_cleanup_list())
      end),
    Parent ! {move_done, {Node, VBucket, OldChain, NewChain}}.

mover_inner(Parent, Node, Bucket, VBucket,
            OldChain, [NewNode|_] = NewChain) ->
    process_flag(trap_exit, true),
    %% first build new chain as replicas of existing master
    Node = hd(OldChain),
    ReplicaNodes = [N || N <- NewChain,
                         N =/= Node,
                         N =/= undefined,
                         N =/= NewNode],
    JustBackfillNodes = [N || N <- [NewNode],
                              N =/= Node],
    true = (JustBackfillNodes =/= [undefined]),
    Self = self(),
    Changes = [{Replica, replica, undefined, undefined}
               || Replica <- ReplicaNodes]
        ++ [{FutureMaster, replica, passive, undefined}
            || FutureMaster <- JustBackfillNodes],
    janitor_agent:bulk_set_vbucket_state(Bucket, Parent, VBucket, Changes),
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
        {{ok, active}, {ok, replica}} ->
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
    Args0 = ebucketmigrator_srv:build_args(Bucket,
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
