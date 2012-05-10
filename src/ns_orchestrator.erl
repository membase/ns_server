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
         failover/1,
         needs_rebalance/0,
         request_janitor_run/1,
         rebalance_progress/0,
         rebalance_progress_full/0,
         start_link/0,
         start_rebalance/3,
         stop_rebalance/0,
         update_progress/1
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
    SecondsToWait = 20,
    SleepTime = 0.2,
    wait_for_orchestrator_loop(erlang:round(SecondsToWait/SleepTime), erlang:round(SleepTime * 1000)).

wait_for_orchestrator_loop(0, _SleepTime) ->
    failed;
wait_for_orchestrator_loop(TriesLeft, SleepTime) ->
    case is_pid(global:whereis_name(?MODULE)) of
        true ->
            ok;
        false ->
            timer:sleep(SleepTime),
            wait_for_orchestrator_loop(TriesLeft-1, SleepTime)
    end.


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
                           ok | rebalance_running | {exit, {not_found, bucket_name()}, _}.
delete_bucket(BucketName) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {delete_bucket, BucketName}, infinity).


-spec failover(atom()) -> ok | rebalancing | unknown_node.
failover(Node) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {failover, Node}, infinity).


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

-spec start_rebalance([node()], [node()], [node()]) ->
                             ok | in_progress | already_balanced.
start_rebalance(KeepNodes, EjectNodes, FailedNodes) ->
    wait_for_orchestrator(),
    gen_fsm:sync_send_event(?SERVER, {start_rebalance, KeepNodes,
                                      EjectNodes, FailedNodes}).


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
    timer:send_interval(10000, janitor),
    {ok, idle, #idle_state{}}.


handle_event(unhandled, unhandled, unhandled) ->
    unhandled.


handle_sync_event(unhandled, unhandled, unhandled, unhandled) ->
    unhandled.

handle_info(janitor, idle, #idle_state{remaining_buckets=[]} = State) ->
    case ns_bucket:get_bucket_names(membase) of
        [] -> {next_state, idle, State#idle_state{remaining_buckets=[]}};
        Buckets ->
            handle_info(janitor, idle,
                        State#idle_state{remaining_buckets=Buckets})
    end;
handle_info(janitor, idle, #idle_state{remaining_buckets=Buckets}) ->
    misc:verify_name(?MODULE), % MB-3180: Make sure we're still registered
    Bucket = hd(Buckets),
    Pid = proc_lib:spawn_link(ns_janitor, cleanup, [Bucket, []]),
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
    {next_state, idle, #idle_state{remaining_buckets = Buckets}};
handle_info({'EXIT', Pid, Reason}, rebalancing,
            #rebalancing_state{rebalancer=Pid,
                               keep_nodes=KeepNodes,
                               eject_nodes=EjectNodes,
                               failed_nodes=FailedNodes}) ->
    master_activity_events:note_rebalance_end(Pid, Reason),
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
                                   end, Results) of
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
idle({delete_bucket, BucketName}, _From,
     #idle_state{remaining_buckets=RemainingBuckets} = State) ->
    Reply = ns_bucket:delete_bucket(BucketName),
    NewState =
        case Reply of
            ok ->
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

    case Reply of
        ok ->
            Pred = fun (Active, _Connected) ->
                           not lists:member(BucketName, Active)
                   end,

            Nodes = ns_cluster_membership:active_nodes(),
            LiveNodes =
                case wait_for_nodes(Nodes, Pred, ?DELETE_BUCKET_TIMEOUT) of
                    ok ->
                        Nodes;
                    {timeout, LeftoverNodes} ->
                        ?log_warning("Nodes ~p failed to delete bucket ~p "
                                     "within expected time.",
                                     [LeftoverNodes, BucketName]),
                        Nodes -- LeftoverNodes
            end,

            ?log_info("Restarting moxi on nodes ~p", [LiveNodes]),
            case rpc:multicall(LiveNodes, ns_port_sup, restart_port_by_name, [moxi],
                               ?DELETE_BUCKET_TIMEOUT) of
                {_Results, []} ->
                    ok;
                {_Results, FailedNodes} ->
                    ?log_warning("Failed to restart moxi on following nodes ~p",
                                 [FailedNodes])
            end;
        _Other ->
            ok
    end,

    {reply, Reply, idle, NewState};
idle({failover, Node}, _From, State) ->
    case ns_config:search(Node) of
        false ->
            ale:info(?USER_LOGGER, "Somebody tried to failover unknown node: ~p", [Node]),
            {reply, unknown_node, idle, State};
        {value, _} ->
            ale:info(?USER_LOGGER, "Starting failing over ~p", [Node]),
            master_activity_events:note_failover(Node),
            Result = ns_rebalancer:failover(Node),
            ?user_log(?FAILOVER_NODE, "Failed over ~p: ~p", [Node, Result]),
            ns_cluster:counter_inc(failover_node),
            ns_config:set({node, Node, membership}, inactiveFailed),
            {reply, Result, idle, State}
    end;
idle(rebalance_progress, _From, State) ->
    {reply, not_running, idle, State};
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
                          Connected = proplists:get_value(connected_buckets,
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
