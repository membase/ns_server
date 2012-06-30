%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.
%%
%% The XDC Replication Manager (XRM) manages vbucket replication to remote data
%% centers. Each instance of XRM running on a node is responsible for only
%% replicating the node's active vbuckets. Individual vbucket replications are
%% delegated to CouchDB's Replication Manager (CRM) and are controlled by
%% adding/deleting replication documents to the _replicator db.
%%
%% A typical XDC replication document will look as follows:
%% {
%%   "_id" : "my_xdc_rep",
%%   "type" : "xdc",
%%   "source" : "bucket0",
%%   "target" : "http://uid:pwd@10.1.6.190:8091/pools/default/buckets/bucket0",
%%   "continuous" : true
%% }
%%
%% After an XDC replication is triggered, all info and state pertaining to it
%% will be stored in a document with the following structure. The doc's id will
%% be derived from the id of the corresponding replication doc by appending
%% "_info" to it:
%% {
%%   "_id" : "my_xdc_rep_info_6d6b46f7065e8600955f479376000b3a",
%%   "node" : "6d6b46f7065e8600955f479376000b3a",
%%   "replication_doc_id" : "my_xdc_rep",
%%   "replication_id" : "c0ebe9256695ff083347cbf95f93e280",
%%   "source" : "",
%%   "target" : "",
%%   "_replication_state" : "triggered",
%%   "_replication_state_time" : "2011-10-31T17:33:04-07:00",
%%   "replication_state_vb_1" : "triggered",
%%   "replication_state_vb_3" : "completed",
%%   "replication_state_vb_5" : "triggered"
%% }
%%
%% The XRM maintains local state about all in-progress replications and
%% comprises of the following data structures:
%% XSTORE: An ETS set of {XDocId, XRep, TriggeredVbs, UntriggeredVbs} tuples
%%         XDocId: Id of a user created XDC replication document
%%         XRep: The parsed #rep record for the document
%%         TriggeredVbs: Vbuckets whose replication was successfully triggered
%%         UntriggeredVbs: Vbuckets whose replication could not be triggered.
%%                         These are periodically retried.
%%
%% X2CSTORE: An ETS bag of {XDocId, CRepPids} tuples
%%           CRepPids: List of Pids of the Couch process responsible for an individual
%%                    vbucket replication
%%
%% CSTORE: An ETS set of {CRepPid, CRep, Vb, State, Wait}
%%         CRep: The parsed #rep record for the couch replication
%%         Vb: The vbucket id being replicated
%%         State: Couch replication state (triggered/completed/error)
%%         Wait: The amount of time to wait before retrying replication
%%

-module(xdc_rep_manager).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("xdc_replicator.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init(_) ->
    process_flag(trap_exit, true),
    Server = self(),
    ?XSTORE = ets:new(?XSTORE, [named_table, set, protected]),
    ?X2CSTORE = ets:new(?X2CSTORE, [named_table, bag, protected]),
    ?CSTORE = ets:new(?CSTORE, [named_table, set, protected]),

    %% Subscribe to bucket map changes due to rebalance and failover operations
    %% at the source
    NsConfigEventsHandler = fun ({buckets, _} = Evt, _Acc) ->
                                    Server ! Evt;
                                (_, Acc) ->
                                    Acc
                            end,
    ns_pubsub:subscribe_link(ns_config_events, NsConfigEventsHandler, []),

    SchedulingInterval = misc:getenv_int("XDCR_SCHEDULING_INTERVAL",
                                         ?XDCR_SCHEDULING_INTERVAL),
    {ok, _Tref} = timer:send_interval(SchedulingInterval * 1000,
                                      manage_vbucket_replications),

    <<"_replicator">> = ?l2b(couch_config:get("replicator", "db",
                                              "_replicator")),

    maybe_create_replication_info_ddoc(),

    %% monitor replication doc change
    {Loop, <<"_replicator">> = RepDbName} =
        xdc_rep_manager_helper:changes_feed_loop(),

    {ok, #rep_db_state{
       changes_feed_loop = Loop,
       rep_db_name = RepDbName
      }}.

maybe_create_replication_info_ddoc() ->
    UserCtx = #user_ctx{roles = [<<"_admin">>, <<"_replicator">>]},
    DB = case couch_db:open_int(<<"_replicator">>,
                                [sys_db, {user_ctx, UserCtx}]) of
             {ok, XDb} ->
                 XDb;
             _Error ->
                 {ok, XDb} = couch_db:create(<<"_replicator">>,
                                             [sys_db, {user_ctx, UserCtx}]),
                 ?xdcr_info("replication doc created"),
                 XDb
         end,
    try couch_db:open_doc(DB, <<"_design/_replicator_info">>, []) of
        {ok, _Doc} ->
            ok;
        _ ->
            DDoc = couch_doc:from_json_obj(
                     {[{<<"_id">>, <<"_design/_replicator_info">>},
                       {<<"language">>, <<"javascript">>},
                       {<<"views">>,
                        {[{<<"infos">>,
                           {[{<<"map">>, ?REPLICATION_INFOS_MAP},
                             {<<"reduce">>, ?REPLICATION_INFOS_REDUCE}]}}]}}]}),
            ok = couch_db:update_doc(DB, DDoc, [])
    after
        couch_db:close(DB)
    end.

handle_call({rep_db_update, {ChangeProps} = Change}, _From, State) ->
    try
        process_update(Change, State#rep_db_state.rep_db_name)
    catch
        _Tag:Error ->
            {RepProps} = get_value(doc, ChangeProps),
            DocId = get_value(<<"_id">>, RepProps),
            xdc_rep_manager_helper:update_rep_doc(
              xdc_rep_utils:info_doc_id(DocId),
              [{<<"_replication_state">>, <<"error">>}]),
            ?xdcr_error("~s: xdc replication error: ~p~n~p",
                        [DocId, Error, erlang:get_stacktrace()]),
            State
    end,
    {reply, ok, State};

handle_call(Msg, From, State) ->
    ?xdcr_error("replication manager received unexpected call ~p from ~p",
                [Msg, From]),
    {stop, {error, {unexpected_call, Msg}}, State}.

handle_cast(Msg, State) ->
    ?xdcr_error("replication manager received unexpected cast ~p", [Msg]),
    {stop, {error, {unexpected_cast, Msg}}, State}.

consume_all_buckets_changes(Buckets) ->
    receive
        {buckets, NewerBuckets} ->
            consume_all_buckets_changes(NewerBuckets)
    after 0 ->
            Buckets
    end.

handle_info({buckets, Buckets0}, State) ->
    %% The source vbucket map changed
    Buckets = consume_all_buckets_changes(Buckets0),
    maybe_adjust_all_replications(proplists:get_value(configs, Buckets)),
    {noreply, State};


handle_info(manage_vbucket_replications, State) ->
    _NumMsgs = misc:flush(manage_vbucket_replications),
    manage_vbucket_replications(),
    {noreply, State};


handle_info({'EXIT', From, normal},
            #rep_db_state{changes_feed_loop = From} = State) ->
    %% replicator DB deleted
    {noreply, State#rep_db_state{changes_feed_loop = nil, rep_db_name = nil}};

handle_info({'EXIT', From, Reason} = Msg, State) ->
    ?xdcr_error("Dying since linked process died: ~p", [Msg]),
    {stop, {linked_process_died, From, Reason}, State};

handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    case ets:member(?CSTORE, Pid) of
        true ->
            %% A message from one of the replicator processes
            [XDocId] = lists:flatten(ets:match(?X2CSTORE, {'$1', Pid})),
            Vb = ets:lookup_element(?CSTORE, Pid, 3),
            case Reason of
                normal ->
                    %% Couch replication completed normally
                    true = ets:update_element(?CSTORE, Pid, {4, completed});
                noproc ->
                    %% Couch replication may have finished before we could start
                    %% monitoring it. This could happen, for example, if there was no
                    %% data to be replicated to begin with.
                    true = ets:update_element(?CSTORE, Pid, {4, completed});
                _ ->
                    %% Couch replication failed due to an error. Update the state
                    %% in CSTORE so that it may be picked up the next time
                    %% manage_vbucket_replications() is run by the timer
                    %% module.
                    true = ets:update_element(?CSTORE, Pid, {4, error}),
                    xdc_rep_manager_helper:update_rep_doc(
                      xdc_rep_utils:info_doc_id(XDocId),
                      [{?l2b("replication_state_vb_" ++ ?i2l(Vb)), <<"error">>},
                       {<<"_replication_state">>, <<"error">>}]),
                    ?xdcr_info("~s: replication of vbucket ~p failed due to reason: "
                               "~p", [XDocId, Vb, Reason])
            end;
        false ->
            %% Ignore messages regarding Pids not found in the CSTORE. These messages
            %% may come from either Couch replications that were explicitly cancelled
            %% (which means that their CSTORE state has already been cleaned up) or
            %% a db monitor created by the Couch replicator.
            ok
    end,
    {noreply, State};


handle_info(Msg, State) ->
    %% Ignore any other messages but log them
    ?xdcr_info("ignoring unexpected message: ~p", [Msg]),
    {noreply, State}.


terminate(_Reason, _State) ->
    cancel_all_xdc_replications(),
    true = ets:delete(?CSTORE),
    true = ets:delete(?X2CSTORE),
    true = ets:delete(?XSTORE).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

process_update({Change}, RepDbName) ->
    DocDeleted = get_value(<<"deleted">>, Change, false),
    {DocProps} = DocBody = get_value(doc, Change),
    case DocDeleted of
        true ->
            DocId = get_value(<<"_id">>, DocProps),
            maybe_cancel_xdc_replication(DocId);
        false ->
            case get_value(<<"type">>, DocProps) of
                <<"xdc">> ->
                    process_xdc_update(DocBody, RepDbName);
                _ ->
                    ok
            end
    end.


%%
%% XDC specific functions
%%
process_xdc_update(XDocBody, RepDbName) ->
    {XDocProps} = XDocBody,
    XDocId = get_value(<<"_id">>, XDocProps),
    case xdc_rep_manager_helper:get_xdc_rep_state(XDocId, RepDbName) of
        undefined ->
            maybe_start_xdc_replication(XDocId, XDocBody, RepDbName);
        <<"triggered">> ->
            maybe_start_xdc_replication(XDocId, XDocBody, RepDbName);
        <<"error">> ->
            maybe_start_xdc_replication(XDocId, XDocBody, RepDbName);
        <<"completed">> ->
            ok
    end.


maybe_start_xdc_replication(XDocId, XDocBody, RepDbName) ->
    #rep{id = {XBaseId, _Ext} = XRepId} = XRep =
        xdc_rep_manager_helper:parse_xdc_rep_doc(XDocBody),
    case lists:flatten(ets:match(?XSTORE, {'$1', #rep{id = XRepId}})) of
        [] ->
            %% A new XDC replication document.
            ?xdcr_info("~s: triggering xdc replication", [XDocId]),
            start_xdc_replication(XRep, RepDbName, XDocBody);
        [XDocId] ->
            %% An XDC replication document previously seen. Ignore.
            ?xdcr_info("~s: ignoring doc previously seen", [XDocId]),
            ok;
        [OtherDocId] ->
            %% A new XDC replication document specifying a previous replication.
            %% Ignore but let  the user know.
            ?xdcr_info("~s: xdc replication was already triggered by doc ~s",
                       [XDocId, OtherDocId]),
            xdc_rep_manager_helper:maybe_tag_rep_doc(XDocId, XDocBody,
                                                     ?l2b(XBaseId))
    end.

start_xdc_replication(#rep{id = XRepId,
                           source = SrcBucketBinary,
                           target = {_, TgtBucket, _, _, _, _, _, _, _, _},
                           doc_id = XDocId} = XRep,
                      RepDbName,
                      XDocBody) ->
    SrcBucket = ?b2l(SrcBucketBinary),
    SrcBucketLookup = ns_bucket:get_bucket(SrcBucket),
    TgtBucketLookup = xdc_rep_utils:remote_vbucketmap_nodelist(TgtBucket),

    case {SrcBucketLookup, TgtBucketLookup} of
        {not_present, not_present} ->
            ?xdcr_error("~s: source and target buckets not found", [XDocId]),
            true = ets:insert(?XSTORE, {XDocId, XRep, [], []}),
            {error, not_present};
        {not_present, _} ->
            ?xdcr_error("~s: source bucket not found", [XDocId]),
            true = ets:insert(?XSTORE, {XDocId, XRep, [], []}),
            {error, not_present};
        {_, not_present} ->
            ?xdcr_error("~s: target bucket not found", [XDocId]),
            true = ets:insert(?XSTORE, {XDocId, XRep, [], []}),
            {error, not_present};
        {{ok, SrcBucketConfig}, _} ->
            MyVbs = xdc_rep_utils:my_active_vbuckets(SrcBucketConfig),
            true = ets:insert(?XSTORE, {XDocId, XRep, MyVbs}),
            xdc_rep_manager_helper:create_xdc_rep_info_doc(
              XDocId, XRepId, MyVbs, RepDbName, XDocBody),
            ok
    end.

cancel_all_xdc_replications() ->
    ?xdcr_info("cancelling all xdc replications"),
    ets:foldl(
      fun(XDocId, _Ok) ->
              maybe_cancel_xdc_replication(XDocId)
      end,
      ok, ?XSTORE).

maybe_cancel_xdc_replication(XDocId) ->
    case ets:lookup(?XSTORE, XDocId) of
        [] ->
            %% Ignore non xdc type docs such as info docs, etc.
            ok;
        _ ->
            CRepPids =
                try
                    ets:lookup_element(?X2CSTORE, XDocId, 2)
                catch
                    error:badarg ->
                        []
                end,

            ?xdcr_info("~s: cancelling xdc replication", [XDocId]),
            CancelledVbs = lists:map(
                             fun(CRepPid) ->
                                     Vb = ets:lookup_element(?CSTORE, CRepPid, 3),
                                     cancel_couch_replication(XDocId, CRepPid),
                                     Vb
                             end,
                             CRepPids),
            true = ets:delete(?XSTORE, XDocId),
            xdc_rep_manager_helper:update_rep_doc(
              xdc_rep_utils:info_doc_id(XDocId),
              [{<<"_replication_state">>, <<"cancelled">>} |
               xdc_rep_utils:vb_rep_state_list(CancelledVbs, <<"cancelled">>)]),
            ok
    end.

maybe_adjust_all_replications(BucketConfigs) ->
    lists:foreach(
      fun([XDocId, #rep{source = SrcBucket}, PrevVbs]) ->
              SrcBucketConfig =
                  proplists:get_value(?b2l(SrcBucket), BucketConfigs),
              CurrVbs = xdc_rep_utils:my_active_vbuckets(SrcBucketConfig),
              maybe_adjust_xdc_replication(XDocId, PrevVbs, CurrVbs)
      end,
      ets:match(?XSTORE, {'$1', '$2', '$3'})).

maybe_adjust_xdc_replication(XDocId, PrevVbs, CurrVbs) ->
    {_AcquiredVbs, LostVbs} = xdc_rep_utils:lists_difference(CurrVbs, PrevVbs),

    %% Cancel Couch replications for the lost vbuckets
    CRepPidsToCancel =
        try
            [CRepPid || CRepPid <- ets:lookup_element(?X2CSTORE, XDocId, 2),
                        lists:member(ets:lookup_element(?CSTORE, CRepPid, 3),
                                     LostVbs)]
        catch error:badarg ->
                []
        end,
    lists:foreach(
      fun(CRepPid) ->
              cancel_couch_replication(XDocId, CRepPid)
      end,
      CRepPidsToCancel),

    %% Mark entries for the cancelled Couch replications in the replication
    %% info doc as "cancelled"
    xdc_rep_manager_helper:update_rep_doc(
      xdc_rep_utils:info_doc_id(XDocId),
      xdc_rep_utils:vb_rep_state_list(LostVbs, <<"cancelled">>)),

    %% Update XSTORE with the current active vbuckets list
    true = ets:update_element(?XSTORE, XDocId, [{3, CurrVbs}]).

start_vbucket_replication(XDocId, SrcBucket, {TgtVbMap, TgtNodes}, Vb) ->
    SrcURI = xdc_rep_utils:local_couch_uri_for_vbucket(SrcBucket, Vb),
    TgtURI = xdc_rep_utils:remote_couch_uri_for_vbucket(TgtVbMap, TgtNodes, Vb),
    start_couch_replication(SrcURI, TgtURI, Vb, XDocId).

restart_vbucket_replication(XDocId, SrcBucket, TgtVbInfo, Vb, CRepPid) ->
    cancel_couch_replication(XDocId, CRepPid),
    start_vbucket_replication(XDocId, SrcBucket, TgtVbInfo, Vb).

start_couch_replication(SrcCouchURI, TgtCouchURI, Vb, XDocId) ->
    %% Until scheduled XDC replication support is added, this function will
    %% trigger continuous replication by default at the Couch level.
    {ok, CRep} =
        xdc_rep_utils:parse_rep_doc(
          {[{<<"source">>, SrcCouchURI},
            {<<"target">>, TgtCouchURI}
           ]},
          #user_ctx{roles = [<<"_admin">>]}),

    case xdc_replicator:async_replicate(CRep) of
        {ok, CRepPid} ->
            erlang:monitor(process, CRepPid),
            CRepState = triggered,
            true = ets:insert(?CSTORE, {CRepPid, CRep, Vb, CRepState}),
            true = ets:insert(?X2CSTORE, {XDocId, CRepPid}),
            xdc_rep_manager_helper:update_rep_doc(
              xdc_rep_utils:info_doc_id(XDocId),
              [{?l2b("replication_state_vb_" ++ ?i2l(Vb)), <<"triggered">>}]),
            ?xdcr_info("~s: triggered replication for vbucket ~p", [XDocId, Vb]),
            {ok, CRepPid};
        Error ->
            ?xdcr_info("~s: triggering of replication for vbucket ~p failed due to: "
                       "~p", [XDocId, Vb, Error]),
            {error, Error}
    end.

cancel_couch_replication(XDocId, CRepPid) ->
    [CRep, CRepState] =
        lists:flatten(ets:match(?CSTORE, {CRepPid, '$1', '_', '$2'})),
    case CRepState of
        triggered ->
            xdc_replicator:cancel_replication(CRep#rep.id);
        _ ->
            ok
    end,
    true = ets:delete(?CSTORE, CRepPid),
    true = ets:delete_object(?X2CSTORE, {XDocId, CRepPid}),
    ok.

manage_vbucket_replications() ->
    lists:foreach(
      fun([XDocId,
           #rep{source = SrcBucket,
                target = {_, TgtBucket, _, _, _, _, _, _, _, _}},
           Vbs]) ->
              MaxConcurrentReps = max_concurrent_reps(SrcBucket),
              NumActiveReps = length(active_replications_for_doc(XDocId)),
              case (MaxConcurrentReps - NumActiveReps) of
                  0 ->
                      ok;
                  NumFreeSlots ->
                      {Vbs1, Vbs2} = lists:split(erlang:min(NumFreeSlots, length(Vbs)), Vbs),
                      %% Reread the target vbucket map once before retrying all reps
                      {ok, TgtVbInfo} =
                          xdc_rep_utils:remote_vbucketmap_nodelist(TgtBucket),
                      lists:foreach(
                        fun(Vb) ->
                                case lists:flatten(ets:match(
                                                     ?CSTORE, {'$1', '_', Vb, '$2'})) of
                                    [] ->
                                        %% New vbucket
                                        start_vbucket_replication(XDocId, SrcBucket,
                                                                  TgtVbInfo, Vb);
                                    [CRepPid, error] ->
                                        %% Failed vbucket
                                        restart_vbucket_replication(XDocId, SrcBucket,
                                                                    TgtVbInfo, Vb, CRepPid);
                                    [CRepPid, completed] ->
                                        %% Completed vbucket
                                        restart_vbucket_replication(XDocId, SrcBucket,
                                                                    TgtVbInfo, Vb, CRepPid);
                                    [_, triggered] ->
                                        %% In progress vbucket
                                        ok
                                end
                        end, Vbs1),
                      %% Update XSTORE with the new vbuckets list
                      true = ets:update_element(?XSTORE, XDocId, [{3, (Vbs2 ++ Vbs1)}])
              end
      end,
      ets:match(?XSTORE, {'$1', '$2', '$3'})).

active_replications_for_doc(XDocId) ->
    %% For the given XDocId:
    %% 1. Lookup all CRepPids in X2CSTORE.
    %% 2. For each CRepPid, lookup its record in CSTORE.
    %% 3. Only select records whose State attribute equals 'triggered'.
    %% 4. Return the list of records found.
    Pids =
        try
            ets:lookup_element(?X2CSTORE, XDocId, 2)
        catch
            error:badarg ->
                []
        end,
    [{CRepPid} ||
        {CRepPid, _CRep, _, State} <-
            lists:flatten([(ets:lookup(?CSTORE, Pid)) || Pid <- Pids]),
        State == triggered].

%% Return a safe value for the max concurrent replication streams per doc
max_concurrent_reps(Bucket) ->
    {ok, Config} = ns_bucket:get_bucket(?b2l(Bucket)),
    NumVBuckets = proplists:get_value(num_vbuckets, Config, []),
    MaxConcurrentReps = misc:getenv_int("MAX_CONCURRENT_REPS_PER_DOC",
                                        ?MAX_CONCURRENT_REPS_PER_DOC),
    case (MaxConcurrentReps > NumVBuckets) orelse (MaxConcurrentReps < 1) of
        true ->
            ?xdcr_warning("Specified value for MAX_CONCURRENT_REPS_PER_DOC is not "
                          "in the range [1, ~p]. Reverting to default value of ~p.",
                          [NumVBuckets, ?MAX_CONCURRENT_REPS_PER_DOC]),
            ?MAX_CONCURRENT_REPS_PER_DOC;
        false ->
            ?xdcr_info("MAX_CONCURRENT_REPS_PER_DOC set to ~p", [MaxConcurrentReps]),
            MaxConcurrentReps
    end.

