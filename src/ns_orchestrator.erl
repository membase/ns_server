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

-record(idle_state, {remaining_buckets=[]}).
-record(janitor_state, {remaining_buckets, pid}).
-record(rebalancing_state, {rebalancer, progress,
                            keep_nodes, eject_nodes, failed_nodes}).


%% API
-export([create_bucket/3,
         delete_bucket/1,
         flush_bucket/1,
         failover/1,
         try_autofailover/1,
         needs_rebalance/0,
         request_janitor_run/1,
         rebalance_progress/0,
         rebalance_progress_full/0,
         start_link/0,
         start_rebalance_old_style/3,
         start_rebalance/2,
         stop_rebalance/0,
         update_progress/1,
         is_rebalance_running/0
        ]).

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
         rebalancing/2, rebalancing/3]).


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
                           rebalance_running.
create_bucket(BucketType, BucketName, NewConfig) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {create_bucket, BucketType, BucketName,
                                      NewConfig}, infinity).

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
                           ok | rebalance_running | {shutdown_failed, [node()]} | {exit, {not_found, bucket_name()}, _}.
delete_bucket(BucketName) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {delete_bucket, BucketName}, infinity).

-spec flush_bucket(bucket_name()) ->
                          ok |
                          rebalance_running |
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


-spec failover(atom()) -> ok.
failover(Node) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {failover, Node}, infinity).


-spec try_autofailover(atom()) -> ok | {autofailover_unsafe, [bucket_name()]}.
try_autofailover(Node) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {try_autofailover, Node}, infinity).


-spec needs_rebalance() -> boolean().
needs_rebalance() ->
    needs_rebalance(ns_node_disco:nodes_wanted()).


-spec needs_rebalance([atom(), ...]) -> boolean().
needs_rebalance(Nodes) ->
    lists:any(fun ({_, BucketConfig}) -> needs_rebalance(Nodes, BucketConfig) end,
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

-spec start_rebalance_old_style([node()], [node()], [node()]) ->
                                       ok | in_progress | already_balanced.
start_rebalance_old_style(KeepNodes, EjectedNodes, FailedNodes) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {start_rebalance, KeepNodes,
                                      EjectedNodes, FailedNodes}).


-spec start_rebalance([node()], [node()]) ->
                                       ok | in_progress | already_balanced | nodes_mismatch | no_active_nodes_left.
start_rebalance(KnownNodes, EjectNodes) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_all_state_event(?SERVER, {maybe_start_rebalance, KnownNodes, EjectNodes}).


-spec stop_rebalance() -> ok | not_rebalancing.
stop_rebalance() ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, stop_rebalance).


%%
%% gen_fsm callbacks
%%

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.


init([]) ->
    process_flag(trap_exit, true),
    self() ! janitor,
    timer:send_interval(10000, janitor),

    CurrentCompat = cluster_compat_mode:get_compat_version(),
    ok = ns_online_config_upgrader:upgrade_config_on_join(CurrentCompat),

    try
        consider_switching_compat_mode()
    catch exit:normal ->
            %% There's no need to restart us here. So if we've changed compat mode in init suppress exit
            ok
    end,
    {ok, idle, #idle_state{}}.


handle_event(Event, StateName, State) ->
    {stop, {unhandled, Event, StateName}, State}.


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

handle_sync_event(Event, _From, StateName, State) ->
    {stop, {unhandled, Event, StateName}, State}.

handle_info(janitor, idle, #idle_state{remaining_buckets=[]} = State) ->
    case ns_bucket:get_bucket_names(membase) of
        [] ->
            consider_switching_compat_mode(),
            {next_state, idle, State#idle_state{remaining_buckets=[]}};
        Buckets ->
            handle_info(janitor, idle,
                        State#idle_state{remaining_buckets=Buckets})
    end;
handle_info(janitor, idle, #idle_state{remaining_buckets=Buckets}) ->
    misc:verify_name(?MODULE), % MB-3180: Make sure we're still registered
    Bucket = hd(Buckets),
    Pid = proc_lib:spawn_link(ns_janitor, cleanup, [Bucket, [consider_stopping_rebalance_status]]),
    %% NOTE: Bucket will be popped from Buckets when janitor run will
    %% complete successfully
    {next_state, janitor_running, #janitor_state{remaining_buckets=Buckets,
                                                 pid = Pid}};
handle_info(janitor, StateName, StateData) ->
    ?log_info("Skipping janitor in state ~p: ~p", [StateName, StateData]),
    {next_state, StateName, StateData};
handle_info({'EXIT', Pid, Reason}, janitor_running,
            #janitor_state{pid = Pid,
                           remaining_buckets = [Bucket|Buckets]}) ->
    case Reason of
        normal ->
            ok;
        _ ->
            ?log_warning("Janitor run exited for bucket ~p with reason ~p~n",
                         [Bucket, Reason])
    end,
    case Buckets of
        [] ->
            ok;
        _ ->
            self() ! janitor
    end,
    consider_switching_compat_mode(),
    {next_state, idle, #idle_state{remaining_buckets = Buckets}};
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
    RemainingBuckets =State#idle_state.remaining_buckets,
    case lists:member(BucketName, RemainingBuckets) of
        false ->
            self() ! janitor,
            {next_state, idle, State#idle_state{remaining_buckets = [BucketName|RemainingBuckets]}};
        _ ->
            consider_switching_compat_mode(),
            {next_state, idle, State}
    end;
idle(_Event, State) ->
    %% This will catch stray progress messages
    {next_state, idle, State}.

janitor_running({request_janitor_run, BucketName}, State) ->
    RemainingBuckets =State#janitor_state.remaining_buckets,
    case lists:member(BucketName, RemainingBuckets) of
        false ->
            {next_state, janitor_running, State#janitor_state{remaining_buckets = [BucketName|RemainingBuckets]}};
        _ ->
            {next_state, janitor_running, State}
    end;
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
                NewRemainingBuckets = RemainingBuckets -- [BucketName],
                case RemainingBuckets =:= NewRemainingBuckets of
                    true ->
                        ok;
                    false ->
                        ?log_debug("Deleted bucket ~p from remaining_buckets",
                                   [BucketName])
                end,
                State#idle_state{remaining_buckets=NewRemainingBuckets};
            _ ->
                State
        end,

    Reply =
        case DeleteRV of
            {ok, BucketConfig} ->
                Nodes = ns_bucket:bucket_nodes(BucketConfig),
                Pred = fun (Active, _Connected) ->
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
                case rpc:multicall(LiveNodes, ns_port_sup, restart_port_by_name, [moxi],
                                   ?DELETE_BUCKET_TIMEOUT) of
                    {_Results, []} ->
                        ok;
                    {_Results, FailedNodes} ->
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
%% NOTE: this is being remotely called by 1.8.x nodes and used by maybe_start_rebalance
idle({start_rebalance, KeepNodes, EjectNodes, FailedNodes}, _From,
            _State) ->
    ?user_log(?REBALANCE_STARTED,
              "Starting rebalance, KeepNodes = ~p, EjectNodes = ~p~n",
              [KeepNodes, EjectNodes]),
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
idle({move_vbuckets, Bucket, Moves}, _From, _State) ->
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
    {reply, not_rebalancing, idle, State}.


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
    idle(Msg, From, NextState).

%% Asynchronous rebalancing events
rebalancing({update_progress, Progress},
            #rebalancing_state{progress=Old} = State) ->
    NewProgress = dict:merge(fun (_, _, New) -> New end, Old, Progress),
    {next_state, rebalancing,
     State#rebalancing_state{progress=NewProgress}}.

%% Synchronous rebalancing events
rebalancing({failover, _Node}, _From, State) ->
    {reply, rebalancing, rebalancing, State};
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



%%
%% Internal functions
%%

needs_rebalance(Nodes, BucketConfig) ->
    Servers = proplists:get_value(servers, BucketConfig, []),
    case proplists:get_value(type, BucketConfig) of
        membase ->
            case Servers of
                [] -> false;
                _ ->
                    Map = proplists:get_value(map, BucketConfig),
                    Map =:= undefined orelse
                        lists:sort(Nodes) /= lists:sort(Servers) orelse
                        ns_rebalancer:unbalanced(Map, Servers)
            end;
        memcached ->
            lists:sort(Nodes) /= lists:sort(Servers)
    end.


-spec update_progress(dict()) -> ok.
update_progress(Progress) ->
    gen_fsm:send_event(?SERVER, {update_progress, Progress}).


wait_for_nodes_loop(Timeout, Nodes) ->
    receive
        {updated, NewNodes} ->
            wait_for_nodes_loop(Timeout, NewNodes);
        done ->
            ok
    after Timeout ->
            {timeout, Nodes}
    end.

%% Wait till active and connected buckets satisfy certain predicate on all
%% nodes. After `Timeout' milliseconds of idleness (i.e. when bucket lists has
%% not been updated on any of the nodes for more than `Timeout' milliseconds)
%% we give up and return the list of leftover nodes.
-spec wait_for_nodes([node()],
                     fun(([string()], [string()]) -> boolean()),
                     timeout()) -> ok | {timeout, [node()]}.
wait_for_nodes(Nodes, Pred, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    Fn =
        fun () ->
                Self = self(),
                ns_pubsub:subscribe_link(
                  buckets_events,
                  fun ({significant_buckets_change, Node}, PendingNodes) ->
                          Status = ns_doctor:get_node(Node),
                          Active = proplists:get_value(active_buckets,
                                                       Status, []),
                          Connected = proplists:get_value(ready_buckets,
                                                          Status, []),

                          case Pred(Active, Connected) of
                              false ->
                                  PendingNodes;
                              true ->
                                  NewPendingNodes = PendingNodes -- [Node],
                                  Msg = case NewPendingNodes of
                                            [] -> done;
                                            _Other -> {updated, NewPendingNodes}
                                        end,
                                  Self ! Msg,
                                  NewPendingNodes
                          end;
                      (_, PendingNodes) ->
                          PendingNodes
                  end,
                  Nodes
                 ),

                Result = wait_for_nodes_loop(Timeout, Nodes),
                Parent ! {Ref, Result}
        end,

    Pid = spawn_link(Fn),

    Result1 =
        receive
            {Ref, Result0} -> Result0
        end,

    receive
        {'EXIT', Pid, normal} ->
            Result1
    end.

%% quickly and _without_ communication to potentially remote
%% ns_orchestrator find out if rebalance is running.
is_rebalance_running() ->
    ns_config:search_quick(rebalance_status) =:= {value, running}.

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
            case cluster_compat_mode:is_cluster_20() of
                true ->
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
                    end;
                _ ->
                    {reply, not_supported, idle, State}
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

