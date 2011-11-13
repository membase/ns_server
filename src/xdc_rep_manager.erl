%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

%
% The XDC Replication Manager (XRM) manages vbucket replication to remote data
% centers. Each instance of XRM running on a node is responsible for only
% replicating the node's active vbuckets. Individual vbucket replications are
% delegated to CouchDB's Replication Manager (CRM) and are controlled by
% adding/deleting replication documents to the _replicator db.
%
% A typical XDC replication document will look as follows:
% {
%   "_id" : "my_xdc_rep",
%   "type" : "xdc",
%   "source" : "bucket0",
%   "target" : "http://uid:pwd@10.1.6.190:8091/pools/default/buckets/bucket0",
%   "continuous" : true
% }
%
% After an XDC replication is triggered, all info and state pertaining to it
% will be stored in a document with the following structure. The doc's id will
% be derived from the id of the corresponding replication doc by appending
% "_info" to it:
% {
%   "_id" : "my_xdc_rep_info_6d6b46f7065e8600955f479376000b3a",
%   "node" : "6d6b46f7065e8600955f479376000b3a",
%   "replication_doc_id" : "my_xdc_rep",
%   "replication_id" : "c0ebe9256695ff083347cbf95f93e280",
%   "source" : "",
%   "target" : "",
%   "_replication_state" : "triggered",
%   "_replication_state_time" : "2011-10-31T17:33:04-07:00",
%   "replication_state_vb_1" : "triggered",
%   "replication_state_vb_3" : "completed",
%   "replication_state_vb_5" : "triggered"
% }
%
% The XRM maintains local state about all in-progress replications and
% comprises of the following data structures:
% XSTORE: An ETS set of {XDocId, XRep, TriggeredVbs, UntriggeredVbs} tuples
%         XDocId: Id of a user created XDC replication document
%         XRep: The parsed #rep record for the document
%         TriggeredVbs: Vbuckets whose replication was successfully triggered
%         UntriggeredVbs: Vbuckets whose replication could not be triggered.
%                         These are periodically retried.
%
% X2CSTORE: An ETS bag of {XDocId, CRepPid} tuples
%           CRepPid: Pid of the Couch process responsible for an individual
%                    vbucket replication
%
% CSTORE: An ETS set of {CRepPid, CRep, Vb, State, Wait}
%         CRep: The parsed #rep record for the couch replication
%         Vb: The vbucket id being replicated
%         State: Couch replication state (triggered/completed/error)
%         Wait: The amount of time to wait before retrying replication
%

-module(xdc_rep_manager).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("couch_db.hrl").
-include("couch_replicator.hrl").
-include("couch_js_functions.hrl").
-include("ns_common.hrl").
-include("replication_infos_ddoc.hrl").

-import(couch_util, [
    get_value/2,
    get_value/3,
    to_binary/1
]).

-define(INITIAL_WAIT, 2). % seconds
-define(RETRY_INTERVAL, 60). % seconds

-define(XSTORE, xdc_rep_info_store).
-define(X2CSTORE, xdc_docid_to_couch_rep_pid_store).
-define(CSTORE, couch_rep_info_store).

% FIXME: Creation of this table is a short term fix for the problem of the tight
% coupling between the couch replication manager and couch replicator. Couch
% replicator calls functions in couch replication manager that attempt to lookup
% state in this table, the absence of which causes it to crash. A better
% abstraction of the couch replicator interface will solve this problem.
-define(REP_TO_STATE, couch_rep_id_to_rep_state).

% Record to store and track changes to the _replicator db
-record(rep_db_state, {
    changes_feed_loop = nil,
    rep_db_name = nil,
    db_notifier = nil
}).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init(_) ->
    process_flag(trap_exit, true),
    Server = self(),
    ?XSTORE = ets:new(?XSTORE, [named_table, set, public]),
    ?X2CSTORE = ets:new(?X2CSTORE, [named_table, bag, public]),
    ?CSTORE = ets:new(?CSTORE, [named_table, set, public]),

    ?REP_TO_STATE = ets:new(?REP_TO_STATE, [named_table, set, protected]),

    ok = couch_config:register(
        fun("replicator", "db", NewName) ->
            ok = gen_server:cast(Server, {rep_db_changed, ?l2b(NewName)})
        end
    ),

    % Subscribe to bucket map changes due to rebalance and failover operations
    % at the source
    NsConfigEventsHandler = fun ({buckets, _} = Evt, _Acc) ->
                                    Server ! Evt;
                                (_, Acc) ->
                                    Acc
                            end,
    ns_pubsub:subscribe(ns_config_events, NsConfigEventsHandler, []),

    % Periodically check whether any Couch replications have failed due to
    % errors and, if so, restart them. Among other reasons, Couch replications
    % may fail due to rebalance and failover operations at the destination.
    % Checking periodically in this manner allows us to batch several failed
    % replications together and only read the destination vbucket map once
    % before retrying all of them.
    {ok, _Tref} = timer:send_interval(?RETRY_INTERVAL * 1000,
                                      retry_failed_couch_replications),

    <<"_replicator">> = ?l2b(couch_config:get("replicator", "db",
                                              "_replicator")),

    maybe_create_replication_info_ddoc(),

    {Loop, <<"_replicator">> = RepDbName} =
        couch_replication_manager:changes_feed_loop(),
    {ok, #rep_db_state{
        changes_feed_loop = Loop,
        rep_db_name = RepDbName,
        db_notifier = couch_replication_manager:db_update_notifier()
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
            {ok, _Rev} = couch_db:update_doc(DB, DDoc, [])
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
        couch_replication_manager:update_rep_doc(
            xdc_rep_utils:info_doc_id(DocId),
            [{<<"_replication_state">>, <<"error">>}]),
        ?log_error("~s: xdc replication error: ~p~n~p",
                   [DocId, Error, erlang:get_stacktrace()]),
        State
    end,
    {reply, ok, State};


handle_call(Msg, From, State) ->
    ?log_error("replication manager received unexpected call ~p from ~p",
        [Msg, From]),
    {stop, {error, {unexpected_call, Msg}}, State}.


handle_cast({rep_db_changed, NewName},
            #rep_db_state{rep_db_name = NewName} = State) ->
    {noreply, State};


handle_cast({rep_db_changed, _NewName}, State) ->
    {noreply, restart(State)};


handle_cast({rep_db_created, NewName},
            #rep_db_state{rep_db_name = NewName} = State) ->
    {noreply, State};


handle_cast({rep_db_created, _NewName}, State) ->
    {noreply, restart(State)};


handle_cast(Msg, State) ->
    ?log_error("replication manager received unexpected cast ~p", [Msg]),
    {stop, {error, {unexpected_cast, Msg}}, State}.

consume_all_buckets_changes(Buckets) ->
    receive
        {buckets, NewerBuckets} ->
            consume_all_buckets_changes(NewerBuckets)
    after 0 ->
            Buckets
    end.

handle_info({buckets, Buckets0}, State) ->
    % The source vbucket map changed
    Buckets = consume_all_buckets_changes(Buckets0),
    maybe_adjust_all_replications(proplists:get_value(configs, Buckets)),
    {noreply, State};


handle_info(retry_failed_couch_replications, State) ->
    _NumMsgs = misc:flush(retry_failed_couch_replications),
    maybe_retry_all_couch_replications(),
    {noreply, State};


handle_info({'EXIT', From, normal},
            #rep_db_state{changes_feed_loop = From} = State) ->
    % replicator DB deleted
    {noreply, State#rep_db_state{changes_feed_loop = nil, rep_db_name = nil}};


handle_info({'EXIT', From, Reason},
            #rep_db_state{db_notifier = From} = State) ->
    ?log_error("database update notifier died. Reason: ~p", [Reason]),
    {stop, {db_update_notifier_died, Reason}, State};


handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    case ets:member(?CSTORE, Pid) of
    true ->
        % A message from one of the couch_replicator processes
        [XDocId] = lists:flatten(ets:match(?X2CSTORE, {'$1', Pid})),
        Vb = ets:lookup_element(?CSTORE, Pid, 3),
        case Reason of
            normal ->
                % Couch replication completed normally
                couch_replication_completed(XDocId, Pid, Vb);
            _ ->
                % Couch replication failed due to an error. Update the state
                % in CSTORE so that it may be picked up the next time
                % maybe_retry_all_couch_replications() is run by the timer
                % module.
                true = ets:update_element(?CSTORE, Pid, {4, error}),
                couch_replication_manager:update_rep_doc(
                    xdc_rep_utils:info_doc_id(XDocId),
                    [{?l2b("replication_state_vb_" ++ ?i2l(Vb)), <<"error">>},
                     {<<"_replication_state">>, <<"error">>}]),
                ?log_info("~s: replication of vbucket ~p failed due to reason: "
                          "~p", [XDocId, Vb, Reason])
        end;
    false ->
        % Ignore messages regarding Pids not found in the CSTORE. These messages
        % may come from either Couch replications that were explicitly cancelled
        % (which means that their CSTORE state has already been cleaned up) or
        % a db monitor created by the Couch replicator.
        ok
    end,
    {noreply, State};


handle_info(Msg, State) ->
    % Ignore any other messages but log them
    ?log_info("ignoring unexpected message: ~p", [Msg]),
    {noreply, State}.


terminate(_Reason, State) ->
    #rep_db_state{
        db_notifier = DbNotifier
    } = State,
    cancel_all_xdc_replications(),
    true = ets:delete(?CSTORE),
    true = ets:delete(?X2CSTORE),
    true = ets:delete(?XSTORE),
    couch_db_update_notifier:stop(DbNotifier).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


restart(State) ->
    cancel_all_xdc_replications(),
    {NewLoop, NewRepDbName} = couch_replication_manager:changes_feed_loop(),
    State#rep_db_state{
        changes_feed_loop = NewLoop,
        rep_db_name = NewRepDbName
    }.


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


%
% XDC specific functions
%

process_xdc_update(XDocBody, RepDbName) ->
    {XDocProps} = XDocBody,
    XDocId = get_value(<<"_id">>, XDocProps),
    case get_xdc_replication_state(XDocId, RepDbName) of
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
    #rep{id = {XBaseId, _Ext} = XRepId} = XRep = parse_xdc_rep_doc(XDocBody),
    case lists:flatten(ets:match(?XSTORE, {'$1', #rep{id = XRepId}})) of
    [] ->
        % A new XDC replication document.
        ?log_info("~s: triggering xdc replication", [XDocId]),
        start_xdc_replication(XRep, RepDbName, XDocBody);
    [XDocId] ->
        % An XDC replication document previously seen. Ignore.
        ?log_info("~s: ignoring doc previously seen", [XDocId]),
        ok;
    [OtherDocId] ->
        % A new XDC replication document specifying a previous replication.
        % Ignore but let  the user know.
        ?log_info("~s: xdc replication was already triggered by doc ~s",
                  [XDocId, OtherDocId]),
        couch_replication_manager:maybe_tag_rep_doc(XDocId, XDocBody,
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
        ?log_error("~s: source and target buckets not found", [XDocId]),
        true = ets:insert(?XSTORE, {XDocId, XRep, [], []}),
        {error, not_present};
    {not_present, _} ->
        ?log_error("~s: source bucket not found", [XDocId]),
        true = ets:insert(?XSTORE, {XDocId, XRep, [], []}),
        {error, not_present};
    {_, not_present} ->
        ?log_error("~s: target bucket not found", [XDocId]),
        true = ets:insert(?XSTORE, {XDocId, XRep, [], []}),
        {error, not_present};
    {{ok, SrcBucketConfig}, {ok, {TgtVbMap, TgtNodes}}} ->
        MyVbs = xdc_rep_utils:my_active_vbuckets(SrcBucketConfig),
        {TriggeredVbs, UntriggeredVbs} = start_vbucket_replications(
            XDocId, SrcBucket, TgtVbMap, TgtNodes, MyVbs, 0),
        true = ets:insert(?XSTORE, {XDocId, XRep, TriggeredVbs,
                                    UntriggeredVbs}),
        create_xdc_rep_info_doc(XDocId, XRepId, TriggeredVbs, UntriggeredVbs,
                                RepDbName, XDocBody),
        ok
    end.


cancel_all_xdc_replications() ->
    ?log_info("cancelling all xdc replications"),
    ets:foldl(
        fun(XDocId, _Ok) ->
            maybe_cancel_xdc_replication(XDocId)
        end,
        ok, ?XSTORE).


maybe_cancel_xdc_replication(XDocId) ->
    case ets:lookup(?XSTORE, XDocId) of
    [] ->
        % Ignore non xdc type docs such as info docs, etc.
        ok;
    _ ->
        CRepPids =
            try
                ets:lookup_element(?X2CSTORE, XDocId, 2)
            catch
            error:badarg ->
                []
            end,

        ?log_info("~s: cancelling xdc replication", [XDocId]),
        lists:foreach(
            fun(CRepPid) ->
                cancel_couch_replication(XDocId, CRepPid)
            end,
            CRepPids),
        true = ets:delete(?XSTORE, XDocId),
        ok
    end.


maybe_adjust_all_replications(BucketConfigs) ->
    lists:foreach(
        fun([XDocId,
             #rep{source = SrcBucket,
                  target = {_, TgtBucket, _, _, _, _, _, _, _, _}},
             PrevTriggeredVbs,
             PrevUntriggeredVbs]) ->
            SrcBucketConfig =
                proplists:get_value(?b2l(SrcBucket), BucketConfigs),
            CurrVbs = xdc_rep_utils:my_active_vbuckets(SrcBucketConfig),
            maybe_adjust_xdc_replication(
                XDocId, SrcBucket, TgtBucket, PrevTriggeredVbs,
                PrevUntriggeredVbs, CurrVbs)
        end,
        ets:match(?XSTORE, {'$1', '$2', '$3', '$4'})).


maybe_adjust_xdc_replication(XDocId, SrcBucket, TgtBucket, PrevTriggeredVbs,
                             PrevUntriggeredVbs, CurrVbs) ->
    PrevVbs = PrevTriggeredVbs ++ PrevUntriggeredVbs,
    {AcquiredVbs, LostVbs} = xdc_rep_utils:lists_difference(CurrVbs, PrevVbs),

    % Start Couch replications for the newly acquired vbuckets
    {ok, {TgtVbMap, TgtNodes}} =
        xdc_rep_utils:remote_vbucketmap_nodelist(TgtBucket),
    {TriggeredVbs1, UntriggeredVbs1} = start_vbucket_replications(
        XDocId, SrcBucket, TgtVbMap, TgtNodes, AcquiredVbs, 0),

    % Add entries for the new Couch replications to the replication info doc
    couch_replication_manager:update_rep_doc(
        xdc_rep_utils:info_doc_id(XDocId),
        xdc_rep_utils:vb_rep_state_list(TriggeredVbs1, <<"triggered">>)),

    % Cancel Couch replications for the lost vbuckets
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

    % Mark entries for the cancelled Couch replications in the replication
    % info doc as "cancelled"
    couch_replication_manager:update_rep_doc(
        xdc_rep_utils:info_doc_id(XDocId),
        xdc_rep_utils:vb_rep_state_list(LostVbs, <<"cancelled">>)),

    % Update XSTORE with the current active vbuckets list
    CurrTriggeredVbs = CurrVbs -- (PrevUntriggeredVbs ++ UntriggeredVbs1),
    CurrUntriggeredVbs = CurrVbs -- CurrTriggeredVbs,
    true = ets:update_element(?XSTORE, XDocId,
                              [{3, CurrTriggeredVbs}, {4, CurrUntriggeredVbs}]).


% Given a list of vbuckets, this function attempts to trigger Couch replication
% for each vbucket using the provided parameters. The lists of vbuckets for
% which trigger was successful and for which it failed, respectively, are
% returned as a tuple.
start_vbucket_replications(XDocId, SrcBucket, TgtVbMap, TgtNodes, VbList,
                           Wait) ->
    lists:foldl(
        fun(Vb, {TriggeredVbs, UntriggeredVbs}) ->
            SrcURI = xdc_rep_utils:local_couch_uri_for_vbucket(
                SrcBucket, Vb),
            TgtURI = xdc_rep_utils:remote_couch_uri_for_vbucket(
                TgtVbMap, TgtNodes, Vb),
            case start_couch_replication(SrcURI, TgtURI, Vb, XDocId, Wait) of
            {ok, _Res} ->
                {[Vb | TriggeredVbs], UntriggeredVbs};
            _Error ->
                {TriggeredVbs, [Vb | UntriggeredVbs]}
            end
        end,
        {[], []}, VbList).


%
% Couch specific functions
%

start_couch_replication(SrcCouchURI, TgtCouchURI, Vb, XDocId, Wait) ->
    % Until scheduled XDC replication support is added, this function will
    % trigger continuous replication by default at the Couch level.
    {ok, CRep} =
        couch_replicator_utils:parse_rep_doc(
            {[{<<"source">>, SrcCouchURI},
              {<<"target">>, TgtCouchURI},
              {<<"worker_processes">>, 1},
              {<<"http_connections">>, 10},
              {<<"continuous">>, true}
             ]},
            #user_ctx{roles = [<<"_admin">>]}),

    ok = timer:sleep(Wait * 1000),
    case couch_replicator:async_replicate(CRep) of
    {ok, CRepPid} = Result ->
        erlang:monitor(process, CRepPid),
        CRepState = triggered,
        true = ets:insert(?CSTORE, {CRepPid, CRep, Vb, CRepState, Wait}),
        true = ets:insert(?X2CSTORE, {XDocId, CRepPid}),
        ?log_info("~s: triggered replication for vbucket ~p", [XDocId, Vb]),
        Result;
    Error ->
        ?log_info("~s: triggering of replication for vbucket ~p failed due to: "
                  "~p", [XDocId, Vb, Error]),
        Error
    end.


cancel_couch_replication(XDocId, CRepPid) ->
    [CRep, Vb] =
        lists:flatten(ets:match(?CSTORE, {CRepPid, '$1', '$2', '_', '_'})),

    case couch_replicator:cancel_replication(CRep#rep.id) of
    {ok, _Res} ->
        ?log_info("~s: cancelled replication for vbucket ~p", [XDocId, Vb]);
    Error ->
        ?log_info("~s: cancellation of replication for vbucket ~p failed due "
                  "to: ~p", [XDocId, Vb, Error])
    end,

    true = ets:delete(?CSTORE, CRepPid),
    true = ets:delete_object(?X2CSTORE, {XDocId, CRepPid}),
    ok.


maybe_retry_all_couch_replications() ->
    lists:foreach(
        fun([XDocId,
             #rep{source = SrcBucket,
                  target = {_, TgtBucket, _, _, _, _, _, _, _, _}},
             TriggeredVbs, UntriggeredVbs]) ->

            FailedCouchReps = failed_couch_replications(XDocId),
            case {FailedCouchReps, UntriggeredVbs} of
            {[], []} ->
                ?log_info("~s: no failed vbucket replications found", [XDocId]);
            {_, _} ->
                % Reread the target vbucket map once before retrying all reps
                {ok, {TgtVbMap, TgtNodes} = TgtVbInfo} =
                    xdc_rep_utils:remote_vbucketmap_nodelist(TgtBucket),

                % Retry couch replications that failed after they were triggered
                lists:foreach(
                    fun(FailedCouchRep) ->
                        retry_couch_replication(XDocId, SrcBucket, TgtVbInfo,
                                                FailedCouchRep)
                    end,
                    FailedCouchReps),

                % Retry couch replications that did not trigger at all
                {TriggeredVbs1, UntriggeredVbs1} = start_vbucket_replications(
                    XDocId, SrcBucket, TgtVbMap, TgtNodes, UntriggeredVbs, 0),
                true = ets:update_element(
                    ?XSTORE, XDocId, [{3, (TriggeredVbs ++ TriggeredVbs1)},
                                      {4, UntriggeredVbs1}])
            end
        end,
        ets:match(?XSTORE, {'$1', '$2', '$3', '$4'})).


retry_couch_replication(XDocId,
                        SrcBucket,
                        {TgtVbMap, TgtNodes},
                        {CRepPid, Vb, Wait}) ->
    cancel_couch_replication(XDocId, CRepPid),

    NewWait = erlang:max(?INITIAL_WAIT, trunc(Wait * 2)),
    SrcURI = xdc_rep_utils:local_couch_uri_for_vbucket(SrcBucket, Vb),
    TgtURI = xdc_rep_utils:remote_couch_uri_for_vbucket(TgtVbMap, TgtNodes, Vb),
    ?log_info("~s: will retry replication for vbucket ~p after ~p seconds",
              [XDocId, Vb, NewWait]),
    start_couch_replication(SrcURI, TgtURI, Vb, XDocId, NewWait),
    ok.


couch_replication_completed(XDocId, CRepPid, Vb) ->
    true = ets:delete(?CSTORE, CRepPid),
    true = ets:delete_object(?X2CSTORE, {XDocId, CRepPid}),
    ?log_info("~s: replication of vbucket ~p completed", [XDocId, Vb]),

    case ets:lookup(?X2CSTORE, XDocId) of
    [] ->
        % All couch replications for this XDocId have completed.
        true = ets:delete(?XSTORE, XDocId),
        couch_replication_manager:update_rep_doc(
            xdc_rep_utils:info_doc_id(XDocId),
            [{?l2b("replication_state_vb_" ++ ?i2l(Vb)), <<"completed">>},
             {<<"_replication_state">>, <<"completed">>}]),
        ?log_info("~s: replication of all vbuckets completed", [XDocId]);
    _ ->
        couch_replication_manager:update_rep_doc(
            xdc_rep_utils:info_doc_id(XDocId),
            [{?l2b("replication_state_vb_" ++ ?i2l(Vb)), <<"completed">>}])
    end.


failed_couch_replications(XDocId) ->
    % For the given XDocId:
    % 1. Lookup all CRepPids in X2CSTORE.
    % 2. For each CRepPid, lookup its record in CSTORE.
    % 3. Only select records whose State attribute equals 'error'.
    % 4. Filter out CRep and State in the final output and just return the
    %    CRepPid, Vb and Wait attributes.
    Pids =
        try
            ets:lookup_element(?X2CSTORE, XDocId, 2)
        catch
        error:badarg ->
            []
        end,
    [{CRepPid, Vb, Wait} ||
        {CRepPid, _CRep, Vb, State, Wait} <-
            lists:flatten([(ets:lookup(?CSTORE, Pid)) || Pid <- Pids]),
        State == error].


%
% XDC replication and replication info document related functions
%

create_xdc_rep_info_doc(XDocId, {Base, Ext}, TriggeredVbs, UntriggeredVbs,
                        RepDbName, XDocBody) ->
    IDocId = xdc_rep_utils:info_doc_id(XDocId),
    UserCtx = #user_ctx{roles = [<<"_admin">>, <<"_replicator">>]},
    {ok, RepDb} = couch_db:open(RepDbName, [sys_db, {user_ctx, UserCtx}]),

    TriggeredVbStates = xdc_rep_utils:vb_rep_state_list(
        TriggeredVbs, <<"triggered">>),
    UntriggeredVbStates =  xdc_rep_utils:vb_rep_state_list(
        UntriggeredVbs, <<"undefined">>),
    AllVbStates = TriggeredVbStates ++ UntriggeredVbStates,

    Body = {[
             {<<"node">>, xdc_rep_utils:node_uuid()},
             {<<"replication_doc_id">>, XDocId},
             {<<"replication_id">>, ?l2b(Base ++ Ext)},
             {<<"replication_fields">>, XDocBody},
             {<<"source">>, <<"">>},
             {<<"target">>, <<"">>} |
             AllVbStates
            ]},

    case couch_db:open_doc(RepDb, IDocId, [ejson_body]) of
    {ok, LatestIDoc} ->
        couch_db:update_doc(RepDb, LatestIDoc#doc{body = Body}, []);
    _ ->
        couch_db:update_doc(RepDb, #doc{id = IDocId, body = Body}, [])
    end,

    case UntriggeredVbs of
    [] ->
        couch_replication_manager:update_rep_doc(
            IDocId, [{<<"_replication_state">>, <<"triggered">>}]);
    _ ->
        couch_replication_manager:update_rep_doc(
            IDocId, [{<<"_replication_state">>, <<"error">>}])
    end,
    couch_db:close(RepDb),

    ?log_info("~s: created replication info doc ~s", [XDocId, IDocId]),
    ok.


get_xdc_replication_state(XDocId, RepDbName) ->
    {ok, RepDb} = couch_db:open(RepDbName, []),
    RepState =
        case couch_db:open_doc(RepDb, xdc_rep_utils:info_doc_id(XDocId),
                               [ejson_body]) of
        {ok, #doc{body = {IDocBody}}} ->
            get_value(<<"_replication_state">>, IDocBody);
        _ ->
            undefined
        end,
    couch_db:close(RepDb),
    RepState.


parse_xdc_rep_doc(RepDoc) ->
    is_valid_xdc_rep_doc(RepDoc),
    {ok, Rep} = try
        couch_replicator_utils:parse_rep_doc(RepDoc, #user_ctx{})
    catch
    throw:{error, Reason} ->
        throw({bad_rep_doc, Reason});
    Tag:Err ->
        throw({bad_rep_doc, to_binary({Tag, Err})})
    end,
    Rep.


% FIXME: Add useful sanity checks to ensure we have a valid replication doc
is_valid_xdc_rep_doc(_RepDoc) ->
    true.
