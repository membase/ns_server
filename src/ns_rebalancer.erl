%% @author Couchbase <info@couchbase.com>
%% @copyright 2010-2018 Couchbase, Inc.
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

-include("cut.hrl").
-include("ns_common.hrl").
-include("ns_stats.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([orchestrate_failover/1,
         check_graceful_failover_possible/2,
         validate_autofailover/1,
         generate_initial_map/1,
         start_link_rebalance/5,
         move_vbuckets/2,
         unbalanced/2,
         map_options_changed/1,
         eject_nodes/1,
         maybe_cleanup_old_buckets/1,
         get_delta_recovery_nodes/2,
         verify_replication/3,
         start_link_graceful_failover/1,
         generate_vbucket_map_options/2,
         run_failover/1,
         rebalance_topology_aware_services/4]).

-export([wait_local_buckets_shutdown_complete/0]). % used via rpc:multicall


-define(DATA_LOST, 1).
-define(BAD_REPLICATORS, 2).

-define(DEFAULT_BUCKETS_SHUTDOWN_WAIT_TIMEOUT, 20000).

-define(REBALANCER_READINESS_WAIT_TIMEOUT,
        ns_config:get_timeout({ns_rebalancer, readiness}, 60000)).
-define(REBALANCER_QUERY_STATES_TIMEOUT,
        ns_config:get_timeout({ns_rebalancer, query_states}, 10000)).
-define(REBALANCER_APPLY_CONFIG_TIMEOUT,
        ns_config:get_timeout({ns_rebalancer, apply_config}, 300000)).

%%
%% API
%%

run_failover(Nodes) ->
    misc:executing_on_new_process(
      fun () ->
              ok = check_no_tap_buckets(),

              case check_failover_possible(Nodes) of
                  ok ->
                      ns_rebalancer:orchestrate_failover(Nodes);
                  Error ->
                      Error
              end
      end).

orchestrate_failover(Nodes) ->
    ale:info(?USER_LOGGER, "Starting failing over ~p", [Nodes]),
    master_activity_events:note_failover(Nodes),
    failover(Nodes),
    ale:info(?USER_LOGGER, "Failed over ~p: ok", [Nodes]),
    ns_cluster:counter_inc(failover_node),
    ns_cluster_membership:deactivate(Nodes),
    ok.


%% @doc Fail one or more nodes. Doesn't eject the node from the cluster. Takes
%% effect immediately.
failover(Nodes) ->
    ok = failover_buckets(Nodes),
    ok = failover_services(Nodes).

failover_buckets(Nodes) ->
    BucketConfigs = ns_bucket:get_buckets(),
    Results       =
        lists:flatmap(fun ({Bucket, BucketConfig}) ->
                              failover_bucket(Bucket, BucketConfig, Nodes)
                      end, BucketConfigs),

    lists:foreach(
      fun ({N, FailoverVBuckets0}) ->
              FailoverVBuckets = [{B, VBs} || {B, _, VBs} <- FailoverVBuckets0],
              ns_config:set({node, N, failover_vbuckets}, FailoverVBuckets)
      end, misc:sort_and_keygroup(2, Results)).

failover_bucket(Bucket, BucketConfig, Nodes) ->
    master_activity_events:note_bucket_failover_started(Bucket, Nodes),

    Type   = ns_bucket:bucket_type(BucketConfig),
    Result = do_failover_bucket(Type, Bucket, BucketConfig, Nodes),

    master_activity_events:note_bucket_failover_ended(Bucket, Nodes),

    Result.

do_failover_bucket(memcached, Bucket, BucketConfig, Nodes) ->
    failover_memcached_bucket(Nodes, Bucket, BucketConfig),
    [];
do_failover_bucket(membase, Bucket, BucketConfig, Nodes) ->
    Map = proplists:get_value(map, BucketConfig, []),
    failover_membase_bucket(Nodes, Bucket, BucketConfig, Map),
    [{Bucket, N, node_vbuckets(Map, N)} || N <- Nodes].

failover_services(Nodes) ->
    Config    = ns_config:get(),
    Services0 = lists:flatmap(
                  ns_cluster_membership:node_services(Config, _), Nodes),
    Services  = lists:usort(Services0) -- [kv],

    case cluster_compat_mode:is_cluster_41() of
        true ->
            lists:foreach(failover_service(Config, _, Nodes), Services);
        false ->
            ok
    end.

failover_service(Config, Service, Nodes) ->
    ns_cluster_membership:failover_service_nodes(Config, Service, Nodes),
    case service_janitor:complete_service_failover(Service) of
        ok ->
            ?log_debug("Failed over service ~p on nodes ~p successfully",
                       [Service, Nodes]);
        Error ->
            ?log_error("Failed to failover service ~p on nodes ~p: ~p",
                       [Service, Nodes, Error])
    end.

get_failover_vbuckets(Config, Node) ->
    ns_config:search(Config, {node, Node, failover_vbuckets}, []).

validate_autofailover(Nodes) ->
    BucketPairs = ns_bucket:get_buckets(),
    UnsafeBuckets =
        [BucketName
         || {BucketName, BucketConfig} <- BucketPairs,
            validate_autofailover_bucket(BucketConfig, Nodes) =:= false],
    case UnsafeBuckets of
        [] -> ok;
        _ -> {error, UnsafeBuckets}
    end.

validate_autofailover_bucket(BucketConfig, Nodes) ->
    case proplists:get_value(type, BucketConfig) of
        membase ->
            Map = proplists:get_value(map, BucketConfig),
            Map1 = mb_map:promote_replicas(Map, Nodes),
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

failover_memcached_bucket(Nodes, Bucket, BucketConfig) ->
    remove_nodes_from_server_list(Nodes, Bucket, BucketConfig).

failover_membase_bucket(Nodes, Bucket, BucketConfig, Map) when Map =:= [] ->
    %% this is possible if bucket just got created and ns_janitor didn't get a
    %% chance to create a map yet; or alternatively, if it failed to do so
    %% because, for example, one of the nodes was down
    failover_membase_bucket_with_no_map(Nodes, Bucket, BucketConfig);
failover_membase_bucket(Nodes, Bucket, BucketConfig, Map) ->
    failover_membase_bucket_with_map(Nodes, Bucket, BucketConfig, Map).

failover_membase_bucket_with_no_map(Nodes, Bucket, BucketConfig) ->
    ?log_debug("Skipping failover of bucket ~p because it has no vbuckets. "
               "Config:~n~p", [Bucket, BucketConfig]),

    %% we still need to make sure to remove ourselves from the bucket server
    %% list
    remove_nodes_from_server_list(Nodes, Bucket, BucketConfig),
    ok.

failover_membase_bucket_with_map(Nodes, Bucket, BucketConfig, Map) ->
    %% Promote replicas of vbuckets on this node
    NewMap = mb_map:promote_replicas(Map, Nodes),
    true = (NewMap =/= undefined),

    case [I || {I, [undefined|_]} <- misc:enumerate(NewMap, 0)] of
        [] -> ok; % Phew!
        MissingVBuckets ->
            ?rebalance_error("Lost data in ~p for ~w", [Bucket, MissingVBuckets]),
            ?user_log(?DATA_LOST,
                      "Data has been lost for ~B% of vbuckets in bucket ~p.",
                      [length(MissingVBuckets) * 100 div length(Map), Bucket])
    end,

    ns_bucket:set_fast_forward_map(Bucket, undefined),
    ns_bucket:set_map(Bucket, NewMap),
    remove_nodes_from_server_list(Nodes, Bucket, BucketConfig),
    try ns_janitor:cleanup(Bucket, []) of
        ok ->
            ok;
        {error, _, BadNodes} ->
            ?rebalance_error("Skipped vbucket activations and "
                             "replication topology changes because not "
                             "all remaining nodes were found to have "
                             "healthy bucket ~p: ~p", [Bucket, BadNodes]),
            janitor_failed
    catch
        E:R ->
            ?rebalance_error("Janitor cleanup of ~p failed after failover of ~p: ~p",
                             [Bucket, Nodes, {E, R}]),
            janitor_failed
    end.

remove_nodes_from_server_list(Nodes, Bucket, BucketConfig) ->
    Servers = proplists:get_value(servers, BucketConfig),
    ns_bucket:set_servers(Bucket, Servers -- Nodes).

generate_vbucket_map_options(KeepNodes, BucketConfig) ->
    Config = ns_config:get(),
    generate_vbucket_map_options(KeepNodes, BucketConfig, Config).

generate_vbucket_map_options(KeepNodes, BucketConfig, Config) ->
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

    %% Note that we don't need to have replication_topology here (in fact as
    %% of today it's still returned by ns_bucket:config_to_map_options/1), but
    %% these options are used to compute map_opts_hash which in turn is used
    %% to decide if rebalance is needed. So if we remove this, old nodes will
    %% wrongly believe that rebalance is needed even when the cluster is
    %% balanced. See MB-15543 for details.
    misc:update_proplist(Opts0, [{replication_topology, star},
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
    ExcessiveBuckets =
        ns_memcached:active_buckets() -- ns_bucket:node_bucket_names(node()),
    do_wait_local_buckets_shutdown_complete(ExcessiveBuckets).

do_wait_local_buckets_shutdown_complete([]) ->
    ok;
do_wait_local_buckets_shutdown_complete(ExcessiveBuckets) ->
    Timeout = ns_config:get_timeout(buckets_shutdown, ?DEFAULT_BUCKETS_SHUTDOWN_WAIT_TIMEOUT)
        * length(ExcessiveBuckets),
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
              erlang:send_after(Timeout, Parent, {Ref, timeout}),
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

pull_and_push_config(Nodes) ->
    case ns_config_rep:pull_remotes(Nodes) of
        ok ->
            ok;
        Error ->
            exit({config_sync_failed, Error})
    end,

    %% And after we have that, make sure recovery, rebalance and
    %% graceful failover, all start with latest config reliably
    case ns_config_rep:ensure_config_seen_by_nodes(Nodes) of
        ok ->
            cool;
        {error, SyncFailedNodes} ->
            exit({config_sync_failed, SyncFailedNodes})
    end.

start_link_rebalance(KeepNodes, EjectNodes,
                     FailedNodes, DeltaNodes, DeltaRecoveryBucketNames) ->
    proc_lib:start_link(
      erlang, apply,
      [fun () ->
               ok = check_no_tap_buckets(),

               KVKeep = ns_cluster_membership:service_nodes(KeepNodes, kv),
               case KVKeep =:= [] of
                   true ->
                       proc_lib:init_ack({error, no_kv_nodes_left}),
                       exit(normal);
                   false ->
                       ok
               end,

               KVDeltaNodes = ns_cluster_membership:service_nodes(DeltaNodes,
                                                                  kv),
               BucketConfigs = ns_bucket:get_buckets(),
               case build_delta_recovery_buckets(KVKeep, KVDeltaNodes,
                                                 BucketConfigs, DeltaRecoveryBucketNames) of
                   {ok, DeltaRecoveryBucketTuples} ->
                       proc_lib:init_ack({ok, self()}),

                       master_activity_events:note_rebalance_start(
                         self(), KeepNodes, EjectNodes, FailedNodes, DeltaNodes),

                       rebalance(KeepNodes, EjectNodes, FailedNodes,
                                 BucketConfigs,
                                 DeltaNodes, DeltaRecoveryBucketTuples);
                   {error, not_possible} ->
                       proc_lib:init_ack({error, delta_recovery_not_possible})
               end
       end, []]).

move_vbuckets(Bucket, Moves) ->
    {ok, Config} = ns_bucket:get_bucket(Bucket),
    Map = proplists:get_value(map, Config),
    TMap = lists:foldl(fun ({VBucket, TargetChain}, Map0) ->
                               setelement(VBucket+1, Map0, TargetChain)
                       end, list_to_tuple(Map), Moves),
    NewMap = tuple_to_list(TMap),
    ProgressFun = make_progress_fun(0, 1),
    run_mover(Bucket, Config,
              proplists:get_value(servers, Config),
              ProgressFun, Map, NewMap).

rebalance_services(KeepNodes, EjectNodes) ->
    Config = ns_config:get(),

    AllServices = ns_cluster_membership:cluster_supported_services() -- [kv],
    TopologyAwareServices = ns_cluster_membership:topology_aware_services(),
    SimpleServices = AllServices -- TopologyAwareServices,

    SimpleTSs = rebalance_simple_services(Config, SimpleServices, KeepNodes),
    TopologyAwareTSs = rebalance_topology_aware_services(Config, TopologyAwareServices,
                                                         KeepNodes, EjectNodes),

    maybe_delay_eject_nodes(SimpleTSs ++ TopologyAwareTSs, EjectNodes).

rebalance_simple_services(Config, Services, KeepNodes) ->
    case cluster_compat_mode:is_cluster_41(Config) of
        true ->
            lists:filtermap(
              fun (Service) ->
                      ServiceNodes = ns_cluster_membership:service_nodes(KeepNodes, Service),
                      Updated = update_service_map_with_config(Config, Service, ServiceNodes),

                      case Updated of
                          false ->
                              false;
                          true ->
                              {true, {Service, os:timestamp()}}
                      end
              end, Services);
        false ->
            []
    end.

update_service_map_with_config(Config, Service, ServiceNodes0) ->
    CurrentNodes0 = ns_cluster_membership:get_service_map(Config, Service),
    update_service_map(Service, CurrentNodes0, ServiceNodes0).

update_service_map(Service, CurrentNodes0, ServiceNodes0) ->
    CurrentNodes = lists:sort(CurrentNodes0),
    ServiceNodes = lists:sort(ServiceNodes0),

    case CurrentNodes =:= ServiceNodes of
        true ->
            false;
        false ->
            ?rebalance_info("Updating service map for ~p:~n~p",
                            [Service, ServiceNodes]),
            ok = ns_cluster_membership:set_service_map(Service, ServiceNodes),
            true
    end.

rebalance_topology_aware_services(Config, Services, KeepNodesAll, EjectNodesAll) ->
    %% TODO: support this one day
    DeltaNodesAll = [],

    lists:filtermap(
      fun (Service) ->
              KeepNodes = ns_cluster_membership:service_nodes(Config, KeepNodesAll, Service),
              DeltaNodes = ns_cluster_membership:service_nodes(Config, DeltaNodesAll, Service),

              %% if a node being ejected is not active, then it means that it
              %% was never rebalanced in in the first place; so we can
              %% postpone the heat death of the universe a little bit by
              %% ignoring such nodes
              ActiveNodes = ns_cluster_membership:get_service_map(Config, Service),
              EjectNodes = [N || N <- EjectNodesAll,
                                 lists:member(N, ActiveNodes)],

              AllNodes = EjectNodes ++ KeepNodes,

              case AllNodes of
                  [] ->
                      false;
                  _ ->
                      update_service_map_with_config(Config, Service, AllNodes),
                      ok = rebalance_topology_aware_service(Service, KeepNodes,
                                                            EjectNodes, DeltaNodes),
                      update_service_map(Service, AllNodes, KeepNodes),
                      {true, {Service, os:timestamp()}}
              end
      end, Services).

rebalance_topology_aware_service(Service, KeepNodes, EjectNodes, DeltaNodes) ->
    ProgressCallback =
        fun (Progress) ->
                ns_orchestrator:update_progress(Service, Progress)
        end,

    misc:with_trap_exit(
      fun () ->
              {Pid, MRef} = service_rebalancer:spawn_monitor_rebalance(
                              Service, KeepNodes,
                              EjectNodes, DeltaNodes, ProgressCallback),

              receive
                  {'EXIT', _Pid, Reason} ->
                      misc:terminate_and_wait(Pid, Reason),
                      exit(Reason);
                  {'DOWN', MRef, _, _, Reason} ->
                      case Reason of
                          normal ->
                              ok;
                          _ ->
                              exit({service_rebalance_failed, Service, Reason})
                      end
              end
      end).

get_service_eject_delay(Service) ->
    Default =
        case Service of
            n1ql ->
                20000;
            fts ->
                10000;
            _ ->
                0
        end,

    ns_config:get_timeout({eject_delay, Service}, Default).

maybe_delay_eject_nodes(Timestamps, EjectNodes) ->
    case cluster_compat_mode:is_cluster_41() of
        true ->
            do_maybe_delay_eject_nodes(Timestamps, EjectNodes);
        false ->
            ok
    end.

do_maybe_delay_eject_nodes(_Timestamps, []) ->
    ok;
do_maybe_delay_eject_nodes(Timestamps, EjectNodes) ->
    EjectedServices =
        ordsets:union([ordsets:from_list(ns_cluster_membership:node_services(N))
                       || N <- EjectNodes]),
    Now = os:timestamp(),

    Delays = [begin
                  ServiceDelay = get_service_eject_delay(Service),

                  case proplists:get_value(Service, Timestamps) of
                      undefined ->
                          %% it's possible that a node is ejected without ever
                          %% getting rebalanced in; there's no point in
                          %% delaying anything in such case
                          0;
                      RebalanceTS ->
                          SinceRebalance = max(0, timer:now_diff(Now, RebalanceTS) div 1000),
                          ServiceDelay - SinceRebalance
                  end
              end || Service <- EjectedServices],

    Delay = lists:max(Delays),

    case Delay > 0 of
        true ->
            ?log_info("Waiting ~pms before ejecting nodes:~n~p",
                      [Delay, EjectNodes]),
            timer:sleep(Delay);
        false ->
            ok
    end.

rebalance(KeepNodes, EjectNodesAll, FailedNodesAll,
          BucketConfigs,
          DeltaNodes, DeltaRecoveryBuckets) ->
    ok = drop_old_2i_indexes(KeepNodes),
    KVDeltaNodes = ns_cluster_membership:service_nodes(DeltaNodes, kv),
    ok = apply_delta_recovery_buckets(DeltaRecoveryBuckets, KVDeltaNodes, BucketConfigs),
    ok = maybe_clear_full_recovery_type(KeepNodes),

    ok = service_janitor:cleanup(),

    ns_cluster_membership:activate(KeepNodes),

    pull_and_push_config(EjectNodesAll ++ KeepNodes),

    %% Eject failed nodes first so they don't cause trouble
    FailedNodes = FailedNodesAll -- [node()],
    eject_nodes(FailedNodes),

    rebalance_kv(KeepNodes, EjectNodesAll, BucketConfigs, DeltaRecoveryBuckets),
    rebalance_services(KeepNodes, EjectNodesAll),

    ok = ns_config_rep:ensure_config_seen_by_nodes(KeepNodes),

    %% don't eject ourselves at all here; this will be handled by ns_orchestrator
    EjectNodes = EjectNodesAll -- [node()],
    eject_nodes(EjectNodes).

make_progress_fun(BucketCompletion, NumBuckets) ->
    fun (P) ->
            Progress = dict:map(fun (_, N) ->
                                        N / NumBuckets + BucketCompletion
                                end, P),
            update_kv_progress(Progress)
    end.

update_kv_progress(Progress) ->
    ns_orchestrator:update_progress(kv, Progress).

update_kv_progress(Nodes, Progress) ->
    update_kv_progress(dict:from_list([{N, Progress} || N <- Nodes])).

rebalance_kv(KeepNodes, EjectNodes, BucketConfigs, DeltaRecoveryBuckets) ->
    %% wait when all bucket shutdowns are done on nodes we're
    %% adding (or maybe adding)
    do_wait_buckets_shutdown(KeepNodes),

    NumBuckets = length(BucketConfigs),
    ?rebalance_debug("BucketConfigs = ~p", [sanitize(BucketConfigs)]),

    KeepKVNodes = ns_cluster_membership:service_nodes(KeepNodes, kv),
    LiveKVNodes = ns_cluster_membership:service_nodes(KeepNodes ++ EjectNodes, kv),

    case maybe_cleanup_old_buckets(KeepNodes) of
        ok ->
            ok;
        Error ->
            exit(Error)
    end,

    {ok, RebalanceObserver} = ns_rebalance_observer:start_link(length(BucketConfigs)),

    lists:foreach(fun ({I, {BucketName, BucketConfig}}) ->
                          BucketCompletion = I / NumBuckets,
                          update_kv_progress(LiveKVNodes, BucketCompletion),

                          ProgressFun = make_progress_fun(BucketCompletion, NumBuckets),
                          rebalance_bucket(BucketName, BucketConfig, ProgressFun,
                                           KeepKVNodes, EjectNodes, DeltaRecoveryBuckets)
                  end, misc:enumerate(BucketConfigs, 0)),

    update_kv_progress(LiveKVNodes, 1.0),
    misc:unlink_terminate_and_wait(RebalanceObserver, shutdown).

rebalance_bucket(BucketName, BucketConfig, ProgressFun,
                 KeepKVNodes, EjectNodes, DeltaRecoveryBuckets) ->
    ale:info(?USER_LOGGER, "Started rebalancing bucket ~s", [BucketName]),
    ?rebalance_info("Rebalancing bucket ~p with config ~p",
                    [BucketName, sanitize(BucketConfig)]),
    case proplists:get_value(type, BucketConfig) of
        memcached ->
            rebalance_memcached_bucket(BucketName, KeepKVNodes);
        membase ->
            rebalance_membase_bucket(BucketName, BucketConfig, ProgressFun,
                                     KeepKVNodes, EjectNodes, DeltaRecoveryBuckets)
    end.

rebalance_memcached_bucket(BucketName, KeepKVNodes) ->
    master_activity_events:note_bucket_rebalance_started(BucketName),
    ns_bucket:set_servers(BucketName, KeepKVNodes),
    master_activity_events:note_bucket_rebalance_ended(BucketName).

rebalance_membase_bucket(BucketName, BucketConfig, ProgressFun,
                         KeepKVNodes, EjectNodes, DeltaRecoveryBuckets) ->
    %% Only start one bucket at a time to avoid
    %% overloading things
    ThisEjected = ordsets:intersection(lists:sort(proplists:get_value(servers, BucketConfig, [])),
                                       lists:sort(EjectNodes)),
    ThisLiveNodes = KeepKVNodes ++ ThisEjected,
    ns_bucket:set_servers(BucketName, ThisLiveNodes),
    ?rebalance_info("Waiting for bucket ~p to be ready on ~p", [BucketName, ThisLiveNodes]),
    {ok, _States, Zombies} = janitor_agent:query_states(BucketName, ThisLiveNodes, ?REBALANCER_READINESS_WAIT_TIMEOUT),
    case Zombies of
        [] ->
            ?rebalance_info("Bucket is ready on all nodes"),
            ok;
        _ ->
            exit({not_all_nodes_are_ready_yet, Zombies})
    end,

    run_janitor_pre_rebalance(BucketName),

    {ok, NewConf} =
        ns_bucket:get_bucket(BucketName),
    master_activity_events:note_bucket_rebalance_started(BucketName),
    {NewMap, MapOptions} =
        do_rebalance_membase_bucket(BucketName, NewConf,
                                    KeepKVNodes, ProgressFun, DeltaRecoveryBuckets),
    ns_bucket:set_map_opts(BucketName, MapOptions),
    ns_bucket:update_bucket_props(BucketName,
                                  [{deltaRecoveryMap, undefined}]),
    master_activity_events:note_bucket_rebalance_ended(BucketName),
    run_verify_replication(BucketName, KeepKVNodes, NewMap).

run_janitor_pre_rebalance(BucketName) ->
    case ns_janitor:cleanup(BucketName,
                            [{query_states_timeout, ?REBALANCER_QUERY_STATES_TIMEOUT},
                             {apply_config_timeout, ?REBALANCER_APPLY_CONFIG_TIMEOUT}]) of
        ok ->
            ok;
        {error, _, BadNodes} ->
            exit({pre_rebalance_janitor_run_failed, BadNodes})
    end.

%% @doc Rebalance the cluster. Operates on a single bucket. Will
%% either return ok or exit with reason 'stopped' or whatever reason
%% was given by whatever failed.
do_rebalance_membase_bucket(Bucket, Config,
                            KeepNodes, ProgressFun, DeltaRecoveryBuckets) ->
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
    {run_mover(Bucket, Config, KeepNodes, ProgressFun, Map, FastForwardMap),
     MapOptions}.

run_mover(Bucket, Config, KeepNodes, ProgressFun, Map, FastForwardMap) ->
    ?rebalance_info("Target map (distance: ~p):~n~p", [(catch mb_map:vbucket_movements(Map, FastForwardMap)), FastForwardMap]),
    ns_bucket:set_fast_forward_map(Bucket, FastForwardMap),
    misc:with_trap_exit(
      fun () ->
              {ok, Pid} = ns_vbucket_mover:start_link(Bucket, Map,
                                                      FastForwardMap,
                                                      ProgressFun),
              wait_for_mover(Pid)
      end),

    HadRebalanceOut = ((proplists:get_value(servers, Config, []) -- KeepNodes) =/= []),
    case HadRebalanceOut of
        true ->
            SecondsToWait = ns_config:read_key_fast(rebalance_out_delay_seconds, 10),
            ?rebalance_info("Waiting ~w seconds before completing rebalance out."
                            " So that clients receive graceful not my vbucket instead of silent closed connection", [SecondsToWait]),
            timer:sleep(SecondsToWait * 1000);
        false ->
            ok
    end,
    ns_bucket:set_fast_forward_map(Bucket, undefined),
    ns_bucket:set_servers(Bucket, KeepNodes),
    FastForwardMap.

unbalanced(Map, BucketConfig) ->
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

    R orelse do_unbalanced(Map, Servers).

do_unbalanced(Map, Servers) ->
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

map_options_changed(BucketConfig) ->
    Config = ns_config:get(),

    Servers = proplists:get_value(servers, BucketConfig, []),

    Opts = generate_vbucket_map_options(Servers, BucketConfig, Config),
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
                          ns_cluster:leave(N)
                  end, LeaveNodes).

run_verify_replication(Bucket, Nodes, Map) ->
    Pid = proc_lib:spawn_link(?MODULE, verify_replication, [Bucket, Nodes, Map]),
    ?log_debug("Spawned verify_replication worker: ~p", [Pid]),
    {trap_exit, false} = erlang:process_info(self(), trap_exit),
    misc:wait_for_process(Pid, infinity).

verify_replication(Bucket, Nodes, Map) ->
    ExpectedReplicators0 = ns_bucket:map_to_replicas(Map),
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

wait_for_mover(Pid) ->
    receive
        {'EXIT', Pid, Reason} ->
            case Reason of
                normal ->
                    ok;
                {shutdown, stop} = Stop->
                    exit(Stop);
                _ ->
                    exit({mover_crashed, Reason})
            end;
        {'EXIT', _Pid, {shutdown, stop} = Stop} ->
            ?log_debug("Got rebalance stop request"),
            TimeoutPid = diag_handler:arm_timeout(
                           5000,
                           fun (_) ->
                                   ?log_debug("Observing slow rebalance stop (mover pid: ~p)", [Pid]),
                                   timeout_diag_logger:log_diagnostics(slow_rebalance_stop)
                           end),
            try
                exit(Pid, Stop),
                wait_for_mover(Pid)
            after
                diag_handler:disarm_timeout(TimeoutPid)
            end;
        {'EXIT', _Pid, Reason} ->
            exit(Reason)
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
    [V || {V, Chain} <- misc:enumerate(Map, 0),
          lists:member(Node, Chain)].

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

membase_delta_recovery_buckets(DeltaRecoveryBuckets, MembaseBucketConfigs) ->
    MembaseBuckets = [Bucket || {Bucket, _} <- MembaseBucketConfigs],

    case DeltaRecoveryBuckets of
        all ->
            MembaseBuckets;
        _ when is_list(DeltaRecoveryBuckets) ->
            ordsets:to_list(ordsets:intersection(ordsets:from_list(MembaseBuckets),
                                                 ordsets:from_list(DeltaRecoveryBuckets)))
    end.

build_delta_recovery_buckets(_AllNodes, [] = _DeltaNodes, _AllBucketConfigs, _DeltaRecoveryBuckets) ->
    {ok, []};
build_delta_recovery_buckets(AllNodes, DeltaNodes, AllBucketConfigs, DeltaRecoveryBuckets0) ->
    Config = ns_config:get(),

    MembaseBuckets = [P || {_, BucketConfig} = P <- AllBucketConfigs,
                           proplists:get_value(type, BucketConfig) =:= membase],
    DeltaRecoveryBuckets = membase_delta_recovery_buckets(DeltaRecoveryBuckets0, MembaseBuckets),

    %% such non-lazy computation of recovery map is suboptimal, but
    %% it's not that big deal suboptimal. I'm doing it for better
    %% testability of build_delta_recovery_buckets_loop
    MappedConfigs = [{Bucket,
                      BucketConfig,
                      find_delta_recovery_map(Config, AllNodes, DeltaNodes,
                                              Bucket, BucketConfig)}
                     || {Bucket, BucketConfig} <- MembaseBuckets],

    case build_delta_recovery_buckets_loop(MappedConfigs, DeltaRecoveryBuckets, []) of
        {ok, Recovered0} ->
            RV = [{Bucket,
                   build_transitional_bucket_config(BucketConfig, Map, Opts, DeltaNodes),
                   {Map, Opts}}
                  || {Bucket, BucketConfig, {Map, Opts}} <- Recovered0],
            {ok, RV};
        Error ->
            Error
    end.

build_delta_recovery_buckets_loop([] = _MappedConfigs, _DeltaRecoveryBuckets, Acc) ->
    {ok, Acc};
build_delta_recovery_buckets_loop(MappedConfigs, DeltaRecoveryBuckets, Acc) ->
    [{Bucket, BucketConfig, RecoverResult0} | RestMapped] = MappedConfigs,

    NeedBucket = lists:member(Bucket, DeltaRecoveryBuckets),
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
                    {error, not_possible};
                false ->
                    build_delta_recovery_buckets_loop(RestMapped, DeltaRecoveryBuckets, Acc)
            end
    end.

membase_delta_recovery_buckets_test() ->
    MembaseBuckets = [{"b1", conf}, {"b3", conf}],
    ["b1", "b3"] = membase_delta_recovery_buckets(["b1", "b2", "b3", "b4"], MembaseBuckets),
    ["b1", "b3"] = membase_delta_recovery_buckets(all, MembaseBuckets).

build_delta_recovery_buckets_loop_test() ->
    MappedConfigs = [{"b1", conf1, {map, opts}},
                     {"b2", conf2, false}],
    All = membase_delta_recovery_buckets(all, [{"b1", conf}, {"b2", conf}]),

    {ok, []} = build_delta_recovery_buckets_loop([], All, []),
    {error, not_possible} = build_delta_recovery_buckets_loop(MappedConfigs, All, []),
    {error, not_possible} = build_delta_recovery_buckets_loop(MappedConfigs, ["b2"], []),
    {error, not_possible} = build_delta_recovery_buckets_loop(MappedConfigs, ["b1", "b2"], []),
    {ok, []} = build_delta_recovery_buckets_loop(MappedConfigs, [], []),
    ?assertEqual({ok, [{"b1", conf1, {map, opts}}]},
                 build_delta_recovery_buckets_loop(MappedConfigs, ["b1"], [])),
    ?assertEqual({ok, [{"b1", conf1, {map, opts}}]},
                 build_delta_recovery_buckets_loop([hd(MappedConfigs)], All, [])).

apply_delta_recovery_buckets([], _DeltaNodes, _CurrentBuckets) ->
    ok;
apply_delta_recovery_buckets(DeltaRecoveryBuckets, DeltaNodes, CurrentBuckets) ->
    NewBuckets = misc:update_proplist(
                   CurrentBuckets,
                   [{Bucket, BucketConfig} ||
                       {Bucket, BucketConfig, _} <- DeltaRecoveryBuckets]),
    NodeChanges = [[{{node, N, recovery_type}, none},
                    {{node, N, failover_vbuckets}, []},
                    {{node, N, membership}, active}] || N <- DeltaNodes],
    BucketChanges = {buckets, [{configs, NewBuckets}]},

    Changes = lists:flatten([BucketChanges, NodeChanges]),
    ok = ns_config:set(Changes),

    case ns_config_rep:ensure_config_seen_by_nodes(DeltaNodes) of
        ok ->
            cool;
        {error, SyncFailedNodes} ->
            exit({delta_recovery_config_synchronization_failed, SyncFailedNodes})
    end,

    lists:foreach(
      fun ({Bucket, _, _}) ->
              ok = wait_for_bucket(Bucket, DeltaNodes)
      end, DeltaRecoveryBuckets),

    ok.

maybe_clear_full_recovery_type(Nodes) ->
    Cfg = ns_config:latest(),
    NodeChanges = [[{{node, N, recovery_type}, none},
                    {{node, N, failover_vbuckets}, []}]
                   || N <- Nodes,
                      ns_cluster_membership:get_recovery_type(Cfg, N) =:= full],
    ok = ns_config:set(lists:flatten(NodeChanges)).

wait_for_bucket(Bucket, Nodes) ->
    ?log_debug("Waiting until bucket ~p gets ready on nodes ~p", [Bucket, Nodes]),
    do_wait_for_bucket(Bucket, Nodes).

do_wait_for_bucket(Bucket, Nodes) ->
    case janitor_agent:query_states_details(Bucket, Nodes, 60000) of
        {ok, _States, []} ->
            ?log_debug("Bucket ~p became ready on nodes ~p", [Bucket, Nodes]),
            ok;
        {ok, _States, Failures} ->
            case check_failures(Failures) of
                keep_waiting ->
                    Zombies = [N || {N, _} <- Failures],
                    ?log_debug("Bucket ~p still not ready on nodes ~p",
                               [Bucket, Zombies]),
                    do_wait_for_bucket(Bucket, Zombies);
                fail ->
                    ?log_error("Bucket ~p not available on nodes ~p",
                               [Bucket, Failures]),
                    fail
            end
    end.

check_failures(Failures) ->
    case [F || {_Node, Reason} = F <- Failures, Reason =/= warming_up] of
        [] ->
            keep_waiting;
        _ ->
            fail
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
    ok = check_no_tap_buckets(),
    pull_and_push_config(ns_node_disco:nodes_wanted()),

    %% No graceful failovers for non KV node
    case lists:member(kv, ns_cluster_membership:node_services(Node)) of
        true ->
            ok;
        false ->
            erlang:exit(non_kv_node)
    end,
    case check_failover_possible([Node]) of
        ok ->
            ok;
        Error ->
            erlang:exit(Error)
    end,

    AllBucketConfigs = ns_bucket:get_buckets(),
    InterestingBuckets = [BC || BC = {_, Conf} <- AllBucketConfigs,
                                proplists:get_value(type, Conf) =:= membase,
                                %% when bucket doesn't have a vbucket map,
                                %% there's not much to do with respect to
                                %% graceful failover; so we skip these;
                                %%
                                %% note, that failover will still operate on
                                %% these buckets and, if needed, will remove
                                %% the node from server list
                                proplists:get_value(map, Conf, []) =/= []],
    NumBuckets = length(InterestingBuckets),

    case check_graceful_failover_possible(Node, InterestingBuckets) of
        true -> ok;
        false ->
            erlang:exit(not_graceful)
    end,
    proc_lib:init_ack({ok, self()}),

    ale:info(?USER_LOGGER, "Starting vbucket moves for graceful failover of ~p", [Node]),
    lists:foldl(
      fun ({BucketName, BucketConfig}, I) ->
              do_run_graceful_failover_moves(Node, BucketName, BucketConfig,
                                             I / NumBuckets, NumBuckets),
              I+1
      end, 0, InterestingBuckets),
    orchestrate_failover([Node]).

do_run_graceful_failover_moves(Node, BucketName, BucketConfig, I, N) ->
    run_janitor_pre_rebalance(BucketName),

    Map = proplists:get_value(map, BucketConfig, []),
    Map1 = mb_map:promote_replicas_for_graceful_failover(Map, Node),

    ProgressFun = make_progress_fun(I, N),
    run_mover(BucketName, BucketConfig,
              proplists:get_value(servers, BucketConfig),
              ProgressFun, Map, Map1).

check_graceful_failover_possible(Node, BucketsAll) ->
    Services = ns_cluster_membership:node_services(Node),
    case lists:member(kv, Services) of
        true ->
            case check_graceful_failover_possible_rec(Node, BucketsAll) of
                false -> false;
                _ -> true
            end;
        false ->
            false
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

check_failover_possible(Nodes) ->
    ActiveNodes = lists:sort(ns_cluster_membership:active_nodes()),
    FailoverNodes = lists:sort(Nodes),
    case ActiveNodes of
        FailoverNodes ->
            last_node;
        _ ->
            case lists:subtract(FailoverNodes, ActiveNodes) of
                [] ->
                    case ns_cluster_membership:service_nodes(ActiveNodes, kv) of
                        FailoverNodes ->
                            last_node;
                        _ ->
                            ok
                    end;
                _ ->
                    unknown_node
            end
    end.

drop_old_2i_indexes(KeepNodes) ->
    Config = ns_config:get(),
    NewNodes = KeepNodes -- ns_cluster_membership:active_nodes(Config),
    %% Only delta recovery is supported for index service.
    %% Note that if a node is running both KV and index service,
    %% and if user selects the full recovery option for such
    %% a node, then recovery_type will be set to full.
    %% But, we will treat delta and full recovery the same for
    %% the index data.
    %% Also, delta recovery for index service is different
    %% from that for the KV service. In case of index, it just
    %% means that we will not drop the indexes and their meta data.
    CleanupNodes = [N || N <- NewNodes,
                         ns_cluster_membership:get_recovery_type(Config, N) =:= none],
    ?rebalance_info("Going to drop possible old 2i indexes on nodes ~p",
                    [CleanupNodes]),
    {Oks, RPCErrors, Downs} = misc:rpc_multicall_with_plist_result(
                                CleanupNodes,
                                ns_storage_conf, delete_old_2i_indexes, []),
    RecoveryNodes = NewNodes -- CleanupNodes,
    ?rebalance_info("Going to keep possible 2i indexes on nodes ~p",
                    [RecoveryNodes]),
    %% Clear recovery type for non-KV nodes here.
    %% recovery_type for nodes running KV services gets cleared later.
    NonKV = [N || N <- RecoveryNodes,
                  not lists:member(kv, ns_cluster_membership:node_services(Config, N))],
    NodeChanges = [[{{node, N, recovery_type}, none},
                    {{node, N, membership}, active}] || N <- NonKV],
    ok = ns_config:set(lists:flatten(NodeChanges)),
    Errors = [{N, RV}
              || {N, RV} <- Oks,
                 RV =/= ok]
        ++ RPCErrors
        ++ [{N, node_down} || N <- Downs],
    case Errors of
        [] ->
            ?rebalance_debug("Cleanup succeeded: ~p", [Oks]),
            ok;
        _ ->
            ?rebalance_error("Failed to cleanup indexes: ~p", [Errors]),
            {old_indexes_cleanup_failed, Errors}
    end.

check_no_tap_buckets() ->
    case cluster_compat_mode:have_non_dcp_buckets() of
        false ->
            ok;
        {true, BadBuckets} ->
            ale:error(?USER_LOGGER,
                      "Cannot rebalance/failover with non-dcp buckets. "
                      "Non-dcp buckets: ~p", [BadBuckets]),
            {error, {found_non_dcp_buckets, BadBuckets}}
    end.
