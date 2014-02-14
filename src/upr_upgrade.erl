%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
%% @doc code that implements upgrade of the bucket to UPR protocol
%%      the main purpose of such upgrade is to make sure that
%%      the vbuckets are upgraded sequentially not causing simultaneous
%%      backfill of all vbuckets
%%
-module(upr_upgrade).

-behavior(gen_server).

-include("ns_common.hrl").

-export([get_buckets_to_upgrade/0,
         consider_trivial_upgrade/1,
         consider_trivial_upgrade/2,
         start_link/1]).

%% gen_server callbacks
-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-record(state, {buckets :: [{bucket_name(), term()}],
                num_buckets :: non_neg_integer(),
                bucket :: bucket_name(),
                bucket_config :: term(),
                progress :: dict(),
                workers :: [pid()]}).

start_link(Buckets) ->
    gen_server:start_link(?MODULE, {Buckets}, []).

code_change(_OldVsn, _Extra, State) ->
    {ok, State}.

init({Buckets}) ->
    process_flag(trap_exit, true),

    NumBuckets = length(Buckets),
    self() ! upgrade_next_bucket,

    {ok, #state{buckets = Buckets,
                num_buckets = NumBuckets,
                workers = []}}.

handle_call({apply_replication_status, Partition, Replicas}, _From,
            #state{bucket = Bucket,
                   bucket_config = Config} = State) ->
    NewReplicationType = upgrade_replication_type(Partition, Config),
    NewConfig = lists:keystore(repl_type, 1, Config,
                               {repl_type, NewReplicationType}),
    ok = apply_bucket_config(Bucket, NewConfig, Replicas),
    {reply, ok, State#state{bucket_config = NewConfig}};
handle_call({update_replication_status, Partition, Master, NumPartitions}, _From,
           #state{bucket = Bucket,
                  progress = Progress,
                  num_buckets = NumBuckets} = State) ->
    {ok, Config} = ns_bucket:get_bucket(Bucket),

    NewReplicationType = upgrade_replication_type(Partition, Config),
    NewConfig = lists:keystore(repl_type, 1, Config,
                               {repl_type, NewReplicationType}),
    ok = ns_bucket:set_bucket_config(Bucket, NewConfig),
    master_activity_events:note_vbucket_upgraded_to_upr(Bucket, Partition),
    case NewReplicationType of
        upr ->
            master_activity_events:note_bucket_upgraded_to_upr(Bucket);
        _ ->
            ok
    end,
    case Master of
        undefined ->
            {reply, ok, State};
        _ ->
            NewProgress = dict:store(Master,
                                     dict:fetch(Master, Progress) + 1 / (NumPartitions * NumBuckets),
                                     Progress),
            ns_orchestrator:update_progress(NewProgress),
            {reply, ok, State#state{progress = NewProgress}}
    end.

handle_cast(unhandled, unhandled) ->
    exit(unhandled).

handle_info(upgrade_next_bucket, #state{buckets = []} = State) ->
    {stop, normal, State};
handle_info(upgrade_next_bucket, #state{buckets = [{BucketName, BucketConfig} | Rest],
                                        num_buckets = NumBuckets} = State) ->
    BucketNodes = ns_bucket:bucket_nodes(BucketConfig),
    ok = janitor_agent:prepare_nodes_for_upr_upgrade(BucketName, BucketNodes, self()),

    IBucket = NumBuckets - (length(Rest) + 1),

    ProgressSoFar = IBucket / NumBuckets,
    Progress = dict:from_list([{N, ProgressSoFar} || N <- BucketNodes]),
    ns_orchestrator:update_progress(Progress),

    Map = proplists:get_value(map, BucketConfig),

    ReplType =
        ns_bucket:replication_type(BucketConfig),

    PartitionsToUpgrade =
        case ReplType of
            tap ->
                misc:enumerate(Map, 0);
            {upr, TapPartitions} ->
                [{Partition, Nodes} || {Partition, Nodes} <- misc:enumerate(Map, 0),
                                       ordsets:is_element(Partition, TapPartitions)]
        end,

    Workers =
        [maybe_spawn_upgrader(BucketName,
                              [{P, Ns} || {P, [N | _] = Ns} <- PartitionsToUpgrade, N =:= Node])
         || Node <- [undefined | BucketNodes]],

    case [W || W <- Workers, W =/= undefined] of
        [] ->
            self() ! upgrade_next_bucket,
            {noreply, State#state{workers = [],
                                  buckets = Rest}};
        CleanedWorkers ->
            {noreply, State#state{buckets = Rest,
                                  bucket = BucketName,
                                  bucket_config = BucketConfig,
                                  progress = Progress,
                                  workers = CleanedWorkers}}
    end;

handle_info({'EXIT', Pid, Reason}, #state{workers = Workers} = State) ->
    NewWorkers = lists:delete(Pid, Workers),
    NewState = State#state{workers = NewWorkers},
    case {Reason, NewWorkers} of
        {normal, []} ->
            self() ! upgrade_next_bucket,
            {noreply, NewState};
        {normal, _} ->
            {noreply, NewState};
        _ ->
            ?rebalance_error("~p exited with ~p", [Pid, Reason]),
            {stop, Reason, State}
    end;
handle_info(stop, State) ->
    {stop, shutdown, State};
handle_info(Info, State) ->
    ?rebalance_warning("Unhandled message ~p", [Info]),
    {noreply, State}.

terminate(Reason, #state{workers = Workers}) ->
    [(catch erlang:exit(P, Reason)) || P <- Workers],
    [misc:wait_for_process(P, infinity) || P <- Workers],
    ok.

apply_replication_status(Pid, Partition, Replicas) ->
    gen_server:call(Pid,
                    {apply_replication_status, Partition, Replicas},
                    infinity).

update_replication_status(Pid, Partition, Master, NumPartitions) ->
    gen_server:call(Pid,
                    {update_replication_status, Partition, Master, NumPartitions},
                    infinity).

maybe_spawn_upgrader(_Bucket, []) ->
    undefined;
maybe_spawn_upgrader(Bucket, PartitionsToUpgrade) ->
    Parent = self(),
    proc_lib:spawn_link(fun () ->
                                upgrade_partitions_for_one_node(Parent, Bucket, PartitionsToUpgrade)
                        end).

upgrade_partitions_for_one_node(Parent, Bucket, PartitionsToUpgrade) ->
    NumPartitionsToUpgrade = length(PartitionsToUpgrade),

    lists:foreach(fun ({Partition, [Master | Replicas]}) ->
                          RealReplicas =
                              [R || R <- Replicas, R =/= undefined],

                          upgrade_partition(Parent, Bucket, Partition, Master, RealReplicas,
                                            NumPartitionsToUpgrade)
                  end, PartitionsToUpgrade).

upgrade_partition(Parent, Bucket, Partition, Master, Replicas, NumPartitions) ->
    ?rebalance_info("Upgrade partition ~p of bucket ~p to UPR", [Partition, Bucket]),

    case {Master, Replicas} of
        {_, []} ->
            ok;
        {undefined, _} ->
            ok;
        _ ->
            ok = apply_replication_status(Parent, Partition, Replicas),
            ok = janitor_agent:wait_upr_data_move(Bucket, Parent, Master, Replicas, Partition)
    end,
    ok = update_replication_status(Parent, Partition, Master, NumPartitions).

apply_bucket_config(Bucket, BucketConfig, Servers) ->
    {ok, _, Zombies} = janitor_agent:query_states(Bucket, Servers, 1),
    case Zombies of
        [] ->
            janitor_agent:apply_new_bucket_config(
              Bucket, self(), Servers, [], BucketConfig, []);
        _ ->
            ?log_error("Failed to query states from some of the nodes: ~p", [Zombies]),
            {error, {failed_nodes, Zombies}}
    end.

upgrade_replication_type(Partition, Config) ->
    ReplicationType = proplists:get_value(repl_type, Config),
    TapPartitions =
        case ReplicationType of
            {upr, TapP} ->
                TapP;
            tap ->
                NumPartitions = proplists:get_value(num_vbuckets, Config),
                lists:seq(0, NumPartitions - 1)
        end,
    case ordsets:del_element(Partition, TapPartitions) of
        [] ->
            upr;
        NewTapPartitions ->
            {upr, NewTapPartitions}
    end.

get_buckets_to_upgrade() ->
    BucketConfigs = ns_bucket:get_buckets(),
    [{Name, BC} || {Name, BC} <- BucketConfigs, ns_bucket:needs_upgrade_to_upr(BC)].

consider_trivial_upgrade(Buckets) ->
    lists:foreach(fun ({BucketName, BucketConfig}) ->
                          consider_trivial_upgrade(BucketName, BucketConfig)
                  end, Buckets).

consider_trivial_upgrade(BucketName, BucketConfig) ->
    case ns_bucket:needs_upgrade_to_upr(BucketConfig) of
        false ->
            false;
        true ->
            NServers =
                case ns_bucket:bucket_nodes(BucketConfig) of
                    List when is_list(List) ->
                        length(List);
                    _ ->
                        0
                end,
            case NServers < 2 orelse
                ns_bucket:num_replicas(BucketConfig) < 1 orelse
                proplists:get_value(map, BucketConfig, []) =:= [] of
                true ->
                    upgrade_bucket_trivial(BucketName, BucketConfig),
                    true;
                false ->
                    false
            end
    end.

upgrade_bucket_trivial(Bucket, BucketConfig) ->
    ?log_info("Performing trivial UPR upgrade for bucket ~p", [{Bucket, BucketConfig}]),
    NewConfig = lists:keystore(repl_type, 1, BucketConfig,
                               {repl_type, upr}),
    ok = ns_bucket:set_bucket_config(Bucket, NewConfig),
    master_activity_events:note_bucket_upgraded_to_upr(Bucket).
