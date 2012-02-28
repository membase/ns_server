%% @author Couchbase <info@couchbase.com>
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

-module(capi_set_view_manager).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-define(SYNC_INTERVAL, 5000).
-define(EMPTY_MAP, [{active, []}, {passive, []}, {replica, []}, {ignore, []}]).

%% API
-export([start_link/1, wait_until_added/3, fetch_ddocs/1]).

-include("couch_db.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").
-include("ns_common.hrl").

-record(state, {bucket,
                bucket_config,
                vbucket_states,
                master_db_watcher,
                map,
                ddocs,
                pending_vbucket_states,
                waiters,
                use_replica_index}).

-define(csv_call(Call, Args),
        %% hack to not introduce any variables in the caller environment
        ((fun () ->
                  %% we may want to downgrade it to ?views_debug at some point
                  ?views_info("~nCalling couch_set_view:~p(~p)", [Call, Args]),
                  try
                      {__Time, __Result} = timer:tc(couch_set_view, Call, Args),

                      ?views_info("~ncouch_set_view:~p(~p) returned ~p in ~bms",
                                  [Call, Args, __Result, __Time div 1000]),
                      __Result
                  catch
                      __T:__E ->
                          ?views_info("~ncouch_set_view:~p(~p) raised ~p:~p",
                                      [Call, Args, __T, __E]),

                          %% rethrowing the exception
                          __Stack = erlang:get_stacktrace(),
                          erlang:raise(__T, __E, __Stack)
                  end
          end)())).

start_link(Bucket) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(BucketConfig) of
        memcached ->
            ignore;
        _ ->
            UseReplicaIndex = (proplists:get_value(replica_index, BucketConfig) =/= false),

            gen_server:start_link({local, server(Bucket)}, ?MODULE,
                                  {Bucket, UseReplicaIndex}, [])
    end.

wait_until_added(Node, Bucket, VBucket) ->
    Address = {server(Bucket), Node},
    gen_server:call(Address, {wait_until_added, VBucket}, infinity).

init({Bucket, UseReplicaIndex}) ->
    process_flag(trap_exit, true),

    InterestingNsConfigEvent =
        fun (Event) ->
                interesting_ns_config_event(Bucket, Event)
        end,

    ns_pubsub:subscribe_link(ns_config_events,
                             mk_filter(InterestingNsConfigEvent), ignored),
    ns_pubsub:subscribe_link(mc_couch_events,
                             mk_mc_couch_event_handler(), ignored),

    Self = self(),
    {ok, Watcher} =
        proc_lib:start_link(erlang, apply,
                             [fun master_db_watcher/2, [Bucket, Self]]),

    {ok, _Timer} = timer:send_interval(?SYNC_INTERVAL, sync),

    State = #state{bucket=Bucket,
                   master_db_watcher=Watcher,
                   ddocs=undefined,
                   waiters=dict:new(),
                   use_replica_index=UseReplicaIndex},

    {ok, apply_current_map(State)}.

handle_call({wait_until_added, VBucket}, From,
            #state{waiters=Waiters} = State) ->
    case added(VBucket, State) of
        true ->
            {reply, ok, State};
        false ->
            Waiters1 = dict:append(VBucket, From, Waiters),
            State1 = State#state{waiters=Waiters1},
            {noreply, State1}
    end;

handle_call(sync, _From, State) ->
    {reply, ok, sync(State)};

handle_call({pre_flush_all, Bucket}, _From,
            #state{bucket=Bucket,
                   ddocs=DDocs,
                   map=Map,
                   use_replica_index=UseReplicaIndex,
                   pending_vbucket_states=States} = State) ->
    NewStates = dict:map(
                  fun (_, _) ->
                          dead
                  end, States),
    NewMap = ?EMPTY_MAP,
    apply_map(Bucket, DDocs, Map, NewMap, UseReplicaIndex),
    {reply, ok, State#state{vbucket_states=NewStates,
                            pending_vbucket_states=NewStates,
                            map=NewMap}};

handle_call(fetch_ddocs, _From, #state{ddocs=DDocs} = State) ->
    {reply, {ok, DDocs}, State}.

handle_cast({update_ddoc, DDocId, Deleted},
            #state{bucket=Bucket,
                   bucket_config=BucketConfig,
                   use_replica_index=UseReplicaIndex,
                   ddocs=DDocs, map=Map} = State) ->
    State1 =
        case Deleted of
            false ->
                %% we need to redefine set view whenever document changes; but
                %% previous group for current value of design document can
                %% still be alive; thus using maybe_define_group
                maybe_define_group(Bucket, BucketConfig,
                                   DDocId, Map, UseReplicaIndex),
                DDocs1 = sets:add_element(DDocId, DDocs),
                State#state{ddocs=DDocs1};
            true ->
                DDocs1 = sets:del_element(DDocId, DDocs),
                State#state{ddocs=DDocs1}
        end,

    {noreply, State1};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({buckets, Buckets},
            #state{bucket=Bucket} = State) ->
    ?views_debug("Got `buckets` event"),

    BucketConfigs = proplists:get_value(configs, Buckets),
    BucketConfig = proplists:get_value(Bucket, BucketConfigs),

    NewState = State#state{bucket_config=BucketConfig},
    {noreply, sync(NewState)};

handle_info({set_vbucket, Bucket, VBucket, VBucketState, _CheckpointId},
            #state{bucket=Bucket,
                   pending_vbucket_states=PendingStates} = State) ->
    ?views_debug("Got set_vbucket event for ~s/~b. Updated state: ~p",
                 [Bucket, VBucket, VBucketState]),

    NewPendingStates = dict:store(VBucket, VBucketState, PendingStates),
    NewState = State#state{pending_vbucket_states=NewPendingStates},

    {noreply, NewState};

handle_info({post_flush_all, Bucket}, #state{bucket=Bucket} = State) ->
    {noreply, apply_current_map(State)};

handle_info(sync, State) ->
    {noreply, sync(State)};

handle_info({'EXIT', Pid, Reason}, #state{master_db_watcher=Pid} = State) ->
    ?views_error("Master db watcher died unexpectedly: ~p", [Reason]),
    {stop, {master_db_watcher_died, Reason}, State};

handle_info({'EXIT', Pid, Reason}, State) ->
    ?views_error("Linked process ~p died unexpectedly: ~p", [Pid, Reason]),
    {stop, {linked_process_died, Pid, Reason}, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

master_db(Bucket) ->
    list_to_binary(Bucket ++ "/master").

matching_indexes(Pred, List) ->
    IndexedList = misc:enumerate(List, 0),
    lists:foldr(
      fun ({Ix, Elem}, Acc) ->
              case Pred(Ix, Elem) of
                  true ->
                      [Ix | Acc];
                  false ->
                      Acc
              end
      end, [], IndexedList).

generic_matching_vbuckets(VBucketPred, Pred, Map, States) ->
    matching_indexes(
      fun (Ix, Chain) ->
              case VBucketPred(Chain) of
                  true ->
                      VBucketState = dict:fetch(Ix, States),
                      Pred(VBucketState);
                  false ->
                      false
              end
      end, Map).

is_master(Chain) ->
    is_master(node(), Chain).

is_master(Node, [Master | _]) ->
    Node =:= Master.

is_replica(Chain) ->
    is_replica(node(), Chain).

is_replica(Node, [_Master | Replicas]) ->
    lists:member(Node, Replicas).

matching_master_vbuckets(Pred, Map, States) ->
    generic_matching_vbuckets(fun is_master/1, Pred, Map, States).

matching_replica_vbuckets(Pred, Map, States) ->
    generic_matching_vbuckets(fun is_replica/1, Pred, Map, States).

matching_vbuckets(Pred, Map, States) ->
    generic_matching_vbuckets(
      fun (Chain) ->
              is_master(Chain) orelse is_replica(Chain)
      end, Pred, Map, States).

build_map(BucketConfig, VBucketStates, UseReplicaIndex) ->
    Map = proplists:get_value(map, BucketConfig),
    FFMap = case proplists:get_value(fastForwardMap, BucketConfig) of
                undefined ->
                    [];
                FFMap1 ->
                    FFMap1
            end,

    case Map of
        undefined ->
            ?EMPTY_MAP;
        _ ->
            Active = matching_master_vbuckets(
                       fun (State) ->
                               State =:= active
                       end, Map, VBucketStates),

            Ignore = matching_vbuckets(
                       fun (State) ->
                               State =:= dead
                       end, Map, VBucketStates),

            %% vbuckets that are going to be masters after rebalance
            Passive1 = matching_master_vbuckets(
                         fun (State) ->
                                 State =:= active orelse
                                     State =:= replica orelse
                                     State =:= pending
                         end, FFMap, VBucketStates),

            %% during failover there is a time lapse when some replica
            %% vbuckets has already been promoted to masters but they are
            %% still in state 'replica'; so we should add these vbuckets to a
            %% passive set to not lose their indexes
            Passive2 = matching_master_vbuckets(
                         fun (State) ->
                                 State =:= replica
                         end, Map, VBucketStates),

            Passive = ordsets:subtract(ordsets:union(Passive1, Passive2),
                                       Active),

            case UseReplicaIndex of
                true ->
                    Replica1 = matching_replica_vbuckets(
                                 fun (State) ->
                                         State =:= replica
                                 end, Map, VBucketStates),

                    %% vbucket is replica according to fastforward map but
                    %% vbucket map has not yet changed for some reason
                    Replica2 = matching_replica_vbuckets(
                                 fun (State) ->
                                         State =:= replica
                                 end, FFMap, VBucketStates),

                    Replica =
                        ordsets:subtract(ordsets:union([Replica1, Replica2]),
                                         Passive);
                false ->
                    Replica = []
            end,

            [{active, Active},
             {passive, Passive},
             {ignore, Ignore},
             {replica, Replica}]
    end.

classify_vbuckets(undefined, NewMap) ->
    classify_vbuckets(?EMPTY_MAP, NewMap);
classify_vbuckets(OldMap, NewMap) ->
    Active = proplists:get_value(active, NewMap),
    Passive = proplists:get_value(passive, NewMap),
    Ignore = proplists:get_value(ignore, NewMap),
    Replica = proplists:get_value(replica, NewMap),

    OldActive = proplists:get_value(active, OldMap),
    OldPassive = proplists:get_value(passive, OldMap),
    OldIgnore = proplists:get_value(ignore, OldMap),
    OldReplica = proplists:get_value(replica, OldMap),

    OldNonReplica = ordsets:union([OldActive, OldPassive, OldIgnore]),
    NonReplica = ordsets:union([Active, Passive, Ignore]),

    Cleanup1 = ordsets:subtract(OldNonReplica, NonReplica),

    %% also cleanup replica vbuckets that were (potentially) active or passive
    Cleanup = ordsets:union(Cleanup1,
                            ordsets:intersection(OldNonReplica, Replica)),

    All = ordsets:union(NonReplica, Replica),
    ReplicaCleanup = ordsets:subtract(OldReplica, All),

    {Active, Passive, Cleanup, Replica, ReplicaCleanup}.

define_group(Bucket, BucketConfig, DDocId, Map, UseReplicaIndex) ->
    SetName = list_to_binary(Bucket),
    NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),

    Params = #set_view_params{max_partitions=NumVBuckets,
                              active_partitions=[],
                              passive_partitions=[],
                              use_replica_index=UseReplicaIndex},

    try
        ok = ?csv_call(define_group, [SetName, DDocId, Params])
    catch
        throw:{not_found, deleted} ->
            %% The document has been deleted but we still think it's
            %% alive. Eventually we will get a notification from master db
            %% watcher and delete it from a list of design documents.
            ok
    end,

    apply_ddoc_map(Bucket, DDocId, undefined, Map, UseReplicaIndex).

maybe_define_group(Bucket, BucketConfig, DDocId, Map, UseReplicaIndex) ->
    try
        define_group(Bucket, BucketConfig, DDocId, Map, UseReplicaIndex)
    catch
        throw:view_already_defined ->
            ok
    end.

apply_ddoc_map(Bucket, DDocId, OldMap, NewMap, UseReplicaIndex) ->
    ?views_info("Applying map to bucket ~s (ddoc ~s):~n~p",
                [Bucket, DDocId, NewMap]),

    {Active, Passive, Cleanup, Replica, ReplicaCleanup} =
        classify_vbuckets(OldMap, NewMap),

    ?views_info("Classified vbuckets for ~p (ddoc ~s):~n"
                "Active: ~p~n"
                "Passive: ~p~n"
                "Cleanup: ~p~n"
                "Replica: ~p~n"
                "ReplicaCleanup: ~p",
                [Bucket, DDocId,
                 Active, Passive, Cleanup, Replica, ReplicaCleanup]),

    apply_ddoc_map(Bucket, DDocId, Active, Passive,
                   Cleanup, Replica, ReplicaCleanup, UseReplicaIndex).

apply_ddoc_map(Bucket, DDocId, Active, Passive, Cleanup,
               Replica, ReplicaCleanup, UseReplicaIndex) ->
    SetName = list_to_binary(Bucket),

    try
        %% this should go first because some of the replica vbuckets might
        %% need to be cleaned up from main index
        ok = ?csv_call(set_partition_states,
                       [SetName, DDocId, Active, Passive, Cleanup]),

        case UseReplicaIndex of
            true ->
                ok = ?csv_call(add_replica_partitions,
                               [SetName, DDocId, Replica]),
                ok = ?csv_call(remove_replica_partitions,
                               [SetName, DDocId, ReplicaCleanup]);
            false ->
                ok
        end

    catch
        throw:{not_found, deleted} ->
            %% The document has been deleted but we still think it's
            %% alive. Eventually we will get a notification from master db
            %% watcher and delete it from a list of design documents.
            ok;
        throw:view_undefined ->
            %% Design document has been updated but we have not reacted on it
            %% yet. As previously eventually we will get a notification about
            %% this change and define a group again.
            ok
    end.

apply_map(Bucket, DDocs, OldMap, NewMap, UseReplicaIndex) ->
    ?views_info("Applying map to bucket ~s:~n~p", [Bucket, NewMap]),

    {Active, Passive, Cleanup, Replica, ReplicaCleanup} =
        classify_vbuckets(OldMap, NewMap),

    ?views_info("Classified vbuckets for ~s:~n"
                "Active: ~p~n"
                "Passive: ~p~n"
                "Cleanup: ~p~n"
                "Replica: ~p~n"
                "ReplicaCleanup: ~p",
                [Bucket, Active, Passive, Cleanup, Replica, ReplicaCleanup]),

    sets:fold(
      fun (DDocId, _) ->
              apply_ddoc_map(Bucket, DDocId, Active, Passive,
                             Cleanup, Replica, ReplicaCleanup, UseReplicaIndex)
      end, undefined, DDocs).

do_get_vbucket_state(Bucket, VBucket) ->
    try
        {JsonState} = ?JSON_DECODE(mc_couch_vbucket:get_state(VBucket, Bucket)),
        State = proplists:get_value(<<"state">>, JsonState),
        erlang:binary_to_atom(State, latin1)
    catch
        throw:{open_db_error, _, _, {not_found, no_db_file}} ->
            dead
    end.

get_vbucket_states(Bucket, BucketConfig) ->
    BucketBinary = list_to_binary(Bucket),
    NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),

    lists:foldl(
      fun (VBucket, States) ->
              State = do_get_vbucket_state(BucketBinary, VBucket),
              dict:store(VBucket, State, States)
      end,
      dict:new(), lists:seq(0, NumVBuckets - 1)).

master_db_watcher(Bucket, Parent) ->
    MasterDbName = master_db(Bucket),
    {ok, MasterDb} = couch_db:open_int(MasterDbName, []),
    Seq = couch_db:get_update_seq(MasterDb),
    ChangesFeedFun = couch_changes:handle_changes(
                       #changes_args{
                          include_docs = false,
                          feed = "continuous",
                          timeout = infinity,
                          db_open_options = [],

                          %% we're interested only in new changes; in case
                          %% there are design documents for which there has
                          %% been no groups defined those will be handled by
                          %% initial call to `apply_map`.
                          since = Seq
                         },
                       {json_req, null},
                       MasterDb
                      ),

    %% we've read a update seq from db; thus even though actual loop is not
    %% started we can safely pretend that it really is; even if any design doc
    %% is created in between it will be included in a changes that are
    %% reported to the main process.
    proc_lib:init_ack({ok, self()}),

    ChangesFeedFun(
      fun({change, {Change}, _}, _) ->
              Deleted = proplists:get_value(<<"deleted">>, Change, false),

              case proplists:get_value(<<"id">>, Change) of
                  <<"_design/", _/binary>> = DDocId ->
                      ?views_debug("Got change in `~s` design document. "
                                   "Initiating set view update", [DDocId]),
                      gen_server:cast(Parent, {update_ddoc, DDocId, Deleted});
                  _ ->
                      ok
              end;
         (_, _) ->
              ok
      end).

apply_current_map(#state{bucket=Bucket,
                         use_replica_index=UseReplicaIndex,
                         waiters=Waiters} = State) ->
    DDocs = get_design_docs(Bucket),

    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    VBucketStates = get_vbucket_states(Bucket, BucketConfig),
    Map = build_map(BucketConfig, VBucketStates, UseReplicaIndex),

    sets:fold(
      fun (DDocId, _) ->
              maybe_define_group(Bucket, BucketConfig,
                                 DDocId, Map, UseReplicaIndex)
      end, undefined, DDocs),

    apply_map(Bucket, DDocs, undefined, Map, UseReplicaIndex),
    Waiters1 = notify_waiters(Waiters, Map),

    State#state{bucket_config=BucketConfig,
                vbucket_states=VBucketStates,
                pending_vbucket_states=VBucketStates,
                map=Map,
                ddocs=DDocs,
                waiters=Waiters1}.

interesting_ns_config_event(Bucket, {buckets, Buckets}) ->
    BucketConfigs = proplists:get_value(configs, Buckets, []),
    proplists:is_defined(Bucket, BucketConfigs);
interesting_ns_config_event(_Bucket, _) ->
    false.

mk_mc_couch_event_handler() ->
    Self = self(),

    fun (Event, _) ->
            handle_mc_couch_event(Self, Event)
    end.

handle_mc_couch_event(Self,
                      {set_vbucket, Bucket, VBucket, State, Checkpoint}) ->
    Self ! {set_vbucket, Bucket, VBucket, State, Checkpoint};
handle_mc_couch_event(Self,
                      {delete_vbucket, Bucket, VBucket}) ->
    Self ! {set_vbucket, Bucket, VBucket, "dead", 0},
    ok = gen_server:call(Self, sync, infinity);
handle_mc_couch_event(Self, {pre_flush_all, _} = Event) ->
    ok = gen_server:call(Self, Event, infinity);
handle_mc_couch_event(Self, {post_flush_all, _} = Event) ->
    Self ! Event;
handle_mc_couch_event(_, _) ->
    ok.

mk_filter(Pred) ->
    Self = self(),

    fun (Event, _) ->
            case Pred(Event) of
                true ->
                    Self ! Event;
                false ->
                    ok
            end
    end.

sync(#state{bucket=Bucket,
            bucket_config=BucketConfig,
            pending_vbucket_states=PendingStates,
            ddocs=DDocs,
            map=Map,
            use_replica_index=UseReplicaIndex,
            waiters=Waiters} = State) ->
    NewMap = build_map(BucketConfig, PendingStates, UseReplicaIndex),
    case NewMap =/= Map of
        true ->
            apply_map(Bucket, DDocs, Map, NewMap, UseReplicaIndex),
            Waiters1 = notify_waiters(Waiters, NewMap),
            State#state{vbucket_states=PendingStates,
                        map=NewMap, waiters=Waiters1};
        false ->
            State#state{vbucket_states=PendingStates}
    end.

get_design_docs(Bucket) ->
    DDocDbName = master_db(Bucket),

    {ok, DDocDb} = couch_db:open(DDocDbName,
                                 [{user_ctx, #user_ctx{roles=[<<"_admin">>]}}]),
    {ok, DDocs} =
        try
            couch_db:get_design_docs(DDocDb)
        after
            couch_db:close(DDocDb)
        end,

    DDocIds = lists:map(fun (#doc{id=DDocId}) ->
                                DDocId
                        end, DDocs),
    sets:from_list(DDocIds).

fetch_ddocs(Bucket) ->
    gen_server:call(server(Bucket), fetch_ddocs).

added(VBucket, #state{map=Map}) ->
    Active = proplists:get_value(active, Map),
    Passive = proplists:get_value(passive, Map),

    lists:member(VBucket, Active)
        orelse lists:member(VBucket, Passive).

notify_waiters(Waiters, Map) ->
    Active = proplists:get_value(active, Map),
    Passive = proplists:get_value(passive, Map),

    Waiters1 = do_notify_waiters(Waiters, Active),
    do_notify_waiters(Waiters1, Passive).

do_notify_waiters(Waiters, Partitions) ->
    lists:foldl(
      fun (P, AccWaiters) ->
              case dict:find(P, AccWaiters) of
                  {ok, Froms} ->
                      [gen_server:reply(From, ok) || From <- Froms],
                      dict:erase(P, AccWaiters);
                  error ->
                      AccWaiters
              end
      end, Waiters, Partitions).
