%% @author Couchbase, Inc <info@couchbase.com>
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
%%
%% @doc this implements creating replication stream for particular
%% vbucket from some node to bunch of other nodes and waiting until
%% all backfills are done. It is also possible to shutdown some
%% replications earlier then others.
%%
%% NOTE: this code can be structured as gen_server, but I decided
%% against that. Reason is that I'd like to keep logic straight and
%% fsm-less, but if you, my dear reader, is planning any extra
%% features here, please, consider refactoring it into gen_server.

-module(ns_replicas_builder).

-include("ns_common.hrl").

-export([spawn_link/6,
         sync_shutdown_many/1, try_with_maybe_ignorant_after/2]).

%% @doc spawns replicas builder for given bucket, vbucket, source and
%% destination node(s). AfterDone will be called after all backfills
%% are done, so it can notify whoever is interested in this event. For
%% JustBackfillNodes it'll backfill replicas just as for any other
%% destination node, but it'll stop replication when backfill is done
%% (and before AfterDone is called). Replicas on ReplicateIntoNodes
%% will be built and replication will continue maintaining them even
%% when AfterDone is called and after it returns.
%%
%% When replicas are built and AfterDone is called this process will
%% wait EXIT signal from parent, on which it'll reliably terminate
%% child replicator and exit.
-spec spawn_link(Bucket::bucket_name(), VBucket::vbucket_id(), SrcNode::node(),
                 ReplicateIntoNodes::[node()], JustBackfillNodes::[node()],
                 AfterDone::fun(() -> any()))-> pid().
spawn_link(Bucket, VBucket, SrcNode, ReplicateIntoNodes, JustBackfillNodes, AfterDone) ->
    proc_lib:spawn_link(erlang, apply,
                        [fun build_replicas_main/6,
                         [Bucket, VBucket, SrcNode, ReplicateIntoNodes, JustBackfillNodes, AfterDone]]).

-define(COMPLETION_POLLING_INTERVAL, 100).

%% @doc works like try/after but when try has raised exception, any
%% exception from AfterBody is logged and ignored. I.e. when we face
%% exceptions from both try-block and after-block, exception from
%% after-block is logged and ignored and exception from try-block is
%% rethrown. Use this when exception from TryBody is more important
%% than exception from AfterBody.
try_with_maybe_ignorant_after(TryBody, AfterBody) ->
    RV =
        try TryBody()
        catch T:E ->
                Stacktrace = erlang:get_stacktrace(),
                try AfterBody()
                catch T2:E2 ->
                        ?log_error("Eating exception from ignorant after-block:~n~p", [{T2, E2, erlang:get_stacktrace()}])
                end,
                erlang:raise(T, E, Stacktrace)
        end,
    AfterBody(),
    RV.

-spec build_replicas_main(bucket_name(), vbucket_id(), node(), [node()], [node()], fun(() -> ok)) -> ok.
build_replicas_main(Bucket, VBucket, SrcNode, ReplicateIntoNodes, JustBackfillNodes, AfterDone) ->
    erlang:process_flag(trap_exit, true),
    case (JustBackfillNodes -- ReplicateIntoNodes) =:= JustBackfillNodes andalso
                     (ReplicateIntoNodes -- JustBackfillNodes) =:= ReplicateIntoNodes of
        false ->
            exit({badarg_on_nodes, ReplicateIntoNodes, JustBackfillNodes});
        _ -> ok
    end,

    StopEarlyReplicators = [spawn_replica_builder(Bucket, VBucket, SrcNode, DNode) || DNode <- JustBackfillNodes],
    ContinuousReplicators = [spawn_replica_builder(Bucket, VBucket, SrcNode, DNode) || DNode <- ReplicateIntoNodes],
    Replicators = StopEarlyReplicators ++ ContinuousReplicators,

    try_with_maybe_ignorant_after(
      fun () ->
              observe_wait_all_done(Bucket, VBucket, SrcNode, JustBackfillNodes ++ ReplicateIntoNodes,
                                    fun () ->
                                            system_stats_collector:increment_counter(replica_builder_sleeps, 1),
                                            system_stats_collector:increment_counter(replica_builder_sleep_amount, ?COMPLETION_POLLING_INTERVAL),
                                            receive
                                                {'EXIT', From, Reason} = ExitMsg ->
                                                    case lists:member(From, Replicators) of
                                                        true ->
                                                            ?log_error("Got premature exit from one of ebucketmigrators: ~p", [ExitMsg]),
                                                            self() ! ExitMsg, % we'll process it again in after block
                                                            exit({replicator_died, ExitMsg});
                                                        _ ->
                                                            ?log_info("Got exit not from child ebucketgrator. Assuming it's our parent: ~p", [ExitMsg]),
                                                            exit(Reason)
                                                    end
                                            after ?COMPLETION_POLLING_INTERVAL ->
                                                    ok
                                            end
                                    end),

              sync_shutdown_many(StopEarlyReplicators),

              AfterDone(),

              %% when replications are up to date, just wait death
              %% signal
              receive
                  {'EXIT', _, _} = ExMsg ->
                      self() ! ExMsg
              end
      end,
      fun () ->
              try_with_maybe_ignorant_after(
                fun () ->
                        sync_shutdown_many(ContinuousReplicators)
                end,
                fun () ->
                        kill_tap_names(Bucket, VBucket, SrcNode, JustBackfillNodes ++ ReplicateIntoNodes)
                end)
      end),
    receive
        {'EXIT', _From, Reason} = ExitMsg ->
            ?log_info("Got exit: ~p", [ExitMsg]),
            exit(Reason)
    after 0 ->
            ok
    end.

%% NOTE: this assumes that caller is trapping exits
-spec sync_shutdown_many(Pids :: [pid()]) -> ok.
sync_shutdown_many(Pids) ->
    BadShutdowns = [{P, RV} || P <- Pids,
                               (RV = sync_shutdown(P)) =/= shutdown],
    case BadShutdowns of
        [] -> ok;
        _ ->
            ?log_error("Shutdown of the following failed: ~p", [BadShutdowns])
    end,
    [] = BadShutdowns,
    ok.

%% NOTE: this assumes that caller is trapping exits
-spec sync_shutdown(Pid :: pid()) -> term().
sync_shutdown(Pid) ->
    (catch erlang:exit(Pid, shutdown)),
    MRef = erlang:monitor(process, Pid),
    MRefReason = receive
                     {'DOWN', MRef, _, _, MRefReason0} ->
                         MRefReason0
                 end,
    receive
        {'EXIT', Pid, Reason} ->
            Reason
    after 5000 ->
            ?log_error("Expected exit signal from ~p but could not get it in 5 seconds. This is a bug, but process we're waiting for is dead (~p), so trying to ignore...", [Pid, MRefReason]),
            ?log_debug("Here's messages:~n~p", [erlang:process_info(self(), messages)]),
            MRefReason
    end.


tap_name(VBucket, _SrcNode, DstNode) ->
    lists:flatten(io_lib:format("building_~p_~p", [VBucket, DstNode])).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

kill_a_bunch_of_tap_names(Bucket, Node, TapNames) ->
    Config = ns_config:get(),
    User = ns_config:search_node_prop(Node, Config, memcached, admin_user),
    Pass = ns_config:search_node_prop(Node, Config, memcached, admin_pass),
    McdPair = {Host, Port} = ns_memcached:host_port(Node),
    {ok, Sock} = gen_tcp:connect(Host, Port, [binary,
                                              {packet, 0},
                                              {active, false},
                                              {nodelay, true},
                                              {delay_send, true}]),
    UserBin = mc_binary:bin(User),
    PassBin = mc_binary:bin(Pass),
    SenderPid = spawn_link(fun () ->
                                   ok = mc_binary:send(Sock, req, #mc_header{opcode = ?CMD_SASL_AUTH},
                                                       #mc_entry{key = <<"PLAIN">>,
                                                                 data = <<UserBin/binary, 0:8,
                                                                          UserBin/binary, 0:8,
                                                                          PassBin/binary, 0:8>>}),
                                   ok = mc_binary:send(Sock, req, #mc_header{opcode = ?CMD_SELECT_BUCKET},
                                                       #mc_entry{key = iolist_to_binary(Bucket)}),
                                   [ok = mc_binary:send(Sock, req, #mc_header{opcode = ?CMD_DEREGISTER_TAP_CLIENT}, #mc_entry{key = TapName})
                                    || TapName <- TapNames]
                           end),
    try
        {ok, #mc_header{status = ?SUCCESS}, _} = mc_binary:recv(Sock, res, infinity), % CMD_SASL_AUTH
        {ok, #mc_header{status = ?SUCCESS}, _} = mc_binary:recv(Sock, res, infinity), % CMD_SELECT_BUCKET
        [{ok, #mc_header{status = ?SUCCESS}, _} = mc_binary:recv(Sock, res, infinity) || _TapName <- TapNames]
    after
        erlang:unlink(SenderPid),
        erlang:exit(SenderPid, kill),
        misc:wait_for_process(SenderPid, infinity)
    end,
    ?log_info("Killed the following tap names on ~p: ~p", [Node, TapNames]),
    ok = gen_tcp:close(Sock),
    [master_activity_events:note_deregister_tap_name(Bucket, McdPair, AName) || AName <- TapNames],
    receive
        {'EXIT', SenderPid, Reason} ->
            normal = Reason
    after 0 ->
            ok
    end,
    ok.

kill_tap_names(Bucket, VBucket, SrcNode, DstNodes) ->
    kill_a_bunch_of_tap_names(Bucket, SrcNode,
                              [iolist_to_binary([<<"replication_">>, tap_name(VBucket, SrcNode, DNode)]) || DNode <- DstNodes]).

spawn_replica_builder(Bucket, VBucket, SrcNode, DstNode) ->
    {User, Pass} = ns_bucket:credentials(Bucket),
    Opts = [{vbuckets, [VBucket]},
            {takeover, false},
            {suffix, tap_name(VBucket, SrcNode, DstNode)},
            {username, User},
            {password, Pass}],
    case ebucketmigrator_srv:start_link(DstNode,
                                        ns_memcached:host_port(SrcNode),
                                        ns_memcached:host_port(DstNode),
                                        Opts) of
        {ok, Pid} ->
            ?log_debug("Replica building ebucketmigrator for vbucket ~p into ~p is ~p", [VBucket, DstNode, Pid]),
            Pid;
        Error ->
            ?log_debug("Failed to spawn ebucketmigrator_srv for replica building: ~p",
                       [{VBucket, SrcNode, DstNode}]),
            spawn_link(fun () ->
                               exit({start_link_failed, VBucket, SrcNode, DstNode, Error})
                       end)
    end.

-spec filter_true_producers(list(), set(), binary()) -> [binary()].
filter_true_producers(PList, TapNamesSet, StatName) ->
    [TapName
     || {<<"eq_tapq:replication_", Key/binary>>, <<"true">>} <- PList,
        TapName <- case misc:split_binary_at_char(Key, $:) of
                       {TapName0, StatName} ->
                           sets:is_element(TapName0, TapNamesSet),
                           [TapName0];
                       _ ->
                           []
                   end].

extract_complete_taps(PList, TapNames) ->
    sets:from_list(filter_true_producers(PList, TapNames, <<"backfill_completed">>)).

observe_wait_all_done(Bucket, VBucket, SrcNode, DstNodes, Sleeper) ->
    TapNames = sets:from_list([iolist_to_binary(tap_name(VBucket, SrcNode, DN)) || DN <- DstNodes]),
    observe_wait_all_done_tail(Bucket, SrcNode, Sleeper, TapNames, true),
    wait_checkpoint_opened(Bucket, VBucket, DstNodes, Sleeper, true).

observe_wait_all_done_tail(Bucket, SrcNode, Sleeper, TapNames, FirstTime) ->
    case sets:size(TapNames) of
        0 ->
            ok;
        _ ->
            if not FirstTime ->
                    system_stats_collector:increment_counter(replicas_builder_backfill_sleeps, 1),
                    Sleeper();
               true ->
                    ok
            end,
            {ok, PList} = ns_memcached:stats(SrcNode, Bucket, <<"tap">>),
            DoneTaps = extract_complete_taps(PList, TapNames),
            NewTapNames = sets:subtract(TapNames, DoneTaps),
            observe_wait_all_done_tail(Bucket, SrcNode, Sleeper, NewTapNames, false)
    end.

wait_checkpoint_opened(_Bucket, _VBucket, [], _Sleeper, _FirstTime) ->
    ok;
wait_checkpoint_opened(Bucket, VBucket, DstNodes, Sleeper, FirstTime) ->
    case FirstTime of
        false ->
            system_stats_collector:increment_counter(replicas_builder_checkpoint_sleeps, 1),
            Sleeper();
        true -> ok
    end,
    Checkpoints = ns_memcached:get_vbucket_open_checkpoint(DstNodes, Bucket, VBucket),
    NodesLeft = [N || {N, Checkpoint} <- Checkpoints,
                      Checkpoint =:= 0 orelse
                          case Checkpoint of
                              missing ->
                                  ?log_error("Node ~p did not have checkpoint stat for vbucket: ~p", [N, VBucket]),
                                  exit({missing_checkpoint_stat, N, VBucket});
                              _ ->
                                  false
                          end],
    wait_checkpoint_opened(Bucket, VBucket, NodesLeft, Sleeper, false).
