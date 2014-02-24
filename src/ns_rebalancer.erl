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

-export([failover/1,
         validate_autofailover/1,
         generate_initial_map/1,
         rebalance/3,
         run_mover/7,
         unbalanced/3,
         map_options_changed/2,
         eject_nodes/1,
         maybe_cleanup_old_buckets/1]).

-export([wait_local_buckets_shutdown_complete/0]). % used via rpc:multicall


-define(DATA_LOST, 1).
-define(BAD_REPLICATORS, 2).

-define(BUCKETS_SHUTDOWN_WAIT_TIMEOUT, 20000).

-define(REBALANCER_READINESS_WAIT_SECONDS, 60).

%%
%% API
%%

%% @doc Fail a node. Doesn't eject the node from the cluster. Takes
%% effect immediately.
failover(Node) ->
    lists:foreach(fun (Bucket) ->
                          master_activity_events:note_bucket_failover_started(Bucket, Node),
                          failover(Bucket, Node),
                          master_activity_events:note_bucket_failover_ended(Bucket, Node)
                  end,
                  ns_bucket:get_bucket_names()).

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

-spec failover(string(), atom()) -> ok | janitor_failed.
failover(Bucket, Node) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
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
               {value, [_]} ->
                   undefined;
               false ->
                   undefined;
               {value, ServerGroups} ->
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
           end,

    Opts0 = ns_bucket:config_to_map_options(BucketConfig),
    misc:update_proplist(Opts0, [{replication_topology, ReplicationTopology},
                                 {tags, Tags}]).

generate_vbucket_map(CurrentMap, KeepNodes, BucketConfig) ->
    Opts = generate_vbucket_map_options(KeepNodes, BucketConfig),
    EffectiveOpts = [{maps_history, ns_bucket:past_vbucket_maps()} | Opts],

    {mb_map:generate_map(CurrentMap, KeepNodes, EffectiveOpts), Opts}.

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
    {Good, ReallyBad, FailedNodes} = multicall_ignoring_undefined(KeepNodes, ns_rebalancer, wait_local_buckets_shutdown_complete, []),
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

rebalance(KeepNodes, EjectNodesAll, FailedNodesAll) ->
    %% TODO: pull config reliably here as well
    ns_config:sync_announcements(),
    case ns_config_rep:synchronize_remote(KeepNodes) of
        ok ->
            cool;
        {error, SyncFailedNodes} ->
            exit({pre_rebalance_config_synchronization_failed, SyncFailedNodes})
    end,

    %% now wait when all bucket shutdowns are done on nodes we're
    %% adding (or maybe adding)
    do_wait_buckets_shutdown(KeepNodes),

    %% don't eject ourselves at all here; this will be handled by ns_orchestrator
    EjectNodes = EjectNodesAll -- [node()],
    FailedNodes = FailedNodesAll -- [node()],

    LiveNodes = KeepNodes ++ EjectNodesAll,
    AllNodes = LiveNodes ++ FailedNodesAll,
    BucketConfigs = ns_bucket:get_buckets(),
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
                                            || N <- AllNodes])),
                          case proplists:get_value(type, BucketConfig) of
                              memcached ->
                                  master_activity_events:note_bucket_rebalance_started(BucketName),
                                  ns_bucket:set_servers(BucketName, KeepNodes),
                                  master_activity_events:note_bucket_rebalance_ended(BucketName);
                              membase ->
                                  %% Only start one bucket at a time to avoid
                                  %% overloading things
                                  ThisEjected = ordsets:intersection(lists:sort(proplists:get_value(servers, BucketConfig, [])),
                                                                     lists:sort(EjectNodesAll)),
                                  ThisLiveNodes = KeepNodes ++ ThisEjected,
                                  ns_bucket:set_servers(BucketName, ThisLiveNodes),
                                  Pid = erlang:spawn_link(
                                          fun () ->
                                                  ?rebalance_info("Waiting for bucket ~p to be ready on ~p", [BucketName, ThisLiveNodes]),
                                                  {ok, _States, Zombies} = janitor_agent:query_states(BucketName, ThisLiveNodes, ?REBALANCER_READINESS_WAIT_SECONDS),
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
                                          exit(stop);
                                      {'DOWN', MRef, _, _, _} ->
                                          ok
                                  end,
                                  case ns_janitor:cleanup(BucketName, [{timeout, 10}]) of
                                      ok -> ok;
                                      {error, _, BadNodes} ->
                                          exit({pre_rebalance_janitor_run_failed, BadNodes})
                                  end,
                                  {ok, NewConf} =
                                      ns_bucket:get_bucket(BucketName),
                                  master_activity_events:note_bucket_rebalance_started(BucketName),
                                  {NewMap, MapOptions} =
                                      rebalance(BucketName, NewConf,
                                                KeepNodes, BucketCompletion,
                                                NumBuckets),
                                  ns_bucket:set_map_opts(BucketName, MapOptions),
                                  master_activity_events:note_bucket_rebalance_ended(BucketName),
                                  verify_replication(BucketName, KeepNodes, NewMap)
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
rebalance(Bucket, Config, KeepNodes, BucketCompletion, NumBuckets) ->
    Map = proplists:get_value(map, Config),
    {FastForwardMap, MapOptions} = generate_vbucket_map(Map, KeepNodes, Config),
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
                    SecondsToWait = ns_config_ets_dup:unreliable_read_key(rebalance_out_delay_seconds, 10),
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
-spec unbalanced_chain(map(), [atom()]) -> boolean().
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

    lists:any(
      fun (Counts0) ->
              Counts = [C || {_, C} <- Counts0],
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
                          ns_cluster:leave(N)
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
            erlang:unlink(Pid),
            (catch Pid ! {'EXIT', self(), shutdown}),
            wait_for_mover_tail(Pid, Ref);
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

multicall_ignoring_undefined(Nodes, M, F, A) ->
    {Results, DownNodes} = rpc:multicall(Nodes, M, F, A),

    {Good, Bad} =
        misc:multicall_result_to_plist(Nodes, {Results, DownNodes}),
    ReallyBad =
        lists:filter(
          fun ({_Node, Reason}) ->
                  case Reason of
                      {'EXIT', ExitReason} ->
                          %% this may be just an old node; if so, ignore it
                          not misc:is_undef_exit(M, F, A, ExitReason);
                      _ ->
                          true
                  end
          end, Bad),
    {Good, ReallyBad, DownNodes}.

maybe_cleanup_old_buckets(KeepNodes) ->
    case multicall_ignoring_undefined(KeepNodes, ns_storage_conf, delete_unused_buckets_db_files, []) of
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
