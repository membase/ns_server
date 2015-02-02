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
%% @doc Rebalancing functions.
%%

-module(ns_rebalancer).

-include("ns_common.hrl").
-include("ns_stats.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([failover/1,
         orchestrate_failover/1,
         check_graceful_failover_possible/2,
         validate_autofailover/1,
         generate_initial_map/1,
         start_link_rebalance/5,
         run_mover/7,
         unbalanced/3,
         map_options_changed/2,
         eject_nodes/1,
         maybe_cleanup_old_buckets/1,
         get_delta_recovery_nodes/2,
         verify_replication/3,
         start_link_graceful_failover/1,
         generate_vbucket_map_options/2,
         check_failover_possible/1]).

-export([wait_local_buckets_shutdown_complete/0]). % used via rpc:multicall


-define(DATA_LOST, 1).
-define(BAD_REPLICATORS, 2).

-define(BUCKETS_SHUTDOWN_WAIT_TIMEOUT, 20000).

-define(REBALANCER_READINESS_WAIT_TIMEOUT, 60000).

%%
%% API
%%

orchestrate_failover(Node) ->
    ale:info(?USER_LOGGER, "Starting failing over ~p", [Node]),
    master_activity_events:note_failover(Node),
    failover(Node),
    ale:info(?USER_LOGGER, "Failed over ~p: ok", [Node]),
    ns_cluster:counter_inc(failover_node),
    ns_config:set({node, Node, membership}, inactiveFailed),
    ok.


%% @doc Fail a node. Doesn't eject the node from the cluster. Takes
%% effect immediately.
failover(Node) ->
    FailoverVBuckets =
        lists:foldl(
          fun (Bucket, Acc) ->
                  master_activity_events:note_bucket_failover_started(Bucket, Node),

                  {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
                  failover(Bucket, BucketConfig, Node),

                  {map, Map} = lists:keyfind(map, 1, BucketConfig),
                  VBuckets = node_vbuckets(Map, Node),

                  master_activity_events:note_bucket_failover_ended(Bucket, Node),

                  [{Bucket, VBuckets} | Acc]
          end, [], ns_bucket:get_bucket_names()),

    case cluster_compat_mode:is_cluster_30() of
        true ->
            ns_config:set({node, Node, failover_vbuckets}, FailoverVBuckets);
        false ->
            ok
    end,

    ok.

get_failover_vbuckets(Config, Node) ->
    ns_config:search(Config, {node, Node, failover_vbuckets}, []).

validate_autofailover(Node) ->
    BucketPairs = ns_bucket:get_buckets(),
    UnsafeBuckets =
        [BucketName
         || {BucketName, BucketConfig} <- BucketPairs,
            validate_autofailover_bucket(BucketConfig, Node) =:= false],
    case UnsafeBuckets of
        [] -> ok;
        _ -> {error, UnsafeBuckets}
    end.

validate_autofailover_bucket(BucketConfig, Node) ->
    case proplists:get_value(type, BucketConfig) of
        membase ->
            Map = proplists:get_value(map, BucketConfig),
            Map1 = mb_map:promote_replicas(Map, [Node]),
            case Map1 of
                undefined ->
                    true;
                _ ->
                    case [I || {I, [undefined|_]} <- misc:enumerate(Map1, 0)] of
                        [] -> true;
                        _MissingVBuckets ->
                            false
                    end
            end;
        _ ->
            true
    end.

-spec failover(string(), list(), atom()) -> ok | janitor_failed.
failover(Bucket, BucketConfig, Node) ->
    Servers = proplists:get_value(servers, BucketConfig),
    case proplists:get_value(type, BucketConfig) of
        membase ->
            %% Promote replicas of vbuckets on this node
            Map = proplists:get_value(map, BucketConfig),
            Map1 = mb_map:promote_replicas(Map, [Node]),
            case Map1 of
                undefined ->
                    ok;
                _ ->
                    case [I || {I, [undefined|_]} <- misc:enumerate(Map1, 0)] of
                        [] -> ok; % Phew!
                        MissingVBuckets ->
                            ?rebalance_error("Lost data in ~p for ~w", [Bucket, MissingVBuckets]),
                            ?user_log(?DATA_LOST,
                                      "Data has been lost for ~B% of vbuckets in bucket ~p.",
                                      [length(MissingVBuckets) * 100 div length(Map), Bucket])
                    end
            end,
            ns_bucket:set_fast_forward_map(Bucket, undefined),
            case Map1 of
                undefined ->
                    undefined = Map;            % Do nothing. Map didn't change
                _ ->
                    ns_bucket:set_map(Bucket, Map1)
            end,
            ns_bucket:set_servers(Bucket, lists:delete(Node, Servers)),
            try ns_janitor:cleanup(Bucket, []) of
                ok ->
                    ok;
                {error, _, BadNodes} ->
                    ?rebalance_error("Skipped vbucket activations and replication topology changes because not all remaining node were found to have healthy bucket ~p: ~p", [Bucket, BadNodes]),
                    janitor_failed
            catch
                E:R ->
                    ?rebalance_error("Janitor cleanup of ~p failed after failover of ~p: ~p",
                                     [Bucket, Node, {E, R}]),
                    janitor_failed
            end;
        memcached ->
            ns_bucket:set_servers(Bucket, lists:delete(Node, Servers))
    end.

generate_vbucket_map_options(KeepNodes, BucketConfig) ->
    Config = ns_config:get(),
    ReplicationTopology = cluster_compat_mode:get_replication_topology(),
    generate_vbucket_map_options(KeepNodes, BucketConfig, ReplicationTopology, Config).

generate_vbucket_map_options(KeepNodes, BucketConfig, ReplicationTopology, Config) ->
    Tags = case ns_config:search(Config, server_groups) of
               false ->
                   undefined;
               {value, ServerGroups} ->
                   case [G || G <- ServerGroups,
                              proplists:get_value(nodes, G) =/= []] of
                       [_] ->
                           %% note that we don't need to handle this case
                           %% specially; but unfortunately removing it would
                           %% make 2.5 nodes always believe that rebalance is
                           %% required in case there's only one server group
                           undefined;
                       _ ->
                           Tags0 = [case proplists:get_value(uuid, G) of
                                        T ->
                                            [{N, T} || N <- proplists:get_value(nodes, G),
                                                       lists:member(N, KeepNodes)]
                                    end || G <- ServerGroups],

                           TagsRV = lists:append(Tags0),

                           case KeepNodes -- [N || {N, _T} <- TagsRV] of
                               [] -> ok;
                               _ ->
                                   %% there's tiny race between start of rebalance and
                                   %% somebody changing server_groups. We largely ignore it,
                                   %% but in case where it can clearly cause problem we raise
                                   %% exception
                                   erlang:error(server_groups_race_detected)
                           end,

                           TagsRV
                   end
           end,

    Opts0 = ns_bucket:config_to_map_options(BucketConfig),
    misc:update_proplist(Opts0, [{replication_topology, ReplicationTopology},
                                 {tags, Tags}]).

generate_vbucket_map(CurrentMap, KeepNodes, BucketConfig) ->
    Opts = generate_vbucket_map_options(KeepNodes, BucketConfig),

    Map0 =
        case lists:keyfind(deltaRecoveryMap, 1, BucketConfig) of
            {deltaRecoveryMap, DRMapAndOpts} when DRMapAndOpts =/= undefined ->
                {DRMap, DROpts} = DRMapAndOpts,

                case mb_map:is_trivially_compatible_past_map(KeepNodes, CurrentMap,
                                                             Opts, DRMap, DROpts) of
                    true ->
                        DRMap;
                    false ->
                        undefined
                end;
            _ ->
                undefined
        end,

    Map = case Map0 of
              undefined ->
                  EffectiveOpts = [{maps_history, ns_bucket:past_vbucket_maps()} | Opts],
                  mb_map:generate_map(CurrentMap, KeepNodes, EffectiveOpts);
              _ ->
                  Map0
          end,

    {Map, Opts}.

generate_initial_map(BucketConfig) ->
    Chain = lists:duplicate(proplists:get_value(num_replicas, BucketConfig) + 1,
                            undefined),
    Map1 = lists:duplicate(proplists:get_value(num_vbuckets, BucketConfig),
                           Chain),
    Servers = proplists:get_value(servers, BucketConfig),
    generate_vbucket_map(Map1, Servers, BucketConfig).

local_buckets_shutdown_loop(Ref, CanWait) ->
    ExcessiveBuckets = ns_memcached:active_buckets() -- ns_bucket:node_bucket_names(node()),
    case ExcessiveBuckets of
        [] ->
            ok;
        _ ->
            case CanWait of
                false ->
                    exit({old_buckets_shutdown_wait_failed, ExcessiveBuckets});
                true ->
                    ?log_debug("Waiting until the following old bucket instances are gone: ~p", [ExcessiveBuckets]),
                    receive
                        {Ref, timeout} ->
                            local_buckets_shutdown_loop(Ref, false);
                        {Ref, _Msg} ->
                            local_buckets_shutdown_loop(Ref, true)
                    end
            end
    end.

%% note: this is rpc:multicall-ed
wait_local_buckets_shutdown_complete() ->
    misc:executing_on_new_process(
      fun () ->
              Ref = erlang:make_ref(),
              Parent = self(),
              Subscription = ns_pubsub:subscribe_link(buckets_events,
                                                      fun ({stopped, _, _, _} = StoppedMsg) ->
                                                              Parent ! {Ref, StoppedMsg};
                                                          (_) ->
                                                              ok
                                                      end),
              erlang:send_after(?BUCKETS_SHUTDOWN_WAIT_TIMEOUT, Parent, {Ref, timeout}),
              try
                  local_buckets_shutdown_loop(Ref, true)
              after
                  (catch ns_pubsub:unsubscribe(Subscription))
              end
      end).

do_wait_buckets_shutdown(KeepNodes) ->
    {Good, ReallyBad, FailedNodes} =
        misc:rpc_multicall_with_plist_result(
          KeepNodes, ns_rebalancer, wait_local_buckets_shutdown_complete, []),
    NonOk = [Pair || {_Node, Result} = Pair <- Good,
                     Result =/= ok],
    Failures = ReallyBad ++ NonOk ++ [{N, node_was_down} || N <- FailedNodes],
    case Failures of
        [] ->
            ok;
        _ ->
            ?rebalance_error("Failed to wait deletion of some buckets on some nodes: ~p~n", [Failures]),
            exit({buckets_shutdown_wait_failed, Failures})
    end.

sanitize(Config) ->
    misc:rewrite_key_value_tuple(sasl_password, "*****", Config).

do_pre_rebalance_config_sync(KeepNodes) ->
    %% TODO: pull config reliably here as well.
    %%
    %% And after we have that, make sure recovery, rebalance and
    %% graceful failover, all start with latest config reliably
    ns_config:sync_announcements(),
    case ns_config_rep:synchronize_remote(KeepNodes) of
        ok ->
            cool;
        {error, SyncFailedNodes} ->
            exit({pre_rebalance_config_synchronization_failed, SyncFailedNodes})
    end.

start_link_rebalance(KeepNodes, EjectNodes,
                     FailedNodes, DeltaNodes, DeltaRecoveryBucketNames) ->
    proc_lib:start_link(
      erlang, apply,
      [fun () ->
               KVKeep = ns_cluster_membership:filter_out_non_kv_nodes(KeepNodes),
               case KVKeep =:= [] of
                   true ->
                       proc_lib:init_ack({error, no_kv_nodes_left}),
                       exit(normal);
                   false ->
                       ok
               end,

               BucketConfigs = ns_bucket:get_buckets(),
               DeltaRecoveryBucketTuples =
                   build_delta_recovery_buckets(KVKeep, DeltaNodes, BucketConfigs, DeltaRecoveryBucketNames),

               NotOk = BucketConfigs =/= [] andalso DeltaNodes =/= [] andalso DeltaRecoveryBucketTuples =:= [],

               case NotOk of
                   true ->
                       proc_lib:init_ack({error, delta_recovery_not_possible});
                   false ->
                       proc_lib:init_ack({ok, self()}),

                       master_activity_events:note_rebalance_start(
                         self(), KeepNodes, EjectNodes, FailedNodes, DeltaNodes),

                       ok = apply_delta_recovery_buckets(DeltaRecoveryBucketTuples, DeltaNodes),

                       ok = drop_old_2i_indexes(KeepNodes),

                       ns_cluster_membership:activate(KeepNodes),

                       rebalance(KeepNodes, EjectNodes, FailedNodes,
                                 BucketConfigs, DeltaRecoveryBucketTuples)
               end
       end, []]).

rebalance(KeepNodes, EjectNodesAll, FailedNodesAll,
          BucketConfigs, DeltaRecoveryBuckets) ->
    do_pre_rebalance_config_sync(KeepNodes),

    %% now wait when all bucket shutdowns are done on nodes we're
    %% adding (or maybe adding)
    do_wait_buckets_shutdown(KeepNodes),

    %% don't eject ourselves at all here; this will be handled by ns_orchestrator
    EjectNodes = EjectNodesAll -- [node()],
    FailedNodes = FailedNodesAll -- [node()],

    KeepKVNodes = ns_cluster_membership:filter_out_non_kv_nodes(KeepNodes),
    LiveKVNodes = ns_cluster_membership:filter_out_non_kv_nodes(KeepNodes ++ EjectNodesAll),
    NumBuckets = length(BucketConfigs),
    ?rebalance_debug("BucketConfigs = ~p", [sanitize(BucketConfigs)]),

    case maybe_cleanup_old_buckets(KeepNodes) of
        ok ->
            ok;
        Error ->
            exit(Error)
    end,

    RebalanceObserver = case cluster_compat_mode:check_is_progress_tracking_supported() of
                            true ->
                                {ok, X} = ns_rebalance_observer:start_link(length(BucketConfigs)),
                                X;
                            _ ->
                                undefined
                        end,

    %% Eject failed nodes first so they don't cause trouble
    eject_nodes(FailedNodes),
    lists:foreach(fun ({I, {BucketName, BucketConfig}}) ->
                          ale:info(?USER_LOGGER, "Started rebalancing bucket ~s", [BucketName]),
                          ?rebalance_info("Rebalancing bucket ~p with config ~p",
                                          [BucketName, sanitize(BucketConfig)]),
                          BucketCompletion = I / NumBuckets,
                          ns_orchestrator:update_progress(
                            dict:from_list([{N, BucketCompletion}
                                            || N <- LiveKVNodes])),
                          case proplists:get_value(type, BucketConfig) of
                              memcached ->
                                  master_activity_events:note_bucket_rebalance_started(BucketName),
                                  ns_bucket:set_servers(BucketName, KeepKVNodes),
                                  master_activity_events:note_bucket_rebalance_ended(BucketName);
                              membase ->
                                  %% Only start one bucket at a time to avoid
                                  %% overloading things
                                  ThisEjected = ordsets:intersection(lists:sort(proplists:get_value(servers, BucketConfig, [])),
                                                                     lists:sort(EjectNodesAll)),
                                  ThisLiveNodes = KeepKVNodes ++ ThisEjected,
                                  ns_bucket:set_servers(BucketName, ThisLiveNodes),
                                  Pid = erlang:spawn_link(
                                          fun () ->
                                                  ?rebalance_info("Waiting for bucket ~p to be ready on ~p", [BucketName, ThisLiveNodes]),
                                                  {ok, _States, Zombies} = janitor_agent:query_states(BucketName, ThisLiveNodes, ?REBALANCER_READINESS_WAIT_TIMEOUT),
                                                  case Zombies of
                                                      [] ->
                                                          ?rebalance_info("Bucket is ready on all nodes"),
                                                          ok;
                                                      _ ->
                                                          exit({not_all_nodes_are_ready_yet, Zombies})
                                                  end
                                          end),
                                  MRef = erlang:monitor(process, Pid),
                                  receive
                                      stop ->
                                          exit(stopped);
                                      {'DOWN', MRef, _, _, _} ->
                                          ok
                                  end,
                                  case ns_janitor:cleanup(BucketName, [{query_states_timeout, 10000},
                                                                       {apply_config_timeout, 300000}]) of
                                      ok -> ok;
                                      {error, _, BadNodes} ->
                                          exit({pre_rebalance_janitor_run_failed, BadNodes})
                                  end,
                                  {ok, NewConf} =
                                      ns_bucket:get_bucket(BucketName),
                                  master_activity_events:note_bucket_rebalance_started(BucketName),
                                  {NewMap, MapOptions} =
                                      rebalance(BucketName, NewConf,
                                                KeepKVNodes, BucketCompletion,
                                                NumBuckets, DeltaRecoveryBuckets),
                                  ns_bucket:set_map_opts(BucketName, MapOptions),
                                  ns_bucket:update_bucket_props(BucketName,
                                                                [{deltaRecoveryMap, undefined}]),
                                  master_activity_events:note_bucket_rebalance_ended(BucketName),
                                  run_verify_replication(BucketName, KeepKVNodes, NewMap)
                          end
                  end, misc:enumerate(BucketConfigs, 0)),

    case RebalanceObserver of
        undefined ->
            ok;
        _Pid ->
            unlink(RebalanceObserver),
            exit(RebalanceObserver, shutdown),
            misc:wait_for_process(RebalanceObserver, infinity)
    end,

    ns_config:sync_announcements(),
    ns_config_rep:push(),
    ok = ns_config_rep:synchronize_remote(KeepNodes),
    eject_nodes(EjectNodes).



%% @doc Rebalance the cluster. Operates on a single bucket. Will
%% either return ok or exit with reason 'stopped' or whatever reason
%% was given by whatever failed.
rebalance(Bucket, Config, KeepNodes, BucketCompletion, NumBuckets, DeltaRecoveryBuckets) ->
    Map = proplists:get_value(map, Config),
    {FastForwardMap, MapOptions} =
        case lists:keyfind(Bucket, 1, DeltaRecoveryBuckets) of
            false ->
                generate_vbucket_map(Map, KeepNodes, Config);
            {_, _, V} ->
                V
        end,

    ns_bucket:update_vbucket_map_history(FastForwardMap, MapOptions),
    ?rebalance_debug("Target map options: ~p (hash: ~p)", [MapOptions, erlang:phash2(MapOptions)]),
    {run_mover(Bucket, Config, KeepNodes, BucketCompletion, NumBuckets, Map, FastForwardMap),
     MapOptions}.

run_mover(Bucket, Config, KeepNodes, BucketCompletion, NumBuckets, Map, FastForwardMap) ->
    ?rebalance_info("Target map (distance: ~p):~n~p", [(catch mb_map:vbucket_movements(Map, FastForwardMap)), FastForwardMap]),
    ns_bucket:set_fast_forward_map(Bucket, FastForwardMap),
    ProgressFun =
        fun (P) ->
                Progress = dict:map(fun (_, N) ->
                                            N / NumBuckets + BucketCompletion
                                    end, P),
                ns_orchestrator:update_progress(Progress)
        end,
    {ok, Pid} =
        ns_vbucket_mover:start_link(Bucket, Map, FastForwardMap, ProgressFun),
    case wait_for_mover(Pid) of
        ok ->
            HadRebalanceOut = ((proplists:get_value(servers, Config, []) -- KeepNodes) =/= []),
            case HadRebalanceOut of
                true ->
                    SecondsToWait = ns_config:read_key_fast(rebalance_out_delay_seconds, 10),
                    ?rebalance_info("Waiting ~w seconds before completing rebalance out."
                                    " So that clients receive graceful not my vbucket instead of silent closed connection", [SecondsToWait]),
                    receive
                        stop ->
                            exit(stopped)
                    after (SecondsToWait * 1000) ->
                            ok
                    end;
                false ->
                    ok
            end,
            ns_bucket:set_fast_forward_map(Bucket, undefined),
            ns_bucket:set_servers(Bucket, KeepNodes),
            FastForwardMap;
        stopped ->
            exit(stopped)
    end.

unbalanced(Map, Topology, BucketConfig) ->
    Servers = proplists:get_value(servers, BucketConfig, []),
    NumServers = length(Servers),

    R = lists:any(
          fun (Chain) ->
                  lists:member(
                    undefined,
                    %% Don't warn about missing replicas when you have
                    %% fewer servers than your copy count!
                    lists:sublist(Chain, NumServers))
          end, Map),

    R orelse case Topology of
                 chain ->
                     unbalanced_chain(Map, Servers);
                 star ->
                     unbalanced_star(Map, Servers)
             end.

%% @doc Determine if a particular bucket is unbalanced. Returns true
%% iff the max vbucket count in any class on any server is >2 more
%% than the min.
-spec unbalanced_chain(vbucket_map(), [atom()]) -> boolean().
unbalanced_chain(Map, Servers) ->
    lists:any(fun (Histogram) ->
                      case [N || {_, N} <- Histogram] of
                          [] -> false;
                          Counts -> lists:max(Counts) - lists:min(Counts) > 2
                      end
              end, histograms(Map, Servers)).

unbalanced_star(Map, Servers) ->
    {Masters, Replicas} =
        lists:foldl(
          fun ([M | R], {AccM, AccR}) ->
                  {[M | AccM], R ++ AccR}
          end, {[], []}, Map),
    Masters1 = lists:sort([M || M <- Masters, lists:member(M, Servers)]),
    Replicas1 = lists:sort([R || R <- Replicas, lists:member(R, Servers)]),

    MastersCounts = misc:uniqc(Masters1),
    ReplicasCounts = misc:uniqc(Replicas1),

    NumServers = length(Servers),

    lists:any(
      fun (Counts0) ->
              Counts1 = [C || {_, C} <- Counts0],
              Len = length(Counts1),
              Counts = case Len < NumServers of
                           true ->
                               lists:duplicate(NumServers - Len, 0) ++ Counts1;
                           false ->
                               true = Len =:= NumServers,
                               Counts1
                       end,
              Counts =/= [] andalso lists:max(Counts) - lists:min(Counts) > 1
      end, [MastersCounts, ReplicasCounts]).

map_options_changed(Topology, BucketConfig) ->
    Config = ns_config:get(),

    Servers = proplists:get_value(servers, BucketConfig, []),

    Opts = generate_vbucket_map_options(Servers, BucketConfig, Topology, Config),
    OptsHash = proplists:get_value(map_opts_hash, BucketConfig),
    case OptsHash of
        undefined ->
            true;
        _ ->
            erlang:phash2(Opts) =/= OptsHash
    end.

%%
%% Internal functions
%%

%% @private


%% @doc Eject a list of nodes from the cluster, making sure this node is last.
eject_nodes(Nodes) ->
    %% Leave myself last
    LeaveNodes = case lists:member(node(), Nodes) of
                     true ->
                         (Nodes -- [node()]) ++ [node()];
                     false ->
                         Nodes
                 end,
    lists:foreach(fun (N) ->
                          ns_cluster_membership:deactivate([N]),
                          ns_cluster:leave(N),
                          ns_audit:remove_node(undefined, N)
                  end, LeaveNodes).


%% for each replication turn in Map returns list of pairs {node(),
%% integer()} representing histogram of occurences of nodes in this
%% replication turn. Missing Servers are represented with counts of 0.
%% Nodes that are not present in Servers are ignored.
histograms(Map, Servers) ->
    Histograms = [lists:keydelete(
                    undefined, 1,
                    misc:uniqc(
                      lists:sort(
                        [N || N<-L,
                              lists:member(N, Servers)]))) ||
                     L <- misc:rotate(Map)],
    lists:map(fun (H) ->
                      Missing = [{N, 0} || N <- Servers,
                                           not lists:keymember(N, 1, H)],
                      Missing ++ H
              end, Histograms).


run_verify_replication(Bucket, Nodes, Map) ->
    Pid = proc_lib:spawn_link(?MODULE, verify_replication, [Bucket, Nodes, Map]),
    ?log_debug("Spawned verify_replication worker: ~p", [Pid]),
    {trap_exit, false} = erlang:process_info(self(), trap_exit),
    MRef = erlang:monitor(process, Pid),
    receive
        stop ->
            exit(stopped);
        {'DOWN', MRef, _, _, _} ->
            %% we're not trapping exits so if we're alive then child's
            %% exit is normal
            ok
    end.

verify_replication(Bucket, Nodes, Map) ->
    ExpectedReplicators0 = ns_bucket:map_to_replicas(Map, cluster_compat_mode:get_replication_topology()),
    ExpectedReplicators = lists:sort(ExpectedReplicators0),

    {ActualReplicators, BadNodes} = janitor_agent:get_src_dst_vbucket_replications(Bucket, Nodes),
    case BadNodes of
        [] -> ok;
        _ ->
            ale:error(?USER_LOGGER, "Rebalance is done, but failed to verify replications on following nodes:~p", [BadNodes]),
            exit(bad_replicas_due_to_bad_results)
    end,

    case misc:comm(ExpectedReplicators, ActualReplicators) of
        {[], [], _} ->
            ok;
        {Missing, Extra, _} ->
            ?user_log(?BAD_REPLICATORS,
                      "Bad replicators after rebalance:~nMissing = ~p~nExtras = ~p",
                      [Missing, Extra]),
            exit(bad_replicas)
    end.

-spec wait_for_mover(pid()) -> ok | stopped.
wait_for_mover(Pid) ->
    Ref = erlang:monitor(process, Pid),
    wait_for_mover_tail(Pid, Ref).

wait_for_mover_tail(Pid, Ref) ->
    receive
        stop ->
            ?log_debug("Got rebalance stop request"),
            erlang:unlink(Pid),
            TimeoutPid = diag_handler:arm_timeout(
                           5000,
                           fun (_) ->
                                   ?log_debug("Observing slow rebalance stop (mover pid: ~p", [Pid]),
                                   timeout_diag_logger:log_diagnostics(slow_rebalance_stop)
                           end),
            try
                (catch Pid ! {'EXIT', self(), shutdown}),
                wait_for_mover_tail(Pid, Ref)
            after
                diag_handler:disarm_timeout(TimeoutPid)
            end;
        {'DOWN', Ref, _, _, Reason} ->
            case Reason of
                %% monitoring was too late, but because we're linked
                %% and don't trap exits the fact that we're alife
                %% means it went normal
                noproc ->
                    ok;
                normal ->
                    ok;
                shutdown ->
                    stopped;
                _ ->
                    exit({mover_crashed, Reason})
            end
    end.

maybe_cleanup_old_buckets(KeepNodes) ->
    case misc:rpc_multicall_with_plist_result(KeepNodes, ns_storage_conf, delete_unused_buckets_db_files, []) of
        {_, _, DownNodes} when DownNodes =/= [] ->
            ?rebalance_error("Failed to cleanup old buckets on some nodes: ~p",
                             [DownNodes]),
            {buckets_cleanup_failed, DownNodes};
        {Good, ReallyBad, []} ->
            ReallyBadNodes =
                case ReallyBad of
                    [] ->
                        [];
                    _ ->
                        ?rebalance_error(
                           "Failed to cleanup old buckets on some nodes: ~n~p",
                           [ReallyBad]),
                        lists:map(fun ({Node, _}) -> Node end, ReallyBad)
                end,

            FailedNodes =
                lists:foldl(
                  fun ({Node, Result}, Acc) ->
                          case Result of
                              ok ->
                                  Acc;
                              Error ->
                                  ?rebalance_error(
                                     "Failed to cleanup old buckets on node ~p: ~p",
                                     [Node, Error]),
                                  [Node | Acc]
                          end
                  end, [], Good),

            case FailedNodes ++ ReallyBadNodes of
                [] ->
                    ok;
                AllFailedNodes ->
                    {buckets_cleanup_failed, AllFailedNodes}
            end
    end.

node_vbuckets(Map, Node) ->
    lists:reverse(
      lists:foldl(
        fun ({V, Chain}, Acc) ->
                case lists:member(Node, Chain) of
                    true ->
                        [V | Acc];
                    false ->
                        Acc
                end
        end, [], misc:enumerate(Map, 0))).

find_delta_recovery_map(Config, AllNodes, DeltaNodes, Bucket, BucketConfig) ->
    {map, CurrentMap} = lists:keyfind(map, 1, BucketConfig),
    CurrentOptions = generate_vbucket_map_options(AllNodes, BucketConfig),

    History = ns_bucket:past_vbucket_maps(Config),
    MatchingMaps = mb_map:find_matching_past_maps(AllNodes, CurrentMap,
                                                  CurrentOptions, History),

    find_delta_recovery_map_loop(MatchingMaps,
                                 Config, Bucket, CurrentOptions, DeltaNodes).

find_delta_recovery_map_loop([], _Config, _Bucket, _Options, _DeltaNodes) ->
    false;
find_delta_recovery_map_loop([TargetMap | Rest], Config, Bucket, Options, DeltaNodes) ->
    {_, TargetVBucketsDict} =
        lists:foldl(
          fun (Chain, {V, D}) ->
                  D1 = lists:foldl(
                         fun (Node, Acc) ->
                                 case lists:member(Node, Chain) of
                                     true ->
                                         dict:update(Node,
                                                     fun (Vs) ->
                                                             [V | Vs]
                                                     end, Acc);
                                     false ->
                                         Acc
                                 end
                         end, D, DeltaNodes),

                  {V+1, D1}
          end,
          {0, dict:from_list([{N, []} || N <- DeltaNodes])}, TargetMap),

    Usable =
        lists:all(
          fun (Node) ->
                  AllFailoverVBuckets = get_failover_vbuckets(Config, Node),
                  FailoverVBuckets = proplists:get_value(Bucket, AllFailoverVBuckets),
                  TargetVBuckets = lists:reverse(dict:fetch(Node, TargetVBucketsDict)),

                  TargetVBuckets =:= FailoverVBuckets
          end, DeltaNodes),

    case Usable of
        true ->
            {TargetMap, Options};
        false ->
            find_delta_recovery_map_loop(Rest, Config, Bucket, Options, DeltaNodes)
    end.

build_delta_recovery_buckets(_AllNodes, [] = _DeltaNodes, _AllBucketConfigs, _DeltaRecoveryBuckets) ->
    [];
build_delta_recovery_buckets(AllNodes, DeltaNodes, AllBucketConfigs, DeltaRecoveryBuckets) ->
    Config = ns_config:get(),

    %% such non-lazy computation of recovery map is suboptimal, but
    %% it's not that big deal suboptimal. I'm doing it for better
    %% testability of build_delta_recovery_buckets_loop
    MappedConfigs = [{Bucket,
                      BucketConfig,
                      find_delta_recovery_map(Config, AllNodes, DeltaNodes,
                                              Bucket, BucketConfig)}
                     || {Bucket, BucketConfig} <- AllBucketConfigs,
                        proplists:get_value(type, BucketConfig) =:= membase],

    Recovered0 = build_delta_recovery_buckets_loop(MappedConfigs, DeltaRecoveryBuckets, []),

    [{Bucket,
      build_transitional_bucket_config(BucketConfig, Map, Opts, DeltaNodes),
      {Map, Opts}}
     || {Bucket, BucketConfig, {Map, Opts}} <- Recovered0].

build_delta_recovery_buckets_loop([] = _MappedConfigs, _DeltaRecoveryBuckets, Acc) ->
    Acc;
build_delta_recovery_buckets_loop(MappedConfigs, DeltaRecoveryBuckets, Acc) ->
    [{Bucket, BucketConfig, RecoverResult0} | RestMapped] = MappedConfigs,

    NeedBucket = case DeltaRecoveryBuckets of
                     all -> true;
                     _List -> lists:member(Bucket, DeltaRecoveryBuckets)
                 end,
    RecoverResult = case NeedBucket of
                        true ->
                            RecoverResult0;
                        false ->
                            false
                    end,
    case RecoverResult of
        {Map, Opts} ->
            ?rebalance_debug("Found delta recovery map for bucket ~s: ~p",
                             [Bucket, {Map, Opts}]),

            NewAcc = [{Bucket, BucketConfig, {Map, Opts}} | Acc],
            build_delta_recovery_buckets_loop(RestMapped, DeltaRecoveryBuckets, NewAcc);
        false ->
            case NeedBucket of
                true ->
                    ?rebalance_debug("Couldn't delta recover bucket ~s when we care about delta recovery of that bucket", [Bucket]),
                    %% run rest of elements for logging
                    _ = build_delta_recovery_buckets_loop(RestMapped, DeltaRecoveryBuckets, []),
                    [];
                false ->
                    build_delta_recovery_buckets_loop(RestMapped, DeltaRecoveryBuckets, Acc)
            end
    end.

build_delta_recovery_buckets_loop_test() ->
    MappedConfigs = [{"b1", conf1, {map, opts}},
                     {"b2", conf2, false}],
    [] = build_delta_recovery_buckets_loop([], all, []),
    [] = build_delta_recovery_buckets_loop(MappedConfigs, all, []),
    [] = build_delta_recovery_buckets_loop(MappedConfigs, ["b2"], []),
    [] = build_delta_recovery_buckets_loop(MappedConfigs, ["b1", "b2"], []),
    [] = build_delta_recovery_buckets_loop(MappedConfigs, [], []),
    ?assertEqual([{"b1", conf1, {map, opts}}], build_delta_recovery_buckets_loop(MappedConfigs, ["b1"], [])),
    ?assertEqual([{"b1", conf1, {map, opts}}], build_delta_recovery_buckets_loop([hd(MappedConfigs)], all, [])).

apply_delta_recovery_buckets([], _DeltaNodes) ->
    ok;
apply_delta_recovery_buckets(DeltaRecoveryBuckets, DeltaNodes) ->
    lists:foreach(
      fun ({Bucket, BucketConfig, _}) ->
              ns_bucket:set_bucket_config(Bucket, BucketConfig)
      end, DeltaRecoveryBuckets),

    ns_config:sync_announcements(),
    case ns_config_rep:synchronize_remote(DeltaNodes) of
        ok ->
            cool;
        {error, SyncFailedNodes} ->
            exit({delta_recovery_config_synchronization_failed, SyncFailedNodes})
    end,

    lists:foreach(
      fun ({Bucket, _, _}) ->
              ok = wait_for_bucket(Bucket, DeltaNodes)
      end, DeltaRecoveryBuckets),

    ns_config:set([{{node, N, recovery_type}, none} || N <- DeltaNodes] ++
                      [{{node, N, failover_vbuckets}, undefined} || N <- DeltaNodes]).


wait_for_bucket(Bucket, Nodes) ->
    ?log_debug("Waiting until bucket ~p gets ready on nodes ~p", [Bucket, Nodes]),
    do_wait_for_bucket(Bucket, Nodes).

do_wait_for_bucket(Bucket, Nodes) ->
    {ok, _States, Zombies} = janitor_agent:query_states(Bucket, Nodes, 60000),
    case Zombies of
        [] ->
            ?log_debug("Bucket ~p became ready on nodes ~p", [Bucket, Nodes]),
            ok;
        _ ->
            ?log_debug("Bucket ~p still not ready on nodes ~p", [Bucket, Zombies]),
            do_wait_for_bucket(Bucket, Zombies)
    end.

build_transitional_bucket_config(BucketConfig, TargetMap, Options, DeltaNodes) ->
    {num_replicas, NumReplicas} = lists:keyfind(num_replicas, 1, BucketConfig),
    {map, CurrentMap} = lists:keyfind(map, 1, BucketConfig),
    {servers, Servers} = lists:keyfind(servers, 1, BucketConfig),
    TransitionalMap =
        lists:map(
          fun ({CurrentChain, TargetChain}) ->
                  case CurrentChain of
                      [undefined | _] ->
                          CurrentChain;
                      _ ->
                          ChainDeltaNodes = [N || N <- TargetChain,
                                                  lists:member(N, DeltaNodes)],
                          PreservedNodes = lists:takewhile(
                                             fun (N) ->
                                                     N =/= undefined andalso
                                                         not lists:member(N, DeltaNodes)
                                             end, CurrentChain),

                          TransitionalChain0 = PreservedNodes ++ ChainDeltaNodes,
                          N = length(TransitionalChain0),
                          true = N =< NumReplicas + 1,

                          TransitionalChain0 ++
                              lists:duplicate(NumReplicas - N + 1, undefined)
                  end
          end, lists:zip(CurrentMap, TargetMap)),

    NewServers = DeltaNodes ++ Servers,

    misc:update_proplist(BucketConfig, [{map, TransitionalMap},
                                        {servers, NewServers},
                                        {deltaRecoveryMap, {TargetMap, Options}}]).

get_delta_recovery_nodes(Config, Nodes) ->
    [N || N <- Nodes,
          ns_cluster_membership:get_cluster_membership(N, Config) =:= inactiveAdded
              andalso ns_cluster_membership:get_recovery_type(Config, N) =:= delta].

start_link_graceful_failover(Node) ->
    proc_lib:start_link(erlang, apply, [fun run_graceful_failover/1, [Node]]).

run_graceful_failover(Node) ->
    case check_failover_possible(Node) of
        ok ->
            ok;
        Error ->
            erlang:exit(Error)
    end,

    case check_graceful_failover_possible(Node, ns_bucket:get_buckets()) of
        true -> ok;
        false ->
            erlang:exit(not_graceful)
    end,
    proc_lib:init_ack({ok, self()}),

    ale:info(?USER_LOGGER, "Starting vbucket moves for graceful failover of ~p", [Node]),
    do_pre_rebalance_config_sync(ns_node_disco:nodes_wanted()),
    AllBucketConfigs = ns_bucket:get_buckets(),

    %% yes we're doing it second time after config sync. In case
    %% synced config is different
    case check_graceful_failover_possible(Node, AllBucketConfigs) of
        true -> ok;
        false ->
            erlang:exit(not_graceful)
    end,

    MembaseBuckets = [BC || BC = {_, Conf} <- AllBucketConfigs,
                            proplists:get_value(type, Conf) =:= membase],
    N = length(MembaseBuckets),
    lists:foldl(
      fun ({BucketName, BucketConfig}, I) ->
              do_run_graceful_failover_moves(Node, BucketName, BucketConfig, I / N, N),
              I+1
      end, 0, MembaseBuckets),
    orchestrate_failover(Node),
    erlang:exit(graceful_failover_done).

do_run_graceful_failover_moves(Node, BucketName, BucketConfig, I, N) ->
    Map = proplists:get_value(map, BucketConfig, []),
    Map1 = mb_map:promote_replicas_for_graceful_failover(Map, Node),
    run_mover(BucketName, BucketConfig, proplists:get_value(servers, BucketConfig),
              I, N, Map, Map1).

check_graceful_failover_possible(Node, BucketsAll) ->
    case check_graceful_failover_possible_rec(Node, BucketsAll) of
        false -> false;
        [] -> false;
        [_|_] -> true
    end.

check_graceful_failover_possible_rec(_Node, []) ->
    [];
check_graceful_failover_possible_rec(Node, [{BucketName, BucketConfig} | RestBucketConfigs]) ->
    Map = proplists:get_value(map, BucketConfig, []),
    Servers = proplists:get_value(servers, BucketConfig, []),
    case lists:member(Node, Servers) of
        true ->
            Map1 = mb_map:promote_replicas_for_graceful_failover(Map, Node),
            case lists:any(fun (Chain) -> hd(Chain) =:= Node end, Map1) of
                true ->
                    false;
                false ->
                    case check_graceful_failover_possible_rec(Node, RestBucketConfigs) of
                        false -> false;
                        RecRV -> [BucketName | RecRV]
                    end
            end;
        false ->
            check_graceful_failover_possible_rec(Node, RestBucketConfigs)
    end.

check_failover_possible(Node) ->
    case ns_cluster_membership:active_nodes() of
        [Node] -> %% Node is bound
            last_node;
        ActiveNodes ->
            case lists:member(Node, ActiveNodes) of
                true ->
                    case ns_cluster_membership:filter_out_non_kv_nodes(ActiveNodes) of
                        %% Node is bound
                        [Node] ->
                            last_node;
                        _ ->
                            ok
                    end;
                false ->
                    unknown_node
            end
    end.

drop_old_2i_indexes(KeepNodes) ->
    case cluster_compat_mode:is_cluster_sherlock() of
        false ->
            ok;
        true ->
            Config = ns_config:get(),
            NewNodes = KeepNodes -- ns_cluster_membership:active_nodes(Config),
            ?rebalance_info("Going to drop possible old 2i indexes on nodes ~p", [NewNodes]),
            {Oks, RPCErrors, Downs} = misc:rpc_multicall_with_plist_result(
                                        NewNodes,
                                        ns_storage_conf, delete_old_2i_indexes, []),
            Errors = [{N, RV}
                      || {N, RV} <- Oks,
                         RV =/= ok]
                ++ RPCErrors
                ++ [{N, timeout} || N <- Downs],
            case Errors of
                [] ->
                    ?rebalance_debug("Cleanup succeeded: ~p", [Oks]),
                    ok;
                _ ->
                    ?rebalance_error("Failed to cleanup indexes: ~p", [Errors]),
                    {old_indexes_cleanup_failed, Errors}
            end
    end.
