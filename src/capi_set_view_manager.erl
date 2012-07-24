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
-export([fetch_ddocs/2, fetch_full_ddocs/1,
         set_vbucket_states/3]).

-include("couch_db.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").
-include("ns_common.hrl").

-record(state, {bucket :: bucket_name(),
                num_vbuckets :: non_neg_integer(),
                use_replica_index :: boolean(),
                master_db_watcher :: pid(),
                ddocs,
                wanted_states :: [missing | active | replica],
                rebalance_states :: [passive | undefined],
                usable_vbuckets}).

set_vbucket_states(Bucket, WantedStates, RebalanceStates) ->
    gen_server:call(server(Bucket), {set_vbucket_states, WantedStates, RebalanceStates}, infinity).

fetch_full_ddocs(Bucket) ->
    {ok, DDocDB} = couch_db:open_int(master_db(Bucket), []),
    {ok, DDocs} = try
                      couch_db:get_design_docs(DDocDB)
                  after
                      couch_db:close(DDocDB)
                  end,
    DDocs.

fetch_ddocs(Bucket, Timeout) when is_binary(Bucket) ->
    fetch_ddocs(binary_to_list(Bucket), Timeout);
fetch_ddocs(Bucket, Timeout) when is_list(Bucket) ->
    gen_server:call(server(Bucket), fetch_ddocs, Timeout).

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
                    lists:zip3(AllVBs,
                               WantedStates,
                               RebalanceStates)),
    Active = [VB || {VB, active} <- WantedPairs],
    Passive = [VB || {VB, passive} <- WantedPairs],
    Replica = [VB || {VB, replica} <- WantedPairs],
    MainCleanup = (AllVBs -- Active) -- Passive,
    ReplicaCleanup = ((AllVBs -- Replica) -- Active),
    {Active, Passive, MainCleanup, Replica, ReplicaCleanup}.

get_usable_vbuckets_set(Bucket) ->
    PrefixLen = erlang:length(Bucket) + 1,
    sets:from_list(
      [list_to_integer(binary_to_list(VBucketName))
       || FullName <- ns_storage_conf:bucket_databases(Bucket),
          VBucketName <- [binary:part(FullName, PrefixLen, erlang:size(FullName) - PrefixLen)],
          VBucketName =/= <<"master">>]).

apply_vbucket_states(Bucket, DDocIds, WantedStates, RebalanceStates, UseReplicaIndex, ExistingVBuckets) ->
    SetName = list_to_binary(Bucket),
    {Active, Passive, MainCleanup, Replica, ReplicaCleanup} = compute_index_states(WantedStates, RebalanceStates, ExistingVBuckets),
    [apply_index_states(SetName, DDocId, Active, Passive, MainCleanup, Replica, ReplicaCleanup, UseReplicaIndex)
     || DDocId <- DDocIds],
    ok.

change_vbucket_states(DDocIds,
                      #state{bucket = Bucket,
                             wanted_states = WantedStates,
                             rebalance_states = RebalanceStates,
                             use_replica_index = UseReplicaIndex,
                             usable_vbuckets = UsableVBuckets} = _State) ->
    apply_vbucket_states(Bucket, DDocIds, WantedStates, RebalanceStates, UseReplicaIndex, UsableVBuckets).

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

    State0 = #state{bucket=Bucket,
                    num_vbuckets = NumVBuckets,
                    use_replica_index=UseReplicaIndex,
                    master_db_watcher=Watcher,
                    wanted_states = [],
                    rebalance_states = [],
                    usable_vbuckets = get_usable_vbuckets_set(Bucket)},

    State = refresh_ddocs(State0),

    {ok, State}.

flush_update_ddoc_messages() ->
    receive
        {update_ddoc, _, _} ->
            flush_update_ddoc_messages()
    after 0 ->
            ok
    end.

refresh_ddocs(#state{bucket = Bucket} = State) ->
    flush_update_ddoc_messages(),
    DDocs = get_design_docs(Bucket),
    [maybe_define_group(DDocId, State) || DDocId <- sets:to_list(DDocs)],
    State#state{ddocs = DDocs}.

handle_call({set_vbucket_states, WantedStates, RebalanceStates}, _From,
            #state{ddocs = DDocsSet} = State) ->
    State2 = State#state{wanted_states = WantedStates,
                         rebalance_states = RebalanceStates},
    case State2 =:= State of
        true ->
            {reply, ok, State};
        false ->
            change_vbucket_states(sets:to_list(DDocsSet), State2),
            {reply, ok, State2}
    end;

handle_call(fetch_ddocs, _From, #state{ddocs=DDocs} = State) ->
    {reply, {ok, DDocs}, State};
handle_call({delete_vbucket, VBucket}, _From, #state{bucket = Bucket,
                                                     ddocs = DDocsSet,
                                                     wanted_states = [],
                                                     rebalance_states = RebalanceStates,
                                                     use_replica_index = UseReplicaIndex} = State) ->
    [] = RebalanceStates,
    ?log_info("Deleting vbucket ~p from all indexes", [VBucket]),
    SetName = list_to_binary(Bucket),
    [apply_index_states(SetName, DDocId, [], [], [VBucket], [], [VBucket], UseReplicaIndex)
     || DDocId <- sets:to_list(DDocsSet)],
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
            change_vbucket_states(sets:to_list(State#state.ddocs), NewState),
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

handle_info({update_ddoc, DDocId, Deleted0},
            #state{ddocs=DDocs} = State) ->
    Deleted = aggregate_update_ddoc_messages(DDocId, Deleted0),
    ?log_info("Processing update_ddoc ~s (~p)", [DDocId, Deleted]),
    State1 =
        case Deleted of
            false ->
                %% we need to redefine set view whenever document changes; but
                %% previous group for current value of design document can
                %% still be alive; thus using maybe_define_group
                maybe_define_group(DDocId, State),
                %% NOTE: already_defined return may still happen for
                %% brand-new ddoc id. That will happen when new ddoc
                %% is identical to some old ddoc. But we still need to
                %% track all ddocs. Thus adding it to set regardless
                %% of return value
                DDocs1 = sets:add_element(DDocId, DDocs),
                change_vbucket_states([DDocId], State),
                State#state{ddocs=DDocs1};
            true ->
                DDocs1 = sets:del_element(DDocId, DDocs),
                State#state{ddocs=DDocs1}
        end,

    {noreply, State1};

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
            change_vbucket_states(sets:to_list(State2#state.ddocs), State2),
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

define_group(DDocId, #state{bucket = Bucket,
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
            ok
    end.

maybe_define_group(DDocId, State) ->
    try
        define_group(DDocId, State),
        ok
    catch
        throw:view_already_defined ->
            already_defined
    end.

apply_index_states(SetName, DDocId, Active, Passive, Cleanup,
                   Replica, ReplicaCleanup, UseReplicaIndex) ->

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
        throw:{error, view_undefined} ->
            %% see below
            ok;
        throw:view_undefined ->
            %% Design document has been updated but we have not reacted on it
            %% yet. Eventually we will get a notification about
            %% this change and define a group again.
            ok
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


get_design_docs(Bucket) ->
    DDocIds = lists:map(fun (#doc{id=DDocId}) ->
                                DDocId
                        end, fetch_full_ddocs(Bucket)),
    sets:from_list(DDocIds).
