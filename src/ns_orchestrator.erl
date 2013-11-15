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

-type reply_to() :: [{pid(), any()}].
-type bucket_request() :: [{bucket_name(), reply_to()}].
-record(idle_state, {remaining_buckets = [] :: bucket_request()}).
-record(janitor_state, {remaining_buckets :: bucket_request(),
                        pid}).
-record(rebalancing_state, {rebalancer, progress,
                            keep_nodes, eject_nodes, failed_nodes}).
-record(recovery_state, {uuid :: binary(),
                         bucket :: bucket_name(),
                         recoverer_state :: any()}).


%% API
-export([create_bucket/3,
         update_bucket/3,
         delete_bucket/1,
         flush_bucket/1,
         failover/1,
         try_autofailover/1,
         needs_rebalance/0,
         request_janitor_run/1,
         rebalance_progress/0,
         rebalance_progress_full/0,
         start_link/0,
         start_rebalance/2,
         stop_rebalance/0,
         update_progress/1,
         is_rebalance_running/0,
         start_recovery/1,
         stop_recovery/2,
         commit_vbucket/3,
         recovery_status/0,
         recovery_map/2,
         is_recovery_running/0,
         set_replication_topology/1,
         run_cleanup/1,
         ensure_janitor_run/1]).

-define(SERVER, {global, ?MODULE}).

-define(REBALANCE_SUCCESSFUL, 1).
-define(REBALANCE_FAILED, 2).
-define(REBALANCE_NOT_STARTED, 3).
-define(REBALANCE_STARTED, 4).
-define(REBALANCE_PROGRESS, 5).
-define(FAILOVER_NODE, 6).
-define(REBALANCE_STOPPED, 7).

-define(DELETE_BUCKET_TIMEOUT, 30000).
-define(FLUSH_BUCKET_TIMEOUT, 60000).
-define(CREATE_BUCKET_TIMEOUT, 5000).

%% gen_fsm callbacks
-export([code_change/4,
         init/1,
         handle_event/3,
         handle_info/3,
         handle_sync_event/4,
         terminate/3]).

%% States
-export([idle/2, idle/3,
         janitor_running/2, janitor_running/3,
         rebalancing/2, rebalancing/3,
         recovery/2, recovery/3]).


%%
%% API
%%

start_link() ->
    misc:start_singleton(gen_fsm, ?MODULE, [], []).

wait_for_orchestrator() ->
    misc:wait_for_global_name(?MODULE, 20000).


-spec create_bucket(memcached|membase, nonempty_string(), list()) ->
                           ok | {error, {already_exists, nonempty_string()}} |
                           {error, {still_exists, nonempty_string()}} |
                           {error, {port_conflict, integer()}} |
                           {error, {invalid_name, nonempty_string()}} |
                           rebalance_running | in_recovery.
create_bucket(BucketType, BucketName, NewConfig) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {create_bucket, BucketType, BucketName,
                                      NewConfig}, infinity).

-spec update_bucket(memcached|membase, nonempty_string(), list()) ->
                           ok | {exit, {not_found, nonempty_string()}, []}.
update_bucket(BucketType, BucketName, UpdatedProps) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_all_state_event(?SERVER, {update_bucket, BucketType, BucketName,
                                                UpdatedProps}, infinity).

%% Deletes bucket. Makes sure that once it returns it's already dead.
%% In implementation we make sure config deletion is propagated to
%% child nodes. And that ns_memcached for bucket being deleted
%% dies. But we don't wait more than ?DELETE_BUCKET_TIMEOUT.
%%
%% Return values are ok if it went fine at least on local node
%% (failure to stop ns_memcached on any nodes is merely logged);
%% rebalance_running if delete bucket request came while rebalancing;
%% and {exit, ...} if bucket does not really exists
-spec delete_bucket(bucket_name()) ->
                           ok | rebalance_running | in_recovery |
                           {shutdown_failed, [node()]} | {exit, {not_found, bucket_name()}, _}.
delete_bucket(BucketName) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {delete_bucket, BucketName}, infinity).

-spec flush_bucket(bucket_name()) ->
                          ok |
                          rebalance_running |
                          in_recovery |
                          bucket_not_found |
                          flush_disabled |
                          not_supported |       % if we're in 1.8.x compat mode and trying to flush couchbase bucket
                          {prepare_flush_failed, _, _} |
                          {initial_config_sync_failed, _} |
                          {flush_config_sync_failed, _} |
                          {flush_wait_failed, _, _} |
                          {old_style_flush_failed, _, _}.
flush_bucket(BucketName) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {flush_bucket, BucketName}, infinity).


-spec failover(atom()) -> ok | rebalance_running | in_recovery.
failover(Node) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {failover, Node}, infinity).


-spec try_autofailover(atom()) -> ok | rebalance_running | in_recovery |
                                  {autofailover_unsafe, [bucket_name()]}.
try_autofailover(Node) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {try_autofailover, Node}, infinity).


-spec needs_rebalance() -> boolean().
needs_rebalance() ->
    needs_rebalance(ns_node_disco:nodes_wanted()).


-spec needs_rebalance([atom(), ...]) -> boolean().
needs_rebalance(Nodes) ->
    Topology = cluster_compat_mode:get_replication_topology(),
    lists:any(fun ({_, BucketConfig}) ->
                      needs_rebalance(Nodes, BucketConfig, Topology)
              end,
              ns_bucket:get_buckets()).

-spec rebalance_progress_full() -> {running, [{atom(), float()}]} | not_running.
rebalance_progress_full() ->
    gen_fsm:sync_send_event(?SERVER, rebalance_progress, 2000).

-spec rebalance_progress() -> {running, [{atom(), float()}]} | not_running.
rebalance_progress() ->
    try rebalance_progress_full()
    catch
        Type:Err ->
            ?log_error("Couldn't talk to orchestrator: ~p", [{Type, Err}]),
            not_running
    end.


request_janitor_run(BucketName) ->
    gen_fsm:send_event(?SERVER, {request_janitor_run, BucketName}).

-spec ensure_janitor_run(bucket_name()) ->
                                ok |
                                in_recovery |
                                rebalance_running |
                                janitor_failed |
                                bucket_deleted.
ensure_janitor_run(BucketName) ->
    wait_for_orchestrator(),
    misc:poll_for_condition(
      fun () ->
              case gen_fsm:sync_send_event(?SERVER, {ensure_janitor_run, BucketName}, infinity) of
                  warming_up ->
                      false;
                  shutdown ->
                      false;
                  Ret ->
                      Ret
              end
      end, infinity, 1000).

-spec start_rebalance([node()], [node()]) ->
                             ok | in_progress | already_balanced |
                             nodes_mismatch | no_active_nodes_left | in_recovery.
start_rebalance(KnownNodes, EjectNodes) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_all_state_event(?SERVER, {maybe_start_rebalance, KnownNodes, EjectNodes}).


-spec stop_rebalance() -> ok | not_rebalancing.
stop_rebalance() ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, stop_rebalance).


-spec start_recovery(bucket_name()) ->
                            {ok, UUID, RecoveryMap} |
                            unsupported |
                            rebalance_running |
                            not_present |
                            not_needed |
                            {error, {failed_nodes, [node()]}}
  when UUID :: binary(),
       RecoveryMap :: dict().
start_recovery(Bucket) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {start_recovery, Bucket}).

-spec recovery_status() -> not_in_recovery | {ok, Status}
  when Status :: [{bucket, bucket_name()} |
                  {uuid, binary()} |
                  {recovery_map, RecoveryMap}],
       RecoveryMap :: dict().
recovery_status() ->
    case is_recovery_running() of
        false ->
            not_in_recovery;
        _ ->
            wait_for_orchestrator(),
            gen_fsm:sync_send_all_state_event(?SERVER, recovery_status)
    end.

-spec recovery_map(bucket_name(), UUID) -> bad_recovery | {ok, RecoveryMap}
  when RecoveryMap :: dict(),
       UUID :: binary().
recovery_map(Bucket, UUID) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_all_state_event(?SERVER, {recovery_map, Bucket, UUID}).

-spec commit_vbucket(bucket_name(), UUID, vbucket_id()) ->
                            ok | recovery_completed |
                            vbucket_not_found | bad_recovery |
                            {error, {failed_nodes, [node()]}}
  when UUID :: binary().
commit_vbucket(Bucket, UUID, VBucket) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_all_state_event(?SERVER, {commit_vbucket, Bucket, UUID, VBucket}).

-spec stop_recovery(bucket_name(), UUID) -> ok | bad_recovery
  when UUID :: binary().
stop_recovery(Bucket, UUID) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_all_state_event(?SERVER, {stop_recovery, Bucket, UUID}).

-spec is_recovery_running() -> boolean().
is_recovery_running() ->
    case ns_config:search(recovery_status) of
        {value, {running, _Bucket, _UUID}} ->
            true;
        _ ->
            false
    end.

-spec set_replication_topology(chain | star) ->
                                      ok | rebalance_running | in_recovery.
set_replication_topology(Topology) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER,
                            {set_replication_topology, Topology}, infinity).

%%
%% gen_fsm callbacks
%%

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.


init([]) ->
    process_flag(trap_exit, true),
    self() ! janitor,
    timer2:send_interval(10000, janitor),

    try
        consider_switching_compat_mode()
    catch exit:normal ->
            %% There's no need to restart us here. So if we've changed compat mode in init suppress exit
            ok
    end,

    {ok, idle, #idle_state{}}.


handle_event(Event, StateName, State) ->
    {stop, {unhandled, Event, StateName}, State}.


handle_sync_event({update_bucket, BucketType, BucketName, UpdatedProps}, _From, StateName, State) ->
    Reply = ns_bucket:update_bucket_props(BucketType, BucketName, UpdatedProps),
    case Reply of
        ok ->
            %% request janitor run to fix map if the replica # has changed
            request_janitor_run(BucketName);
        _ -> ok
    end,
    {reply, Reply, StateName, State};

handle_sync_event({maybe_start_rebalance, KnownNodes, EjectedNodes},
                  From, StateName, State) ->
    case {EjectedNodes -- KnownNodes,
          lists:sort(ns_node_disco:nodes_wanted()),
          lists:sort(KnownNodes)} of
        {[], X, X} ->
            MaybeKeepNodes = KnownNodes -- EjectedNodes,
            FailedNodes =
                [N || {N, MShip} <-
                          ns_cluster_membership:get_nodes_cluster_membership(KnownNodes),
                      MShip == inactiveFailed],
            KeepNodes = MaybeKeepNodes -- FailedNodes,
            case KeepNodes of
                [] ->
                    {reply, no_active_nodes_left, StateName, State};
                _ ->
                    ns_cluster_membership:activate(KeepNodes),
                    StartEvent = {start_rebalance,
                                  KeepNodes,
                                  EjectedNodes -- FailedNodes,
                                  FailedNodes},
                    ?MODULE:StateName(StartEvent, From, State)
            end;
        _ ->
            {reply, nodes_mismatch, StateName, State}
    end;

handle_sync_event(recovery_status, From, StateName, State) ->
    case StateName of
        recovery ->
            ?MODULE:recovery(recovery_status, From, State);
        _ ->
            {reply, not_in_recovery, StateName, State}
    end;
handle_sync_event(Msg, From, StateName, State)
  when element(1, Msg) =:= recovery_map;
       element(1, Msg) =:= commit_vbucket;
       element(1, Msg) =:= stop_recovery ->
    case StateName of
        recovery ->
            Bucket = element(2, Msg),
            UUID = element(3, Msg),

            #recovery_state{bucket=BucketInRecovery,
                            uuid=RecoveryUUID} = State,

            case Bucket =:= BucketInRecovery andalso UUID =:= RecoveryUUID of
                true ->
                    ?MODULE:recovery(Msg, From, State);
                false ->
                    {reply, bad_recovery, recovery, State}
            end;
        _ ->
            {reply, bad_recovery, StateName, State}
    end;

handle_sync_event(Event, _From, StateName, State) ->
    {stop, {unhandled, Event, StateName}, State}.

handle_info(janitor, idle, #idle_state{remaining_buckets=[]} = State) ->
    case ns_bucket:get_bucket_names(membase) of
        [] ->
            consider_switching_compat_mode(),
            {next_state, idle, State#idle_state{remaining_buckets=[]}};
        Buckets ->
            handle_info(janitor, idle,
                        State#idle_state{remaining_buckets=[{Bucket, []}|| Bucket <- Buckets]})
    end;
handle_info(janitor, idle, #idle_state{remaining_buckets=BucketRequests}) ->
    misc:verify_name(?MODULE), % MB-3180: Make sure we're still registered
    maybe_drop_recovery_status(),
    {Bucket, _} = hd(BucketRequests),
    Pid = proc_lib:spawn_link(?MODULE, run_cleanup, [Bucket]),
    %% NOTE: Bucket will be popped from Buckets when janitor run will
    %% complete successfully
    {next_state, janitor_running, #janitor_state{remaining_buckets=BucketRequests,
                                                 pid = Pid}};
handle_info(janitor, StateName, StateData) ->
    ?log_info("Skipping janitor in state ~p", [StateName]),
    {next_state, StateName, StateData};
handle_info({'EXIT', Pid, Reason}, janitor_running,
            #janitor_state{pid = Pid,
                           remaining_buckets = [{Bucket, _ReplyTo} = BucketRequest|BucketRequests]}) ->
    Ret = case Reason of
              shutdown ->
                  shutdown;
              normal ->
                  ok;
              {shutdown, {error, wait_for_memcached_failed, _}} ->
                  warming_up;
              _ ->
                  ?log_warning("Janitor run exited for bucket ~p with reason ~p~n",
                               [Bucket, Reason]),
                  janitor_failed
          end,
    notify_janitor_finished(BucketRequest, Ret),
    case BucketRequests of
        [] ->
            ok;
        _ ->
            self() ! janitor
    end,
    consider_switching_compat_mode(),
    {next_state, idle, #idle_state{remaining_buckets = BucketRequests}};
handle_info({'EXIT', Pid, Reason}, rebalancing,
            #rebalancing_state{rebalancer=Pid,
                               keep_nodes=KeepNodes,
                               eject_nodes=EjectNodes,
                               failed_nodes=FailedNodes}) ->
    Status = case Reason of
                 normal ->
                     ?user_log(?REBALANCE_SUCCESSFUL,
                               "Rebalance completed successfully.~n"),
                     ns_cluster:counter_inc(rebalance_success),
                     none;
                 stopped ->
                     ?user_log(?REBALANCE_STOPPED,
                               "Rebalance stopped by user.~n"),
                     ns_cluster:counter_inc(rebalance_stop),
                     none;
                 _ ->
                     ?user_log(?REBALANCE_FAILED,
                               "Rebalance exited with reason ~p~n", [Reason]),
                     ns_cluster:counter_inc(rebalance_fail),
                     {none, <<"Rebalance failed. See logs for detailed reason. "
                              "You can try rebalance again.">>}
             end,

    ns_config:set([{rebalance_status, Status},
                   {rebalancer_pid, undefined}]),
    rpc:eval_everywhere(diag_handler, log_all_tap_and_checkpoint_stats, []),
    case (lists:member(node(), EjectNodes) andalso Reason =:= normal) orelse
        lists:member(node(), FailedNodes) of
        true ->
            ns_config:sync_announcements(),
            ns_config_rep:push(),
            ok = ns_config_rep:synchronize_remote(KeepNodes),
            ns_rebalancer:eject_nodes([node()]);
        false ->
            ok
    end,
    consider_switching_compat_mode(),
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

%% Asynchronous idle events
idle({request_janitor_run, BucketName}, State) ->
    do_request_janitor_run({BucketName, []}, idle, State);
idle(_Event, State) ->
    %% This will catch stray progress messages
    {next_state, idle, State}.

janitor_running({request_janitor_run, BucketName}, State) ->
    do_request_janitor_run({BucketName, []}, janitor_running, State);
janitor_running(_Event, State) ->
    {next_state, janitor_running, State}.

%% Synchronous idle events
idle({create_bucket, BucketType, BucketName, NewConfig}, _From, State) ->
    Reply = case ns_bucket:name_conflict(BucketName) of
                false ->
                    {Results, FailedNodes} = rpc:multicall(ns_node_disco:nodes_wanted(), ns_memcached, active_buckets, [], ?CREATE_BUCKET_TIMEOUT),
                    case FailedNodes of
                        [] -> ok;
                        _ ->
                            ?log_warning("Best-effort check for presense of bucket failed to be made on following nodes: ~p", FailedNodes)
                    end,
                    case lists:any(fun (StartedBucket) ->
                                           ns_bucket:names_conflict(StartedBucket, BucketName)
                                   end, lists:append(Results)) of
                        true ->
                            {error, {still_exists, BucketName}};
                        _ ->
                            ns_bucket:create_bucket(BucketType, BucketName, NewConfig)
                        end;
                true ->
                    {error, {already_exists, BucketName}}
            end,
    case Reply of
        ok ->
            master_activity_events:note_bucket_creation(BucketName, BucketType, NewConfig),
            request_janitor_run(BucketName);
        _ -> ok
    end,
    {reply, Reply, idle, State};
idle({flush_bucket, BucketName}, _From, State) ->
    perform_bucket_flushing(BucketName, State);
idle({delete_bucket, BucketName}, _From,
     #idle_state{remaining_buckets=RemainingBuckets} = State) ->
    DeleteRV = ns_bucket:delete_bucket_returning_config(BucketName),
    NewState =
        case DeleteRV of
            {ok, _} ->
                master_activity_events:note_bucket_deletion(BucketName),
                ns_config:sync_announcements(),
                State#idle_state{remaining_buckets=
                                     delete_bucket_request(BucketName, RemainingBuckets)};
            _ ->
                State
        end,

    Reply =
        case DeleteRV of
            {ok, BucketConfig} ->
                Nodes = ns_bucket:bucket_nodes(BucketConfig),
                Pred = fun (Active) ->
                               not lists:member(BucketName, Active)
                       end,
                LeftoverNodes =
                    case wait_for_nodes(Nodes, Pred, ?DELETE_BUCKET_TIMEOUT) of
                        ok ->
                            [];
                        {timeout, LeftoverNodes0} ->
                            ?log_warning("Nodes ~p failed to delete bucket ~p "
                                         "within expected time.",
                                         [LeftoverNodes0, BucketName]),
                            LeftoverNodes0
                    end,

                LiveNodes = Nodes -- LeftoverNodes,

                ?log_info("Restarting moxi on nodes ~p", [LiveNodes]),
                case multicall_moxi_restart(LiveNodes, ?DELETE_BUCKET_TIMEOUT) of
                    ok ->
                        ok;
                    FailedNodes ->
                        ?log_warning("Failed to restart moxi on following nodes ~p",
                                     [FailedNodes])
                end,
                case LeftoverNodes of
                    [] ->
                        ok;
                    _ ->
                        {shutdown_failed, LeftoverNodes}
                end;
            _ ->
                DeleteRV
    end,

    {reply, Reply, idle, NewState};
idle({failover, Node}, _From, State) ->
    ale:info(?USER_LOGGER, "Starting failing over ~p", [Node]),
    master_activity_events:note_failover(Node),
    Result = ns_rebalancer:failover(Node),
    ?user_log(?FAILOVER_NODE, "Failed over ~p: ~p", [Node, Result]),
    ns_cluster:counter_inc(failover_node),
    ns_config:set({node, Node, membership}, inactiveFailed),
    {reply, Result, idle, State};
idle({try_autofailover, Node}, From, State) ->
    case ns_rebalancer:validate_autofailover(Node) of
        {error, UnsafeBuckets} ->
            {reply, {autofailover_unsafe, UnsafeBuckets}, idle, State};
        ok ->
            idle({failover, Node}, From, State)
    end;
idle(rebalance_progress, _From, State) ->
    {reply, not_running, idle, State};
%% NOTE: this is not remotely called but is used by maybe_start_rebalance
idle({start_rebalance, KeepNodes, EjectNodes, FailedNodes}, _From,
            #idle_state{remaining_buckets = RemainingBuckets}) ->
    ?user_log(?REBALANCE_STARTED,
              "Starting rebalance, KeepNodes = ~p, EjectNodes = ~p~n",
              [KeepNodes, EjectNodes]),
    notify_janitor_finished(RemainingBuckets, rebalance_running),
    ns_cluster:counter_inc(rebalance_start),
    Pid = spawn_link(
            fun () ->
                    master_activity_events:note_rebalance_start(self(), KeepNodes, EjectNodes, FailedNodes),
                    ns_rebalancer:rebalance(KeepNodes, EjectNodes, FailedNodes)
            end),
    ns_config:set([{rebalance_status, running},
                   {rebalancer_pid, Pid}]),
    {reply, ok, rebalancing,
     #rebalancing_state{rebalancer=Pid,
                        progress=dict:new(),
                        keep_nodes=KeepNodes,
                        eject_nodes=EjectNodes,
                        failed_nodes=FailedNodes}};
idle({move_vbuckets, Bucket, Moves}, _From, #idle_state{remaining_buckets = RemainingBuckets}) ->
    notify_janitor_finished(RemainingBuckets, rebalance_running),
    Pid = spawn_link(
            fun () ->
                    {ok, Config} = ns_bucket:get_bucket(Bucket),
                    Map = proplists:get_value(map, Config),
                    TMap = lists:foldl(fun ({VBucket, TargetChain}, Map0) ->
                                               setelement(VBucket+1, Map0, TargetChain)
                                       end, list_to_tuple(Map), Moves),
                    NewMap = tuple_to_list(TMap),
                    ns_rebalancer:run_mover(Bucket, Config, proplists:get_value(servers, Config),
                                            0, 1, Map, NewMap)
            end),
    ns_config:set([{rebalance_status, running},
                   {rebalancer_pid, Pid}]),
    {reply, ok, rebalancing,
     #rebalancing_state{rebalancer=Pid,
                        progress=dict:new()}};
idle(stop_rebalance, _From, State) ->
    ns_janitor:stop_rebalance_status(
      fun () ->
              ?user_log(?REBALANCE_STOPPED,
                        "Resetting rebalance status since rebalance stop was "
                        "requested but rebalance isn't orchestrated on our node"),
              none
      end),
    {reply, not_rebalancing, idle, State};
idle({start_recovery, Bucket}, {FromPid, _} = _From,
     #idle_state{remaining_buckets = RemainingBuckets} = State) ->
    try

        BucketConfig0 = case ns_bucket:get_bucket(Bucket) of
                            {ok, V} ->
                                V;
                            Error0 ->
                                throw(Error0)
                        end,

        case ns_bucket:bucket_type(BucketConfig0) of
            membase ->
                ok;
            _ ->
                throw(not_needed)
        end,

        FailedOverNodes = [N || {N, inactiveFailed} <- ns_cluster_membership:get_nodes_cluster_membership()],
        Servers = ns_node_disco:nodes_wanted() -- FailedOverNodes,
        BucketConfig = misc:update_proplist(BucketConfig0, [{servers, Servers}]),
        ns_cluster_membership:activate(Servers),
        ns_config:sync_announcements(),
        FromPidNode = erlang:node(FromPid),
        SyncServers = Servers -- [FromPidNode] ++ [FromPidNode],
        case ns_config_rep:synchronize_remote(SyncServers) of
            ok ->
                ok;
            {error, BadNodes} ->
                ?log_error("Failed to syncrhonize config to some nodes: ~p", [BadNodes]),
                throw({error, {failed_nodes, BadNodes}})
        end,

        case ns_rebalancer:maybe_cleanup_old_buckets(Servers) of
            ok ->
                ok;
            {buckets_cleanup_failed, FailedNodes0} ->
                throw({error, {failed_nodes, FailedNodes0}})
        end,

        ns_bucket:set_servers(Bucket, Servers),

        case ns_janitor:cleanup(Bucket, [{timeout, 10}]) of
            ok ->
                ok;
            {error, _, FailedNodes1} ->
                error({error, {failed_nodes, FailedNodes1}})
        end,

        {ok, RecoveryMap, {NewServers, NewBucketConfig}, RecovererState} =
            case recoverer:start_recovery(BucketConfig) of
                {ok, _, _, _} = R ->
                    R;
                Error1 ->
                    throw(Error1)
            end,

        true = (Servers =:= NewServers),

        RV = apply_recoverer_bucket_config(Bucket, NewBucketConfig, NewServers),
        case RV of
            ok ->
                RecoveryUUID = couch_uuids:random(),
                NewState =
                    #recovery_state{bucket=Bucket,
                                    uuid=RecoveryUUID,
                                    recoverer_state=RecovererState},

                ensure_recovery_status(Bucket, RecoveryUUID),

                ale:info(?USER_LOGGER, "Put bucket `~s` into recovery mode", [Bucket]),

                notify_janitor_finished(RemainingBuckets, in_recovery),
                {reply, {ok, RecoveryUUID, RecoveryMap}, recovery, NewState};
            Error2 ->
                throw(Error2)
        end

    catch
        throw:E ->
            {reply, E, idle, State}
    end;
idle({set_replication_topology, Topology}, _From, State) ->
    CurrentTopology = cluster_compat_mode:get_replication_topology(),
    case CurrentTopology =:= Topology of
        true ->
            ok;
        false ->
            ale:info(?USER_LOGGER, "Switching replication topology from ~s to ~s",
                     [CurrentTopology, Topology]),
            ns_config:set(replication_topology, Topology),
            ns_config:sync_announcements(),
            lists:foreach(fun request_janitor_run/1, ns_bucket:get_bucket_names())
    end,
    {reply, ok, idle, State};
idle({ensure_janitor_run, BucketName}, From, State) ->
    do_request_janitor_run({BucketName, [From]}, idle, State).

janitor_running(rebalance_progress, _From, State) ->
    {reply, not_running, janitor_running, State};
janitor_running(Msg, From, #janitor_state{pid=Pid} = State) ->
    %% when handling some call while janitor is running we kill janitor
    exit(Pid, shutdown),
    %% than await that it's dead and handle it's death message
    {next_state, idle, NextState}
        = receive
              {'EXIT', Pid, _} = DeathMsg ->
                  handle_info(DeathMsg, janitor_running, State)
          end,
    %% and than handle original call in idle state
    idle(Msg, From, NextState);
janitor_running({ensure_janitor_run, BucketName}, From, State) ->
    do_request_janitor_run({BucketName, [From]}, janitor_running, State).

%% Asynchronous rebalancing events
rebalancing({update_progress, Progress},
            #rebalancing_state{progress=Old} = State) ->
    NewProgress = dict:merge(fun (_, _, New) -> New end, Old, Progress),
    {next_state, rebalancing,
     State#rebalancing_state{progress=NewProgress}}.

%% Synchronous rebalancing events
rebalancing({start_rebalance, _KeepNodes, _EjectNodes, _FailedNodes},
            _From, State) ->
    ?user_log(?REBALANCE_NOT_STARTED,
              "Not rebalancing because rebalance is already in progress.~n"),
    {reply, in_progress, rebalancing, State};
rebalancing(stop_rebalance, _From,
            #rebalancing_state{rebalancer=Pid} = State) ->
    Pid ! stop,
    {reply, ok, rebalancing, State};
rebalancing(rebalance_progress, _From,
            #rebalancing_state{progress = Progress} = State) ->
    {reply, {running, dict:to_list(Progress)}, rebalancing, State};
rebalancing(Event, _From, State) ->
    ?log_warning("Got event ~p while rebalancing.", [Event]),
    {reply, rebalance_running, rebalancing, State}.

recovery(Event, State) ->
    ?log_warning("Got unexpected event: ~p", [Event]),
    {next_state, recovery_running, State}.

recovery({start_recovery, Bucket}, _From,
         #recovery_state{bucket=BucketInRecovery,
                         uuid=RecoveryUUID,
                         recoverer_state=RState} = State) ->
    case Bucket =:= BucketInRecovery of
        true ->
            RecoveryMap = recoverer:get_recovery_map(RState),
            {reply, {ok, RecoveryUUID, RecoveryMap}, recovery, State};
        false ->
            {reply, recovery_running, recovery, State}
    end;

recovery({commit_vbucket, Bucket, UUID, VBucket}, _From,
         #recovery_state{recoverer_state=RState} = State) ->
    Bucket = State#recovery_state.bucket,
    UUID = State#recovery_state.uuid,

    case recoverer:commit_vbucket(VBucket, RState) of
        {ok, {Servers, NewBucketConfig}, RState1} ->
            RV = apply_recoverer_bucket_config(Bucket, NewBucketConfig, Servers),
            case RV of
                ok ->
                    {ok, Map, RState2} = recoverer:note_commit_vbucket_done(VBucket, RState1),
                    ns_bucket:set_map(Bucket, Map),
                    case recoverer:is_recovery_complete(RState2) of
                        true ->
                            ale:info(?USER_LOGGER, "Recovery of bucket `~s` completed", [Bucket]),
                            {reply, recovery_completed, idle, #idle_state{}};
                        false ->
                            ?log_debug("Committed vbucket ~b (recovery of `~s`)", [VBucket, Bucket]),
                            {reply, ok, recovery,
                             State#recovery_state{recoverer_state=RState2}}
                    end;
                Error ->
                    {reply, Error, recovery,
                     State#recovery_state{recoverer_state=RState1}}
            end;
        Error ->
            {reply, Error, recovery, State}
    end;

recovery({stop_recovery, Bucket, UUID}, _From, State) ->
    Bucket = State#recovery_state.bucket,
    UUID = State#recovery_state.uuid,

    ns_config:set(recovery_status, not_running),

    ale:info(?USER_LOGGER, "Recovery of bucket `~s` aborted", [Bucket]),

    {reply, ok, idle, #idle_state{}};

recovery(recovery_status, _From,
         #recovery_state{uuid=RecoveryUUID,
                         bucket=Bucket,
                         recoverer_state=RState} = State) ->
    RecoveryMap = recoverer:get_recovery_map(RState),

    Status = [{bucket, Bucket},
              {uuid, RecoveryUUID},
              {recovery_map, RecoveryMap}],

    {reply, {ok, Status}, recovery, State};
recovery({recovery_map, Bucket, RecoveryUUID}, _From,
         #recovery_state{uuid=RecoveryUUID,
                         bucket=Bucket,
                         recoverer_state=RState} = State) ->
    RecoveryMap = recoverer:get_recovery_map(RState),
    {reply, {ok, RecoveryMap}, recovery, State};

recovery(rebalance_progress, _From, State) ->
    {reply, not_running, recovery, State};
recovery(stop_rebalance, _From, State) ->
    {reply, not_rebalancing, recovery, State};
recovery(_Event, _From, State) ->
    {reply, in_recovery, recovery, State}.


%%
%% Internal functions
%%

run_cleanup(Bucket) ->
    RV = ns_janitor:cleanup(Bucket, [consider_stopping_rebalance_status]),
    case RV of
        ok ->
            ok;
        Error ->
            exit({shutdown, Error})
    end.

add_bucket_request(BucketRequest, BucketRequests) ->
    add_bucket_request(BucketRequest, BucketRequests, []).

add_bucket_request(BucketRequest, [], Acc) ->
    {added, lists:reverse([BucketRequest|Acc])};
add_bucket_request({Bucket, NewReplyTo}, [{Bucket, ReplyTo} | T], Acc) ->
    {found, lists:reverse(Acc, [{Bucket, lists:umerge(ReplyTo, NewReplyTo)} | T])};
add_bucket_request({NewBucket, NewReplyTo}, [{Bucket, ReplyTo} | T], Acc) ->
    add_bucket_request({NewBucket, NewReplyTo}, T, [{Bucket, ReplyTo} | Acc]).

delete_bucket_request(BucketName, BucketRequests) ->
    case lists:keytake(BucketName, 1, BucketRequests) of
        false ->
            BucketRequests;
        {value, BucketRequest, NewBucketRequests} ->
            notify_janitor_finished(BucketRequest, bucket_deleted),
            ?log_debug("Deleted bucket ~p from remaining_buckets", [BucketName]),
            NewBucketRequests
    end.

notify_janitor_finished({_Bucket, ReplyTo}, Reason) ->
    lists:foreach(fun (To) ->
                          gen_fsm:reply(To, Reason)
                  end, ReplyTo);
notify_janitor_finished(BucketRequests, Reason) ->
    lists:foreach(fun (BucketRequest) ->
                          notify_janitor_finished(BucketRequest, Reason)
                  end, BucketRequests).

do_request_janitor_run(BucketRequest, FsmState, State) ->
    BucketRequests = case FsmState of
                         idle ->
                             State#idle_state.remaining_buckets;
                         janitor_running ->
                             State#janitor_state.remaining_buckets
                     end,
    {Oper, NewBucketRequests} = add_bucket_request(BucketRequest, BucketRequests),
    case FsmState of
        idle ->
            case Oper of
                added ->
                    self() ! janitor;
                found ->
                    consider_switching_compat_mode()
            end,
            {next_state, FsmState, State#idle_state{remaining_buckets = NewBucketRequests}};
        janitor_running ->
            {next_state, FsmState, State#janitor_state{remaining_buckets = NewBucketRequests}}
    end.

needs_rebalance(Nodes, BucketConfig, Topology) ->
    Servers = proplists:get_value(servers, BucketConfig, []),
    case proplists:get_value(type, BucketConfig) of
        membase ->
            case Servers of
                [] -> false;
                _ ->
                    Map = proplists:get_value(map, BucketConfig),
                    Map =:= undefined orelse
                        lists:sort(Nodes) /= lists:sort(Servers) orelse
                        ns_rebalancer:unbalanced(Map, Topology, BucketConfig)
            end;
        memcached ->
            lists:sort(Nodes) /= lists:sort(Servers)
    end.


-spec update_progress(dict()) -> ok.
update_progress(Progress) ->
    gen_fsm:send_event(?SERVER, {update_progress, Progress}).


wait_for_nodes_loop(Nodes) ->
    receive
        {done, Node} ->
            NewNodes = Nodes -- [Node],
            case NewNodes of
                [] ->
                    ok;
                _ ->
                    wait_for_nodes_loop(NewNodes)
            end;
        timeout ->
            {timeout, Nodes}
    end.

wait_for_nodes_check_pred(Status, Pred) ->
    Active = proplists:get_value(active_buckets, Status),
    case Active of
        undefined ->
            false;
        _ ->
            Pred(Active)
    end.

%% Wait till active buckets satisfy certain predicate on all nodes. After
%% `Timeout' milliseconds, we give up and return the list of leftover nodes.
-spec wait_for_nodes([node()],
                     fun(([string()]) -> boolean()),
                     timeout()) -> ok | {timeout, [node()]}.
wait_for_nodes(Nodes, Pred, Timeout) ->
    misc:executing_on_new_process(
        fun () ->
                Self = self(),

                ns_pubsub:subscribe_link(
                  buckets_events,
                  fun ({significant_buckets_change, Node}) ->
                          Status = ns_doctor:get_node(Node),

                          case wait_for_nodes_check_pred(Status, Pred) of
                              false ->
                                  ok;
                              true ->
                                  Self ! {done, Node}
                          end;
                      (_) ->
                          ok
                  end),

                Statuses = ns_doctor:get_nodes(),
                Nodes1 =
                    lists:filter(
                      fun (N) ->
                              Status = ns_doctor:get_node(N, Statuses),
                              not wait_for_nodes_check_pred(Status, Pred)
                      end, Nodes),

                erlang:send_after(Timeout, Self, timeout),
                wait_for_nodes_loop(Nodes1)
        end).

%% quickly and _without_ communication to potentially remote
%% ns_orchestrator find out if rebalance is running.
is_rebalance_running() ->
    ns_config:search(rebalance_status) =:= {value, running}.

consider_switching_compat_mode() ->
    CurrentVersion = cluster_compat_mode:get_compat_version(),

    case cluster_compat_mode:consider_switching_compat_mode() of
        changed ->
            NewVersion = cluster_compat_mode:get_compat_version(),
            ale:warn(?USER_LOGGER, "Changed cluster compat mode from ~p to ~p",
                     [CurrentVersion, NewVersion]),

            ok = ns_online_config_upgrader:upgrade_config(CurrentVersion, NewVersion),
            exit(normal);
        ok ->
            ok
    end.

perform_bucket_flushing(BucketName, State) ->
    case ns_bucket:get_bucket(BucketName) of
        not_present ->
            {reply, bucket_not_found, idle, State};
        {ok, BucketConfig} ->
            case proplists:get_value(flush_enabled, BucketConfig, false) of
                true ->
                    perform_bucket_flushing_with_config(BucketName, State, BucketConfig);
                false ->
                    {reply, flush_disabled, idle, State}
            end
    end.


perform_bucket_flushing_with_config(BucketName, State, BucketConfig) ->
    ale:info(?MENELAUS_LOGGER, "Flushing bucket ~p from node ~p", [BucketName, erlang:node()]),
    case ns_bucket:bucket_type(BucketConfig) =:= memcached of
        true ->
            {reply, do_flush_old_style(BucketName, BucketConfig), idle, State};
        _ ->
            RV = do_flush_bucket(BucketName, BucketConfig),
            case RV of
                ok ->
                    ?log_info("Requesting janitor run to actually revive bucket ~p after flush", [BucketName]),
                    JanitorRV = ns_janitor:cleanup(BucketName, [{timeout, 1}]),
                    case JanitorRV of
                        ok -> ok;
                        _ ->
                            ?log_error("Flusher's janitor run failed: ~p", [JanitorRV])
                    end,
                    {reply, RV, idle, State};
                _ ->
                    {reply, RV, idle, State}
            end
    end.

do_flush_bucket(BucketName, BucketConfig) ->
    ns_config:sync_announcements(),
    Nodes = ns_bucket:bucket_nodes(BucketConfig),
    case ns_config_rep:synchronize_remote(Nodes) of
        ok ->
            case janitor_agent:mass_prepare_flush(BucketName, Nodes) of
                {_, [], []} ->
                    continue_flush_bucket(BucketName, BucketConfig, Nodes);
                {_, BadResults, BadNodes} ->
                    %% NOTE: I'd like to undo prepared flush on good
                    %% nodes, but given we've lost information whether
                    %% janitor ever marked them as warmed up I
                    %% cannot. We'll do it after some partial
                    %% janitoring support is achieved. And for now
                    %% we'll rely on janitor cleaning things up.
                    {error, {prepare_flush_failed, BadNodes, BadResults}}
            end;
        {error, SyncFailedNodes} ->
            {error, {initial_config_sync_failed, SyncFailedNodes}}
    end.

continue_flush_bucket(BucketName, BucketConfig, Nodes) ->
    OldFlushCount = proplists:get_value(flushseq, BucketConfig, 0),
    NewConfig = lists:keystore(flushseq, 1, BucketConfig, {flushseq, OldFlushCount + 1}),
    ns_bucket:set_bucket_config(BucketName, NewConfig),
    ns_config:sync_announcements(),
    case ns_config_rep:synchronize_remote(Nodes) of
        ok ->
            finalize_flush_bucket(BucketName, Nodes);
        {error, SyncFailedNodes} ->
            {error, {flush_config_sync_failed, SyncFailedNodes}}
    end.

finalize_flush_bucket(BucketName, Nodes) ->
    {_GoodNodes, FailedCalls, FailedNodes} = janitor_agent:complete_flush(BucketName, Nodes, ?FLUSH_BUCKET_TIMEOUT),
    case FailedCalls =:= [] andalso FailedNodes =:= [] of
        true ->
            ok;
        _ ->
            {error, {flush_wait_failed, FailedNodes, FailedCalls}}
    end.

do_flush_old_style(BucketName, BucketConfig) ->
    Nodes = ns_bucket:bucket_nodes(BucketConfig),
    {Results, BadNodes} = rpc:multicall(Nodes, ns_memcached, flush, [BucketName],
                                        ?MULTICALL_DEFAULT_TIMEOUT),
    case BadNodes =:= [] andalso lists:all(fun(A) -> A =:= ok end, Results) of
        true ->
            ok;
        false ->
            {old_style_flush_failed, Results, BadNodes}
    end.

apply_recoverer_bucket_config(Bucket, BucketConfig, Servers) ->
    {ok, _, Zombies} = janitor_agent:query_states(Bucket, Servers, 1),
    case Zombies of
        [] ->
            janitor_agent:apply_new_bucket_config(
              Bucket, Servers, [], BucketConfig, []);
        _ ->
            ?log_error("Failed to query states from some of the nodes: ~p", [Zombies]),
            {error, {failed_nodes, Zombies}}
    end.

maybe_drop_recovery_status() ->
    ns_config:update(
      fun ({recovery_status, Value} = P) ->
              case Value of
                  not_running ->
                      P;
                  {running, _Bucket, _UUID} ->
                      ale:info(?USER_LOGGER, "Apparently recovery ns_orchestrator died. Dropped stale recovery status ~p", [P]),
                      {recovery_status, not_running}
              end;
          (Other) ->
              Other
      end, make_ref()).

ensure_recovery_status(Bucket, UUID) ->
    ns_config:set(recovery_status, {running, Bucket, UUID}).

%% NOTE: 2.0.1 and earlier nodes only had
%% ns_port_sup. I believe it's harmless not to clean
%% their moxis
-spec multicall_moxi_restart([node()], _) -> ok | [{node(), _} | node()].
multicall_moxi_restart(Nodes, Timeout) ->
    {Results, FailedNodes} = rpc:multicall(Nodes, ns_ports_setup, restart_moxi, [],
                                           Timeout),
    BadResults = [Pair || {_N, R} = Pair <- lists:zip(Nodes -- FailedNodes, Results),
                          R =/= ok],
    case BadResults =:= [] andalso FailedNodes =:= [] of
        true ->
            ok;
        _ ->
            FailedNodes ++ BadResults
    end.
