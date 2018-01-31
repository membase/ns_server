%% @author Couchbase <info@couchbase.com>
%% @copyright 2018 Couchbase, Inc.
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
-module(recovery_server).

-behavior(gen_server2).

-include("ns_common.hrl").

%% API
-export([start_recovery/2, commit_vbucket/4, stop_recovery/3]).
-export([recovery_status/1, recovery_map/3, is_recovery_running/0]).

%% gen_server2 callbacks
-export([handle_call/3]).

-define(RECOVERY_QUERY_STATES_TIMEOUT,
        ns_config:get_timeout(recovery_query_states, 5000)).

-record(state, {uuid           :: binary(),
                bucket         :: bucket_name(),
                recovery_state :: any()}).

-define(expect_exit(Pid, ExitPattern, Body),
        misc:with_trap_exit(
          fun () ->
                  __R = Body,
                  case __R of
                      ExitPattern ->
                          ?must_flush({'EXIT', Pid, normal});
                      _ ->
                          ok
                  end,
                  __R
          end)).

start_recovery(Bucket, FromPid) ->
    {ok, Pid} = start_link(Bucket),
    ?expect_exit(Pid, {error, _}, call(Pid, {start_recovery, Bucket, FromPid})).

commit_vbucket(Pid, Bucket, UUID, VBucket) ->
    ?expect_exit(Pid, recovery_completed,
                 call(Pid, {check, Bucket, UUID, {commit_vbucket, VBucket}})).

stop_recovery(Pid, Bucket, UUID) ->
    ?expect_exit(Pid, ok, call(Pid, {check, Bucket, UUID, stop_recovery})).

recovery_status(Pid) ->
    call(Pid, recovery_status).

recovery_map(Pid, Bucket, UUID) ->
    call(Pid, {check, Bucket, UUID, recovery_map}).

is_recovery_running() ->
    case ns_config:search(recovery_status) of
        {value, {running, _Bucket, _UUID}} ->
            true;
        _ ->
            false
    end.

%% gen_server2 callbacks
handle_call({start_recovery, Bucket, FromPid}, _From, undefined) ->
    handle_start_recovery(Bucket, FromPid);
handle_call(recovery_status, _From, #state{bucket = Bucket,
                                           uuid   = UUID} = State) ->
    Map = get_recovery_map(State),

    Status = [{bucket, Bucket},
              {uuid, UUID},
              {recovery_map, Map}],

    {reply, {ok, Status}, State};
handle_call({check, Bucket, UUID, Call}, _From,
            #state{uuid   = OurUUID,
                   bucket = OurBucket} = State) ->
    case {Bucket, UUID} =:= {OurBucket, OurUUID} of
        true ->
            handle_checked_call(Call, State);
        false ->
            {reply, bad_recovery, State}
    end.

%% internal
server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

start_link(Bucket) ->
    gen_server2:start_link({local, server(Bucket)}, ?MODULE, [], []).

call(Pid, Call) ->
    gen_server2:call(Pid, Call, infinity).

handle_checked_call({commit_vbucket, VBucket}, State) ->
    handle_commit_vbucket(VBucket, State);
handle_checked_call(stop_recovery, #state{bucket = Bucket} = State) ->
    ns_config:set(recovery_status, not_running),
    ale:info(?USER_LOGGER, "Recovery of bucket `~s` aborted", [Bucket]),
    {stop, normal, ok, State};
handle_checked_call(recovery_map, State) ->
    {reply, {ok, get_recovery_map(State)}, State}.

handle_commit_vbucket(VBucket,
                      #state{bucket         = Bucket,
                             recovery_state = RecoveryState} = State) ->
    case recovery:commit_vbucket(VBucket, RecoveryState) of
        {ok, {Servers, NewBucketConfig}, NewRecoveryState} ->
            RV = apply_recovery_bucket_config(Bucket, NewBucketConfig, Servers),
            case RV of
                ok ->
                    handle_commit_vbucket_post_apply(Bucket, VBucket,
                                                     NewRecoveryState, State);
                Error ->
                    NewState = State#state{recovery_state = NewRecoveryState},
                    {reply, Error, NewState}
            end;
        Error ->
             {reply, Error, State}
    end.

handle_commit_vbucket_post_apply(Bucket, VBucket, RecoveryState, State) ->
    {ok, Map, NewRecoveryState} =
        recovery:note_commit_vbucket_done(VBucket, RecoveryState),
    ns_bucket:set_map(Bucket, Map),

    NewState = State#state{recovery_state = NewRecoveryState},
    case recovery:is_recovery_complete(NewRecoveryState) of
        true ->
            ale:info(?USER_LOGGER,
                     "Recovery of bucket `~s` completed", [Bucket]),
            {stop, normal, recovery_completed, NewState};
        false ->
            ?log_debug("Committed "
                       "vbucket ~b (recovery of `~s`)", [VBucket, Bucket]),
            {reply, ok, NewState}
    end.

handle_start_recovery(Bucket, FromPid) ->
    try
        check_bucket(Bucket),
        Servers = get_recovery_servers(),

        leader_activities:register_process({recovery, Bucket}, {all, Servers}),

        ns_cluster_membership:activate(Servers),

        sync_config(Servers, FromPid),
        cleanup_old_buckets(Servers),
        BucketConfig = prepare_bucket(Bucket, Servers),
        complete_start_recovery(Bucket, BucketConfig, Servers)
    catch
        throw:Error ->
            {stop, normal, Error, undefined}
    end.

get_recovery_servers() ->
    FailedOverNodes = get_failed_over_nodes(),
    LiveNodes = ns_node_disco:nodes_wanted() -- FailedOverNodes,
    ns_cluster_membership:service_nodes(LiveNodes, kv).

check_bucket(Bucket) ->
    case ns_bucket:get_bucket(Bucket) of
        {ok, BucketConfig} ->
            case ns_bucket:bucket_type(BucketConfig) of
                membase ->
                    ok;
                _ ->
                    throw(not_needed)
            end;
        not_present ->
            throw(not_present)
    end.

get_failed_over_nodes() ->
    ns_cluster_membership:get_nodes_with_status(inactiveFailed).

sync_config(Servers, FromPid) ->
    FromPidNode = erlang:node(FromPid),
    SyncServers = lists:usort([FromPidNode | Servers]),

    case ns_config_rep:ensure_config_seen_by_nodes(SyncServers) of
        ok ->
            ok;
        {error, BadNodes} ->
            ?log_error("Failed to "
                       "synchronize config to some nodes: ~p", [BadNodes]),
            throw({error, {failed_nodes, BadNodes}})
    end.

cleanup_old_buckets(Servers) ->
    case ns_rebalancer:maybe_cleanup_old_buckets(Servers) of
        ok ->
            ok;
        {buckets_cleanup_failed, FailedNodes} ->
            throw({error, {failed_nodes, FailedNodes}})
    end.

prepare_bucket(Bucket, Servers) ->
    ns_bucket:set_servers(Bucket, Servers),
    case ns_janitor:cleanup(Bucket, [{query_states_timeout, 10000}]) of
        ok ->
            {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
            BucketConfig;
        {error, _, FailedNodes} ->
            throw({error, {failed_nodes, FailedNodes}})
    end.

init_recovery_state(Servers, BucketConfig) ->
    case recovery:start_recovery(BucketConfig) of
        {ok, Map, {NewServers, NewBucketConfig}, RecoveryState} ->
            true = (NewServers =:= Servers),
            {Map, NewBucketConfig, RecoveryState};
        Error ->
            throw(Error)
    end.

complete_start_recovery(Bucket, BucketConfig, Servers) ->
    {Map, NewBucketConfig, RecoveryState} =
        init_recovery_state(Servers, BucketConfig),
    RV = apply_recovery_bucket_config(Bucket, NewBucketConfig, Servers),

    case RV of
        ok ->
            UUID = couch_uuids:random(),

            ensure_recovery_status(Bucket, UUID),
            ale:info(?USER_LOGGER,
                     "Put bucket `~s` into recovery mode", [Bucket]),

            State = #state{bucket         = Bucket,
                           uuid           = UUID,
                           recovery_state = RecoveryState},

            {reply, {ok, self(), UUID, Map}, State};
        Error ->
            throw(Error)
    end.

apply_recovery_bucket_config(Bucket, BucketConfig, Servers) ->
    {ok, _, Zombies} =
        janitor_agent:query_states(Bucket,
                                   Servers, ?RECOVERY_QUERY_STATES_TIMEOUT),
    case Zombies of
        [] ->
            janitor_agent:apply_new_bucket_config_with_timeout(
              Bucket, undefined, Servers,
              BucketConfig, [], undefined_timeout);
        _ ->
            ?log_error("Failed to query states "
                       "from some of the nodes: ~p", [Zombies]),
            {error, {failed_nodes, Zombies}}
    end.

ensure_recovery_status(Bucket, UUID) ->
    ns_config:set(recovery_status, {running, Bucket, UUID}).

get_recovery_map(#state{recovery_state = State}) ->
    recovery:get_recovery_map(State).
