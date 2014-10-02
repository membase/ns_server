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
-export([set_vbucket_states/3, server/1,
         wait_index_updated/2, initiate_indexing/1, reset_master_vbucket/1,
         get_safe_purge_seqs/1, foreach_doc/3, update_doc/2]).

-include("couch_db.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").
-include("ns_common.hrl").

-record(state, {bucket :: bucket_name(),
                local_docs = [] :: [#doc{}],
                num_vbuckets :: non_neg_integer(),
                use_replica_index :: boolean(),
                master_db_watcher :: pid(),
                wanted_states :: [missing | active | replica],
                rebalance_states :: [rebalance_vbucket_state()],
                ddoc_replicator :: pid()}).

set_vbucket_states(Bucket, WantedStates, RebalanceStates) ->
    gen_server:call(server(Bucket), {set_vbucket_states, WantedStates, RebalanceStates}, infinity).

wait_index_updated(Bucket, VBucket) ->
    gen_server:call(server(Bucket), {wait_index_updated, VBucket}, infinity).

initiate_indexing(Bucket) ->
    gen_server:call(server(Bucket), initiate_indexing, infinity).

reset_master_vbucket(Bucket) ->
    gen_server:call(server(Bucket), reset_master_vbucket, infinity).

-spec foreach_doc(ext_bucket_name(),
                  fun ((#doc{}) -> any()),
                  non_neg_integer() | infinity) -> [{binary(), any()}].
foreach_doc(Bucket, Fun, Timeout) ->
    gen_server:call(server(Bucket), {foreach_doc, Fun}, Timeout).

update_doc(Bucket, Doc) ->
    gen_server:call(server(Bucket), {interactive_update, Doc}, infinity).

-define(csv_call_all(Call, Bucket, DDocId, RestArgs),
        ok = ?csv_call(Call, mapreduce_view, Bucket, DDocId, RestArgs),
        ok = ?csv_call(Call, spatial_view, Bucket, DDocId, RestArgs)).

-define(csv_call(Call, Kind, Bucket, DDocId, RestArgs),
        %% hack to not introduce any variables in the caller environment
        ((fun () ->
                  %% we may want to downgrade it to ?views_debug at some point
                  ?views_debug("~nCalling couch_set_view:~p(~s, <<\"~s\">>, <<\"~s\">>, ~w)", [Call, Kind, Bucket, DDocId, RestArgs]),
                  try
                      {__Time, __Result} = timer:tc(couch_set_view, Call, [Kind, Bucket, DDocId | RestArgs]),

                      ?views_debug("~ncouch_set_view:~p(~s, <<\"~s\">>, <<\"~s\">>, ~w) returned ~p in ~bms",
                                   [Call, Kind, Bucket, DDocId, RestArgs, __Result, __Time div 1000]),
                      __Result
                  catch
                      __T:__E ->
                          ?views_debug("~ncouch_set_view:~p(~s, <<\"~s\">>, <<\"~s\">>, ~w) raised~n~p:~p",
                                       [Call, Kind, Bucket, DDocId, RestArgs, __T, __E]),

                          %% rethrowing the exception
                          __Stack = erlang:get_stacktrace(),
                          erlang:raise(__T, __E, __Stack)
                  end
          end)())).


compute_index_states(WantedStates, RebalanceStates) ->
    AllVBs = lists:seq(0, erlang:length(WantedStates)-1),
    Triples = lists:zip3(AllVBs,
                         WantedStates,
                         RebalanceStates),
                                                % Ensure Active, Passive and Replica are ordsets
    {Active, Passive, Replica} = lists:foldr(
                                   fun ({VBucket, WantedState, TmpState}, {AccActive, AccPassive, AccReplica}) ->
                                           case {WantedState, TmpState} of
                                               %% {replica, passive} ->
                                               %%     {AccActibe, [VBucket | AccPassive], [VBucket | AccReplica]};
                                               {_, passive} ->
                                                   {AccActive, [VBucket | AccPassive], AccReplica};
                                               {active, _} ->
                                                   {[VBucket | AccActive], AccPassive, AccReplica};
                                               {replica, _} ->
                                                   {AccActive, AccPassive, [VBucket | AccReplica]};
                                               _ ->
                                                   {AccActive, AccPassive, AccReplica}
                                           end
                                   end,
                                   {[], [], []},
                                   Triples),
    AllMain = ordsets:union(Active, Passive),
    MainCleanup = ordsets:subtract(AllVBs, AllMain),
    ReplicaCleanup = ordsets:subtract(ordsets:subtract(AllVBs, Replica), Active),
    PauseVBuckets = [VBucket
                     || {VBucket, WantedState, TmpState} <- Triples,
                        TmpState =:= paused,
                        begin
                            active = WantedState,
                            true
                        end],
    UnpauseVBuckets = ordsets:subtract(AllVBs, PauseVBuckets),
    {Active, Passive, MainCleanup, Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets}.

do_apply_vbucket_states(SetName, Active, Passive, MainCleanup, Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets, State) ->
    DDocIds = get_live_ddoc_ids(State),
    RVs = [{DDocId, (catch begin
                               apply_index_states(SetName, DDocId,
                                                  Active, Passive, MainCleanup, Replica, ReplicaCleanup,
                                                  PauseVBuckets, UnpauseVBuckets,
                                                  State),
                               ok
                           end)}
           || DDocId <- DDocIds],
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
                             rebalance_states = RebalanceStates} = State) ->
    SetName = list_to_binary(Bucket),
    {Active, Passive, MainCleanup, Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets} =
        compute_index_states(WantedStates, RebalanceStates),
    do_apply_vbucket_states(SetName, Active, Passive, MainCleanup, Replica, ReplicaCleanup, PauseVBuckets, UnpauseVBuckets, State).

start_link(Bucket) ->
    single_bucket_sup:ignore_if_not_couchbase_bucket(
      Bucket,
      fun (BucketConfig) ->
              UseReplicaIndex = (proplists:get_value(replica_index, BucketConfig) =/= false),
              VBucketsCount = proplists:get_value(num_vbuckets, BucketConfig),

              gen_server:start_link({local, server(Bucket)}, ?MODULE,
                                    {Bucket, UseReplicaIndex, VBucketsCount}, [])
      end).

nodeup_monitoring_loop(Parent) ->
    receive
        {nodeup, _} ->
            ?log_debug("got nodeup event. Considering ddocs replication"),
            Parent ! replicate_newnodes_docs;
        _ ->
            ok
    end,
    nodeup_monitoring_loop(Parent).

init({Bucket, UseReplicaIndex, NumVBuckets}) ->
    process_flag(trap_exit, true),
    Self = self(),

    %% Update myself whenever the config changes (rebalance)
    ns_pubsub:subscribe_link(
      ns_config_events,
      fun (_, _) -> Self ! replicate_newnodes_docs end,
      empty),

    {ok, DDocReplicationProxy} = capi_ddoc_replication_srv:start_link(Bucket),
    erlang:put('ddoc_replication_proxy', DDocReplicationProxy),

    {ok, Db} = open_local_db(Bucket),
    Docs = try
               {ok, ADocs} = couch_db:get_design_docs(Db, deleted_also),
               ADocs
           after
               ok = couch_db:close(Db)
           end,
    %% anytime we disconnect or reconnect, force a replicate event.
    erlang:spawn_link(
      fun () ->
              ok = net_kernel:monitor_nodes(true),
              nodeup_monitoring_loop(Self)
      end),
    Self ! replicate_newnodes_docs,

    %% Explicitly ask all available nodes to send their documents to us
    ServerName = capi_ddoc_replication_srv:proxy_server_name(Bucket),
    [{ServerName, N} ! replicate_newnodes_docs ||
        N <- get_remote_nodes(Bucket)],

    Replicator = spawn_ddoc_replicator(ServerName),

    State = #state{bucket=Bucket,
                   local_docs = Docs,
                   num_vbuckets = NumVBuckets,
                   use_replica_index=UseReplicaIndex,
                   wanted_states = [],
                   rebalance_states = [],
                   ddoc_replicator = Replicator},

    proc_lib:init_ack({ok, self()}),

    [maybe_define_group(DDocId, State)
     || DDocId <- get_live_ddoc_ids(State)],

    gen_server:enter_loop(?MODULE, [], State).

get_live_ddoc_ids(#state{local_docs = Docs}) ->
    [Id || #doc{id = Id, deleted = false} <- Docs].

handle_call({wait_index_updated, VBucket}, From, State) ->
    ok = proc_lib:start_link(erlang, apply, [fun do_wait_index_updated/4, [From, VBucket, self(), State]]),
    {noreply, State};
handle_call(initiate_indexing, _From, State) ->
    BinBucket = list_to_binary(State#state.bucket),
    DDocIds = get_live_ddoc_ids(State),
    [case DDocId of
         <<"_design/dev_", _/binary>> -> ok;
         _ ->
             couch_set_view:trigger_update(mapreduce_view, BinBucket, DDocId, 0),
             couch_set_view:trigger_update(spatial_view, BinBucket, DDocId, 0)
     end || DDocId <- DDocIds],
    {reply, ok, State};
handle_call({interactive_update, #doc{id=Id}=Doc}, _From,
            #state{ddoc_replicator = Replicator} = State) ->
    #state{local_docs=Docs}=State,
    Rand = crypto:rand_uniform(0, 16#100000000),
    RandBin = <<Rand:32/integer>>,
    {NewRev, FoundType} =
        case lists:keyfind(Id, #doc.id, Docs) of
            false ->
                {{1, RandBin}, missing};
            #doc{rev = {Pos, _DiskRev}, deleted=Deleted} ->
                FoundType0 = case Deleted of
                                 true ->
                                     deleted;
                                 false ->
                                     existent
                             end,
                {{Pos + 1, RandBin}, FoundType0}
        end,

    case Doc#doc.deleted andalso FoundType =/= existent of
        true ->
            {reply, {not_found, FoundType}, State};
        false ->
            NewDoc = Doc#doc{rev=NewRev},
            try
                ?log_debug("Writing interactively saved ddoc ~p", [Doc]),
                SavedDocState = save_doc(NewDoc, State),
                Replicator ! {replicate_change, NewDoc},
                {reply, ok, SavedDocState}
            catch throw:{invalid_design_doc, _} = Error ->
                    ?log_debug("Document validation failed: ~p", [Error]),
                    {reply, Error, State}
            end
    end;
handle_call({foreach_doc, Fun}, _From, #state{local_docs = Docs} = State) ->
    Res = [{Id, (catch Fun(Doc))} || #doc{id = Id} = Doc <- Docs],
    {reply, Res, State};
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

handle_call(reset_master_vbucket, _From, #state{bucket = Bucket,
                                                local_docs = LocalDocs} = State) ->
    MasterVBucket = iolist_to_binary([Bucket, <<"/master">>]),
    {ok, master_db_deletion} = {couch_server:delete(MasterVBucket, []), master_db_deletion},
    {ok, MasterDB} = open_local_db(Bucket),
    ok = couch_db:close(MasterDB),
    [save_doc(Doc, State) || Doc <- LocalDocs],
    {reply, ok, State}.


handle_cast({replicated_update, #doc{id=Id, rev=Rev}=Doc}, State) ->
    %% this is replicated from another node in the cluster. We only accept it
    %% if it doesn't exist or the rev is higher than what we have.
    #state{local_docs=Docs} = State,
    Proceed = case lists:keyfind(Id, #doc.id, Docs) of
                  false ->
                      true;
                  #doc{rev = DiskRev} when Rev > DiskRev ->
                      true;
                  _ ->
                      false
              end,
    if Proceed ->
            ?log_debug("Writing replicated ddoc ~p", [Doc]),
            {noreply, save_doc(Doc, State)};
       true ->
            {noreply, State}
    end.

aggregate_update_ddoc_messages(DDocId, Deleted) ->
    receive
        {update_ddoc, DDocId, NewDeleted} ->
            aggregate_update_ddoc_messages(DDocId, NewDeleted)
    after 0 ->
            Deleted
    end.

handle_info(replicate_newnodes_docs, #state{bucket = Bucket,
                                            local_docs = Docs,
                                            ddoc_replicator = Replicator} = State) ->
    Replicator ! {replicate_newnodes_docs, get_remote_nodes(Bucket), Docs},
    {noreply, State};
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

handle_info({'EXIT', Pid, Reason}, State) ->
    ?views_error("Linked process ~p died unexpectedly: ~p", [Pid, Reason]),
    {stop, {linked_process_died, Pid, Reason}, State};

handle_info(Info, State) ->
    ?log_info("Ignoring unexpected message: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{ddoc_replicator = Replicator} = _State) ->
    case erlang:get('ddoc_replication_proxy') of
        Pid when is_pid(Pid) ->
            erlang:exit(Pid, kill),
            misc:wait_for_process(Pid, infinity);
        _ ->
            ok
    end,

    erlang:exit(Replicator, kill),
    misc:wait_for_process(Replicator, infinity),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

server(Bucket) when is_binary(Bucket) ->
    server(erlang:binary_to_list(Bucket));
server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

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
        ok = ?csv_call(define_group, mapreduce_view, SetName, DDocId, [Params])
    catch
        throw:{not_found, deleted} ->
            %% The document has been deleted but we still think it's
            %% alive. Eventually we will get a notification from master db
            %% watcher and delete it from a list of design documents.
            ok;
        throw:view_already_defined ->
            already_defined
    end,
    try
        ok = ?csv_call(define_group, spatial_view, SetName, DDocId, [Params])
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
                ?csv_call_all(mark_partitions_indexable,
                              SetName, DDocId, [UnpauseVBuckets])
        end,

        %% this should go first because some of the replica vbuckets might
        %% need to be cleaned up from main index
        ?csv_call_all(set_partition_states,
                      SetName, DDocId, [Active, Passive, Cleanup]),

        case UseReplicaIndex of
            true ->
                ?csv_call_all(add_replica_partitions,
                              SetName, DDocId, [Replica]),
                ?csv_call_all(remove_replica_partitions,
                              SetName, DDocId, [ReplicaCleanup]);
            false ->
                ok
        end,

        case PausingOn of
            false ->
                ok;
            true ->
                ?csv_call_all(mark_partitions_unindexable,
                              SetName, DDocId, [PauseVBuckets])
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

open_local_db(Bucket) ->
    MasterVBucket = iolist_to_binary([Bucket, <<"/master">>]),
    case couch_db:open(MasterVBucket, []) of
        {ok, Db} ->
            {ok, Db};
        {not_found, _} ->
            couch_db:create(MasterVBucket, [])
    end.

save_doc(#doc{id = Id} = Doc,
         #state{bucket=Bucket, local_docs=Docs}=State) ->
    {ok, Db} = open_local_db(Bucket),
    try
        ok = couch_db:update_doc(Db, Doc)
    after
        ok = couch_db:close(Db)
    end,
    self() ! {update_ddoc, Id, Doc#doc.deleted},
    State#state{local_docs = lists:keystore(Id, #doc.id, Docs, Doc)}.

do_wait_index_updated({Pid, _} = From, VBucket,
                      ParentPid, #state{bucket = Bucket} = State) ->
    DDocIds = get_live_ddoc_ids(State),
    BinBucket = list_to_binary(Bucket),
    Refs = lists:foldl(
             fun (DDocId, Acc) ->
                     case DDocId of
                         <<"_design/dev_", _/binary>> -> Acc;
                         _ ->
                             RefMapReduce =
                                 couch_set_view:monitor_partition_update(
                                   mapreduce_view, BinBucket, DDocId,
                                   VBucket),
                             couch_set_view:trigger_update(
                               mapreduce_view, BinBucket, DDocId, 0),
                             RefSpatial =
                                 couch_set_view:monitor_partition_update(
                                   spatial_view, BinBucket, DDocId,
                                   VBucket),
                             couch_set_view:trigger_update(
                               spatial_view, BinBucket, DDocId, 0),
                             [RefMapReduce, RefSpatial | Acc]
                     end
             end, [], DDocIds),
    ?log_debug("References to wait: ~p (~p, ~p)", [Refs, Bucket, VBucket]),
    ParentMRef = erlang:monitor(process, ParentPid),
    CallerMRef = erlang:monitor(process, Pid),
    proc_lib:init_ack(ok),
    erlang:unlink(ParentPid),
    [receive
         {Ref, Msg} -> % Ref is bound
             case Msg of
                 updated -> ok;
                 _ ->
                     ?log_debug("Got unexpected message from ddoc monitoring. Assuming that's shutdown: ~p", [Msg])
             end;
         {'DOWN', ParentMRef, _, _, _} = DownMsg ->
             ?log_debug("Parent died: ~p", [DownMsg]),
             exit({parent_exited, DownMsg});
         {'DOWN', CallerMRef, _, _, _} = DownMsg ->
             ?log_debug("Caller died: ~p", [DownMsg]),
             exit(normal)
     end
     || Ref <- Refs],
    ?log_debug("All refs fired"),
    gen_server:reply(From, ok).

-spec get_safe_purge_seqs(BucketName :: binary()) -> [{non_neg_integer(), non_neg_integer()}].
get_safe_purge_seqs(BucketName) ->
    lists:foldl(
      fun (<<"_design/dev_",_>>, SafeSeqs) ->
              %% we ignore dev design docs
              SafeSeqs;
          (DDocId, SafeSeqs) ->
              case (catch couch_set_view:get_indexed_seqs(mapreduce_view, BucketName, DDocId, prod)) of
                  {ok, IndexSeqs} ->
                      misc:ukeymergewith(
                        fun ({Vb, SeqA}, {_, SeqB}) ->
                                {Vb, case SeqA < SeqB of
                                         true -> SeqA;
                                         _ -> SeqB
                                     end}
                        end, 1, SafeSeqs, IndexSeqs);
                  {not_found, missing} ->
                      SafeSeqs;
                  Error ->
                      ?log_error("ignoring unexpected get_indexed_seqs(~s, ~s) failure: ~p", [BucketName, DDocId, Error]),
                      SafeSeqs
              end
      end, [], capi_utils:fetch_ddoc_ids(BucketName)).

spawn_ddoc_replicator(ServerName) ->
    proc_lib:spawn_link(
      fun () ->
              ddoc_replicator_loop(ServerName, [])
      end).

ddoc_replicator_loop(ServerName, RemoteNodes) ->
    NewRemoteNodes =
        receive
            {replicate_change, Doc} ->
                [replicate_change_to_node(ServerName, Node, Doc)
                 || Node <- RemoteNodes],
                RemoteNodes;
            {replicate_newnodes_docs, AllNodes, Docs} ->
                ?log_debug("doing replicate_newnodes_docs"),

                NewNodes = AllNodes -- RemoteNodes,
                case NewNodes of
                    [] ->
                        ok;
                    _ ->
                        [monitor(process, {ServerName, Node}) || Node <- NewNodes],
                        [replicate_change_to_node(ServerName, S, D)
                         || S <- NewNodes,
                            D <- Docs]
                end,
                AllNodes;
            {'DOWN', _Ref, _Type, {Server, RemoteNode}, Error} ->
                ?log_warning("Remote server node ~p process down: ~p",
                             [{Server, RemoteNode}, Error]),
                RemoteNodes -- [RemoteNode];
            Msg ->
                ?log_error("Got unexpected message: ~p", [Msg]),
                exit({unexpected_message, Msg})
        end,

    ddoc_replicator_loop(ServerName, NewRemoteNodes).

replicate_change_to_node(ServerName, Node, Doc) ->
    ?log_debug("Sending ~s to ~s", [Doc#doc.id, Node]),
    gen_server:cast({ServerName, Node}, {replicated_update, Doc}).

get_remote_nodes(Bucket) ->
    case ns_bucket:get_bucket(Bucket) of
        {ok, Conf} ->
            proplists:get_value(servers, Conf) -- [node()];
        not_present ->
            []
    end.
