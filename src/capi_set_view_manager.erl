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

-export([start_link/1]).

%% API
-export([set_vbucket_states/3]).

-include("couch_db.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").
-include("ns_common.hrl").

-record(state, {bucket :: bucket_name(),
                num_vbuckets :: non_neg_integer(),
                use_replica_index :: boolean(),
                master_db_watcher :: pid(),
                wanted_states :: [missing | active | replica],
                rebalance_states :: [rebalance_vbucket_state()],
                usable_vbuckets}).

set_vbucket_states(Bucket, WantedStates, RebalanceStates) ->
    gen_server:call(server(Bucket), {set_vbucket_states, WantedStates, RebalanceStates}, infinity).

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


compute_index_states(WantedStates, RebalanceStates, ExistingVBuckets) ->
    AllVBs = lists:seq(0, erlang:length(WantedStates)-1),
    Triples = lists:zip3(AllVBs,
                         WantedStates,
                         RebalanceStates),
    WantedPairs = lists:flatmap(
                    fun ({VBucket, WantedState, TmpState}) ->
                            case sets:is_element(VBucket, ExistingVBuckets) of
                                true ->
                                    case {WantedState, TmpState} of
                                        %% {replica, passive} ->
                                        %%     [{VBucket, replica}, {VBucket, passive}];
                                        {_, passive} ->
                                            [{VBucket, passive}];
                                        {active, _} ->
                                            [{VBucket, active}];
                                        {replica, _} ->
                                            [{VBucket, replica}];
                                        _ ->
                                            []
                                    end;
                                false ->
                                    []
                            end
                    end,
                    Triples),
    Active = [VB || {VB, active} <- WantedPairs],
    Passive = [VB || {VB, passive} <- WantedPairs],
    Replica = [VB || {VB, replica} <- WantedPairs],
    AllMain = Active ++ Passive,
    MainCleanup = AllVBs -- AllMain,
    ReplicaCleanup = ((AllVBs -- Replica) -- Active),
    PauseVBuckets = [VBucket
                     || {VBucket, WantedState, TmpState} <- Triples,
                        TmpState =:= paused,
                        sets:is_element(VBucket, ExistingVBuckets),
                        begin
                            active = WantedState,
                            true
                        end],
    UnpauseVBuckets = AllVBs -- PauseVBuckets,
    {Active, Passive, MainCleanup, Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets}.

get_usable_vbuckets_set(Bucket) ->
    PrefixLen = erlang:length(Bucket) + 1,
    sets:from_list(
      [list_to_integer(binary_to_list(VBucketName))
       || FullName <- ns_storage_conf:bucket_databases(Bucket),
          VBucketName <- [binary:part(FullName, PrefixLen, erlang:size(FullName) - PrefixLen)],
          VBucketName =/= <<"master">>]).

do_apply_vbucket_states(SetName, Active, Passive, MainCleanup, Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets, State) ->
    RVs = capi_ddoc_replication_srv:foreach_live_ddoc_id(
            SetName,
            fun (DDocId) ->
                    apply_index_states(SetName, DDocId,
                                       Active, Passive, MainCleanup, Replica, ReplicaCleanup,
                                       PauseVBuckets, UnpauseVBuckets,
                                       State),
                    ok
            end),
    BadDDocs = [Pair || {_Id, Val} = Pair <- RVs,
                        Val =/= ok],
    case BadDDocs of
        [] ->
            ok;
        _ ->
            ?log_error("Failed to apply index states for the following ddocs:~n~p", [BadDDocs])
    end,
    ok.

change_vbucket_states(#state{bucket = Bucket,
                             wanted_states = WantedStates,
                             rebalance_states = RebalanceStates,
                             usable_vbuckets = UsableVBuckets} = State) ->
    SetName = list_to_binary(Bucket),
    {Active, Passive, MainCleanup, Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets} =
        compute_index_states(WantedStates, RebalanceStates, UsableVBuckets),
    do_apply_vbucket_states(SetName, Active, Passive, MainCleanup, Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets, State).

start_link(Bucket) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(BucketConfig) of
        memcached ->
            ignore;
        _ ->
            UseReplicaIndex = (proplists:get_value(replica_index, BucketConfig) =/= false),
            VBucketsCount = proplists:get_value(num_vbuckets, BucketConfig),

            gen_server:start_link({local, server(Bucket)}, ?MODULE,
                                  {Bucket, UseReplicaIndex, VBucketsCount}, [])
    end.

init({Bucket, UseReplicaIndex, NumVBuckets}) ->
    process_flag(trap_exit, true),

    ns_pubsub:subscribe_link(mc_couch_events,
                             mk_mc_couch_event_handler(), ignored),

    Self = self(),
    {ok, Watcher} =
        proc_lib:start_link(erlang, apply,
                             [fun master_db_watcher/2, [Bucket, Self]]),

    State = #state{bucket=Bucket,
                   num_vbuckets = NumVBuckets,
                   use_replica_index=UseReplicaIndex,
                   master_db_watcher=Watcher,
                   wanted_states = [],
                   rebalance_states = [],
                   usable_vbuckets = get_usable_vbuckets_set(Bucket)},

    ?log_debug("Usable vbuckets:~n~p", [sets:to_list(State#state.usable_vbuckets)]),

    {ok, State}.

handle_call({set_vbucket_states, WantedStates, RebalanceStates}, _From,
            State) ->
    State2 = State#state{wanted_states = WantedStates,
                         rebalance_states = RebalanceStates},
    case State2 =:= State of
        true ->
            {reply, ok, State};
        false ->
            change_vbucket_states(State2),
            {reply, ok, State2}
    end;

handle_call({delete_vbucket, VBucket}, _From, #state{bucket = Bucket,
                                                     wanted_states = [],
                                                     rebalance_states = RebalanceStates} = State) ->
    [] = RebalanceStates,
    ?log_info("Deleting vbucket ~p from all indexes", [VBucket]),
    SetName = list_to_binary(Bucket),
    do_apply_vbucket_states(SetName, [], [], [VBucket], [], [VBucket], [], [], State),
    {reply, ok, State};
handle_call({delete_vbucket, VBucket}, _From, #state{usable_vbuckets = UsableVBuckets,
                                                     wanted_states = WantedStates,
                                                     rebalance_states = RebalanceStates} = State) ->
    NewUsableVBuckets = sets:del_element(VBucket, UsableVBuckets),
    case (NewUsableVBuckets =/= UsableVBuckets
          andalso (lists:nth(VBucket+1, WantedStates) =/= missing
                   orelse lists:nth(VBucket+1, RebalanceStates) =/= undefined)) of
        true ->
            NewState = State#state{usable_vbuckets = NewUsableVBuckets},
            change_vbucket_states(NewState),
            {reply, ok, NewState};
        false ->
            {reply, ok, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

aggregate_update_ddoc_messages(DDocId, Deleted) ->
    receive
        {update_ddoc, DDocId, NewDeleted} ->
            aggregate_update_ddoc_messages(DDocId, NewDeleted)
    after 0 ->
            Deleted
    end.

handle_info({update_ddoc, DDocId, Deleted0}, State) ->
    Deleted = aggregate_update_ddoc_messages(DDocId, Deleted0),
    ?log_info("Processing update_ddoc ~s (~p)", [DDocId, Deleted]),
    case Deleted of
        false ->
            %% we need to redefine set view whenever document changes; but
            %% previous group for current value of design document can
            %% still be alive; thus using maybe_define_group
            maybe_define_group(DDocId, State),
            change_vbucket_states(State),
            State;
        true ->
            ok
    end,
    {noreply, State};

handle_info(refresh_usable_vbuckets,
            #state{bucket=Bucket,
                   usable_vbuckets = OldUsableVBuckets} = State) ->
    misc:flush(refresh_usable_vbuckets),
    NewUsableVBuckets = get_usable_vbuckets_set(Bucket),
    case NewUsableVBuckets =:= OldUsableVBuckets of
        true ->
            {noreply, State};
        false ->
            State2 = State#state{usable_vbuckets = NewUsableVBuckets},
            ?log_debug("Usable vbuckets:~n~p", [sets:to_list(State2#state.usable_vbuckets)]),
            change_vbucket_states(State2),
            {noreply, State2}
    end;

handle_info({'EXIT', Pid, Reason}, #state{master_db_watcher=Pid} = State) ->
    ?views_error("Master db watcher died unexpectedly: ~p", [Reason]),
    {stop, {master_db_watcher_died, Reason}, State};

handle_info({'EXIT', Pid, Reason}, State) ->
    ?views_error("Linked process ~p died unexpectedly: ~p", [Pid, Reason]),
    {stop, {linked_process_died, Pid, Reason}, State};

handle_info(Info, State) ->
    ?log_info("Ignoring unexpected message: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

master_db(Bucket) ->
    list_to_binary(Bucket ++ "/master").

maybe_define_group(DDocId,
                   #state{bucket = Bucket,
                          num_vbuckets = NumVBuckets,
                          use_replica_index = UseReplicaIndex} = _State) ->
    SetName = list_to_binary(Bucket),
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
            ok;
        throw:view_already_defined ->
            already_defined
    end.

define_and_reapply_index_states(SetName, DDocId, Active, Passive, Cleanup,
                                Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets,
                                State, OriginalException, NowException) ->
    ?log_info("Got view_undefined exception:~n~p", [NowException]),
    case OriginalException of
        undefined ->
            ok;
        _ ->
            ?log_error("Got second exception after trying to redefine undefined view:~n~p~nOriginal exception was:~n~p",
                       [NowException, OriginalException]),
            erlang:apply(erlang, raise, OriginalException)
    end,
    maybe_define_group(DDocId, State),
    apply_index_states(SetName, DDocId, Active, Passive, Cleanup,
                       Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets,
                       State, NowException).

apply_index_states(SetName, DDocId, Active, Passive, Cleanup,
                   Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets,
                   State) ->
    apply_index_states(SetName, DDocId, Active, Passive, Cleanup,
                       Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets,
                       State, undefined).

apply_index_states(SetName, DDocId, Active, Passive, Cleanup,
                   Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets,
                   #state{use_replica_index = UseReplicaIndex} = State,
                   PastException) ->

    try
        PausingOn = cluster_compat_mode:is_index_pausing_on(),
        case PausingOn of
            false ->
                ok;
            true ->
                ok = ?csv_call(mark_partitions_indexable,
                               [SetName, DDocId, UnpauseVBuckets])
        end,

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
        end,

        case PausingOn of
            false ->
                ok;
            true ->
                ok = ?csv_call(mark_partitions_unindexable,
                               [SetName, DDocId, PauseVBuckets])
        end

    catch
        throw:{not_found, deleted} ->
            %% The document has been deleted but we still think it's
            %% alive. Eventually we will get a notification from master db
            %% watcher and delete it from a list of design documents.
            ok;
        T:E ->
            Stack = erlang:get_stacktrace(),
            Exc = [T, E, Stack],
            Undefined = case Exc of
                            [throw, {error, view_undefined}, _] ->
                                true;
                            [error, view_undefined, _] ->
                                true;
                            _ ->
                                false
                        end,
            case Undefined of
                true ->
                    define_and_reapply_index_states(
                      SetName, DDocId, Active, Passive, Cleanup,
                      Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets,
                      State, PastException, Exc);
                _ ->
                    erlang:raise(T, E, Stack)
            end
    end.

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
                      Parent ! {update_ddoc, DDocId, Deleted};
                  _ ->
                      ok
              end;
         (_, _) ->
              ok
      end).

mk_mc_couch_event_handler() ->
    Self = self(),

    fun (Event, _) ->
            handle_mc_couch_event(Self, Event)
    end.

handle_mc_couch_event(Self,
                      {set_vbucket, Bucket, VBucket, State, _Checkpoint}) ->
    ?views_debug("Got set_vbucket event for ~s/~b. Updated state: ~p",
                 [Bucket, VBucket, State]),
    Self ! refresh_usable_vbuckets;
handle_mc_couch_event(Self,
                      {delete_vbucket, _Bucket, VBucket}) ->
    ok = gen_server:call(Self, {delete_vbucket, VBucket}, infinity);
handle_mc_couch_event(_, _) ->
    ok.
