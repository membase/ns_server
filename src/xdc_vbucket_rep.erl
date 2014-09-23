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

%% This module is responsible for replicating an individual vbucket. It gets
%% started and stopped by the xdc_replicator module when the local vbucket maps
%% changes and moves its vb. When the remote vbucket map changes, it receives
%% an error and restarts, thereby reloading it's the remote vb info.

%% It waits for changes to the local vbucket (state=idle), and calculates
%% the amount of work it needs to do. Then it asks the concurrency throttle
%% for a turn to replicate (state=waiting_turn). When it gets it's turn, it
%% replicates a single snapshot of the local vbucket (state=replicating).
%% it waits for the last worker to complete, then enters the idle state
%% and it checks to see if any work is to be done again.

%% While it's idle or waiting_turn, it will update the amount of work it
%% needs to do during the next replication, but it won't while it's
%% replicating. This can be enhanced in the future to update it's count while
%% it has a snapshot.cd bi

%% XDC Replicator Functions
-module(xdc_vbucket_rep).
-behaviour(gen_server).

%% public functions
-export([start_link/6]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-export([format_status/2]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").
-include("xdcr_dcp_streamer.hrl").

%% for ?MC_DATATYPE_COMPRESSED
-include("mc_constants.hrl").

%% imported functions
-import(couch_util, [get_value/2,
                     to_binary/1]).

-record(init_state, {
          rep,
          vb,
          mode,
          init_throttle,
          work_throttle,
          parent}).

start_link(Rep, Vb, InitThrottle, WorkThrottle, Parent, RepMode) ->
    InitState = #init_state{rep = Rep,
                            vb = Vb,
                            mode = RepMode,
                            init_throttle = InitThrottle,
                            work_throttle = WorkThrottle,
                            parent = Parent},
    gen_server:start_link(?MODULE, InitState, []).


%% gen_server behavior callback functions
init(#init_state{init_throttle = InitThrottle,
                 vb = Vb,
                 rep = Rep,
                 parent = Parent} = InitState) ->
    process_flag(trap_exit, true),
    %% signal to self to initialize
    ok = new_concurrency_throttle:send_back_when_can_go(InitThrottle, init),
    ?x_trace(init,
             [{repID, Rep#rep.id},
              {vb, Vb},
              {parent, Parent}]),
    {ok, InitState}.

format_status(Opt, [PDict, State]) ->
    xdc_rep_utils:sanitize_status(Opt, PDict, State).

handle_info({failover_id, FailoverUUID,
             StartSeqno, EndSeqno, StartSnapshot, EndSnapshot},
            State) ->

    ?x_trace(gotFailoverID,
             [{failoverUUUID, FailoverUUID},
              {startSeq, StartSeqno},
              {endSeq, EndSeqno},
              {startSnapshot, StartSnapshot},
              {endSnapshot, EndSnapshot}]),

    NewState = State#rep_state{dcp_failover_uuid = FailoverUUID,
                               last_stream_end_seq = 0,
                               current_through_seq = StartSeqno,
                               current_through_snapshot_seq = StartSnapshot,
                               current_through_snapshot_end_seq = EndSnapshot},

    {noreply, NewState};

handle_info(opaque_mismatch, State) ->
    {stop, {shutdown, opaque_mismatch}, State};

handle_info({updated_highseqno, Seqno}, #rep_state{rep_details = #rep{id = RepId},
                                                   status = #rep_vb_status{vb = Vb}
                                                  } = State) ->
    case ets:lookup(xdcr_stats, {RepId, Vb}) of
        [#xdcr_vb_stats_sample{vbucket_seqno = KnownSeqno}] when KnownSeqno < Seqno ->
            ?xdcr_debug("updating vb ~p seqno from ~p to ~p", [Vb, KnownSeqno, Seqno]),
            ets:update_element(xdcr_stats, {RepId, Vb},
                               {#xdcr_vb_stats_sample.vbucket_seqno, Seqno});
        _ ->
            ok
    end,
    {noreply, State};
handle_info({updated_highseqno, _Seqno}, OtherState) ->
    {noreply, OtherState};

handle_info({stream_end, SnapshotStart, SnapshotEnd, LastSeenSeqno}, State) ->
    ?x_trace(gotStreamEnd,
             [{snapshotStart, SnapshotStart},
              {snapshotEnd, SnapshotEnd},
              {lastSeq, LastSeenSeqno}]),
    {noreply, State#rep_state{last_stream_end_seq = LastSeenSeqno}};

handle_info({'EXIT',_Pid, normal}, St) ->
    {noreply, St};

handle_info({'EXIT',_Pid, Reason}, St) ->
    {stop, Reason, St};

handle_info(init, #init_state{init_throttle = InitThrottle} = InitState) ->
    ?x_trace(gotInitToken, []),
    try
        State = init_replication_state(InitState),
        check_src_db_updated(State),
        {noreply, State}
    catch
        ErrorType:Error ->
            ?xdcr_error("Error initializing vb replicator (~p):~p~n~p",
                        [InitState, {ErrorType,Error}, erlang:get_stacktrace()]),
            {stop, Error, InitState}
    after
        new_concurrency_throttle:is_done(InitThrottle)
    end;

handle_info(wake_me_up,
            #rep_state{status = VbStatus = #rep_vb_status{status = idle,
                                                          vb = Vb},
                       rep_details = #rep{source = SourceBucket, id = RepId},
                       current_through_seq = ThroughSeq,
                       throttle = Throttle,
                       target_name = TgtURI} = St) ->
    TargetNode =  target_uri_to_node(TgtURI),
    ok = new_concurrency_throttle:send_back_when_can_go(Throttle, TargetNode, start_replication),

    SeqnoKey = iolist_to_binary(io_lib:format("vb_~B:high_seqno", [Vb])),
    {ok, StatsValue} =
        ns_memcached:raw_stats(node(), couch_util:to_list(SourceBucket),
                               iolist_to_binary(io_lib:format("vbucket-seqno ~B", [Vb])),
                               fun (K, V, Acc) ->
                                       case K =:= SeqnoKey of
                                           true ->
                                               V;
                                           _ ->
                                               Acc
                                       end
                               end, []),

    VbucketSeq = list_to_integer(binary_to_list(StatsValue)),

    NewChangesLeft = erlang:max(VbucketSeq - ThroughSeq, 0),

    ets:update_element(xdcr_stats, {RepId, Vb}, {#xdcr_vb_stats_sample.vbucket_seqno, VbucketSeq}),

    NewVbStatus = VbStatus#rep_vb_status{status = waiting_turn},

    ?x_trace(gotWakeup, [{newChangesLeft, NewChangesLeft}]),

    {noreply, St#rep_state{status = NewVbStatus}, hibernate};

handle_info(wake_me_up, OtherState) ->
    ?x_trace(gotNOOPWakeup, []),
    {noreply, OtherState};

handle_info(start_replication,
            #rep_state{
               status = #rep_vb_status{status = waiting_turn} = VbStatus} = St) ->

    St1 = St#rep_state{status = VbStatus#rep_vb_status{status = replicating}},
    St2 = update_rep_options(St1),
    bump_stats(St2, {#xdcr_stats_sample.activations, 0}),
    {noreply, start_replication(St2)};

handle_info(return_token_please, State) ->
    ?x_trace(gotReturnTokenPlease, []),
    case State of
        #rep_state{status = RepVBStatus,
                   changes_queue = ChangesQueue} when RepVBStatus#rep_vb_status.status =:= replicating ->
            ?xdcr_debug("changes queue for vb ~p closed due to pause request, "
                        "rep will stop after flushing remaining ~p items in queue",
                        [RepVBStatus#rep_vb_status.vb,
                         couch_work_queue:item_count(ChangesQueue)]),
            ChangesReader = erlang:get(changes_reader),
            {true, is_pid} = {is_pid(ChangesReader), is_pid},
            ?x_trace(sendingPleaseStopToReader, []),
            ChangesReader ! please_stop;
        _ ->
            ok
    end,
    {noreply, State}.


handle_call({report_seq_done,
             GetMetaLatency,
             SetMetaLatency,
             #worker_stat{
                seq = Seq,
                snapshot_start_seq = SnapshotStart,
                snapshot_end_seq = SnapshotEnd,
                worker_item_opt_repd = NumDocsOptRepd,
                worker_item_checked = NumChecked,
                worker_item_replicated = NumWritten,
                worker_data_replicated = WorkerDataReplicated}}, From,
            #rep_state{rep_details = #rep{id = RepId},
                       seqs_in_progress = SeqsInProgress,
                       highest_seq_done = HighestDone,
                       highest_seq_done_snapshot = HighestDoneSnapshot,
                       current_through_seq = ThroughSeq,
                       current_through_snapshot_seq = CurrentSnapshotSeq,
                       current_through_snapshot_end_seq = CurrentSnapshotEndSeq,
                       status = #rep_vb_status{vb = Vb}} = State) ->
    gen_server:reply(From, ok),

    true = (CurrentSnapshotSeq =< SnapshotStart),

    {NewThroughSeq0, NewSeqsInProgress} = case SeqsInProgress of
                                              [Seq | Rest] ->
                                                  {Seq, Rest};
                                              [_ | _] ->
                                                  {ThroughSeq, ordsets:del_element(Seq, SeqsInProgress)}
                                          end,

    {NewHighestDone, NewHighestDoneSnapshot} =
        case Seq > HighestDone of
            true ->
                {Seq, {SnapshotStart, SnapshotEnd}};
            false ->
                {HighestDone, HighestDoneSnapshot}
        end,

    NewThroughSeq = case NewSeqsInProgress of
                        [] ->
                            lists:max([NewThroughSeq0, NewHighestDone]);
                        _ ->
                            NewThroughSeq0
                    end,

    {NewSnapshotSeq, NewSnapshotEndSeq} =
        case NewThroughSeq of
            NewHighestDone ->
                NewHighestDoneSnapshot;
            Seq ->
                {SnapshotStart, SnapshotEnd};
            _ ->
                {CurrentSnapshotSeq, CurrentSnapshotEndSeq}
        end,

    %% check possible inconsistency, and dump warning msgs if purger is ahead of replication
    %% SourceDB = State#rep_state.source,
    %% PurgeSeq = couch_db:get_purge_seq(SourceDB),
    %% BehindPurger =
    %%     case (PurgeSeq >= NewHighestDone) and (State#rep_state.behind_purger == false) of
    %%         true ->
    %%             ?xdcr_error("WARNING! Database delete purger current sequence is ahead of "
    %%                         "replicator sequence for (source: ~p, target: ~p "
    %%                         "that means one or more deletion is lost "
    %%                         "(vb: ~p, purger seq: ~p, repl current seq: ~p).",
    %%                         [(State#rep_state.rep_details)#rep.source,
    %%                          (State#rep_state.rep_details)#rep.target,
    %%                          Vb, PurgeSeq, NewHighestDone]),
    %%             true;
    %%         _ ->
    %%             %% keep old value if repl is not outpaced, or warning msg has been dumped
    %%             State#rep_state.behind_purger
    %%     end,

    ?x_trace(workerReported,
             [{seq, Seq},
              {oldThroughSeq, ThroughSeq},
              {newThroughSeq, NewThroughSeq},
              {workerOptReplicated, NumDocsOptRepd},
              {workerChecked, NumChecked},
              {workerReplicated, NumWritten},
              {workerDataReplicate, WorkerDataReplicated}]),

    ets:update_element(xdcr_stats, {RepId, Vb}, {#xdcr_vb_stats_sample.through_seqno, NewThroughSeq}),

    NewState = State#rep_state{
                 current_through_seq = NewThroughSeq,
                 current_through_snapshot_seq = NewSnapshotSeq,
                 current_through_snapshot_end_seq = NewSnapshotEndSeq,
                 seqs_in_progress = NewSeqsInProgress,
                 highest_seq_done = NewHighestDone,
                 highest_seq_done_snapshot = NewHighestDoneSnapshot
                 %% behind_purger = BehindPurger,
                },

    StatsBatch0 =
        [{#xdcr_stats_sample.data_replicated, WorkerDataReplicated},
         {#xdcr_stats_sample.docs_checked, NumChecked},
         {#xdcr_stats_sample.docs_written, NumWritten},
         {#xdcr_stats_sample.docs_opt_repd, NumDocsOptRepd},
         {#xdcr_stats_sample.worker_batches, 1}],

    MaybeGetMetaBatch = case GetMetaLatency of
                            undefined -> [];
                            _ ->
                                [{#xdcr_stats_sample.get_meta_batches, 1},
                                 {#xdcr_stats_sample.get_meta_latency, GetMetaLatency}]
                        end,
    MaybeSetMetaBatch = case SetMetaLatency of
                            undefined -> [];
                            _ ->
                                [{#xdcr_stats_sample.set_meta_batches, 1},
                                 {#xdcr_stats_sample.set_meta_latency, SetMetaLatency}]
                        end,

    bump_stats(NewState, MaybeGetMetaBatch ++ MaybeSetMetaBatch ++ StatsBatch0),

    {noreply, NewState};

handle_call({worker_done, Pid}, _From,
            #rep_state{workers = Workers, status = VbStatus} = State) ->
    ?x_trace(workerDone, [{workerPid, Pid}]),
    case Workers -- [Pid] of
        Workers ->
            {stop, {unknown_worker_done, Pid}, ok, State};
        [] ->
            %% all workers completed. Now shutdown everything and prepare for
            %% more changes from src

            %% allow another replicator to go
            State2 = replication_turn_is_done(State),
            couch_api_wrap:db_close(State2#rep_state.target),

            update_work_time(State2),

            VbStatus3 = VbStatus#rep_vb_status{status = idle},

            CurrentSnapshotSeq = State2#rep_state.current_through_snapshot_seq,
            CurrentSnapshotEndSeq = State2#rep_state.current_through_snapshot_end_seq,
            LastStreamEndSeq = State#rep_state.last_stream_end_seq,

            %% end of work is definitely at snapshot, so move last
            %% known snapshot to the end. But only if we actually
            %% reached end (xdcr pausing can prevent that)
            {NewSnapshotSeq, NewSnapshotEndSeq} =
                case CurrentSnapshotSeq < LastStreamEndSeq of
                    true ->
                        {LastStreamEndSeq, LastStreamEndSeq};
                    false ->
                        {CurrentSnapshotSeq, CurrentSnapshotEndSeq}
                end,

            %% dump a bunch of stats
            ?x_trace(lastWorkerDone,
                     [{lastCheckpointTime, xdcr_trace_log_formatter:format_ts(State2#rep_state.last_checkpoint_time)},
                      {lastStartTime, xdcr_trace_log_formatter:format_ts(State2#rep_state.rep_start_time)},
                      {throughSeq, State2#rep_state.current_through_seq},
                      {throughSnapshotStart, NewSnapshotSeq},
                      {throughSnapshotEnd, NewSnapshotEndSeq}]),

            %% finally report stats to bucket replicator and tell it that I am idle

            NewState = State2#rep_state{
                         workers = [],
                         status = VbStatus3,
                         target = undefined,
                         current_through_snapshot_seq = NewSnapshotSeq,
                         current_through_snapshot_end_seq = NewSnapshotEndSeq},

            %% cancel the timer since we will start it next time the vb rep waken up
            NewState2 = xdc_vbucket_rep_ckpt:cancel_timer(NewState),

            check_src_db_updated(NewState2),

            % hibernate to reduce memory footprint while idle
            {reply, ok, NewState2, hibernate};
        Workers2 ->
            {reply, ok, State#rep_state{workers = Workers2}}
    end.


handle_cast(checkpoint, #rep_state{status = VbStatus} = State) ->
    Result = case VbStatus#rep_vb_status.status of
                 replicating ->
                     Start = os:timestamp(),
                     case xdc_vbucket_rep_ckpt:do_checkpoint(State) of
                         {ok, _, NewState} ->
                             CommitTime = timer:now_diff(os:timestamp(), Start),
                             bump_stats(State, {#xdcr_stats_sample.commit_time, CommitTime}),
                             NewState2 = NewState#rep_state{timer = xdc_vbucket_rep_ckpt:start_timer(State)},
                             ?x_trace(checkpointedDuringReplication, [{duration, CommitTime}]),
                             {ok, NewState2};
                         {checkpoint_commit_failure, Reason, NewState} ->
                             %% update the failed ckpt stats to bucket replicator
                             Vb = (NewState#rep_state.status)#rep_vb_status.vb,
                             ?xdcr_error("checkpoint commit failure during replication for vb ~p", [Vb]),
                             {stop, {failed_to_checkpoint, Reason}, NewState}
                     end;
                 _ ->
                     %% if get checkpoint when not in replicating state, continue to wait until we
                     %% get our next turn, we'll do the checkpoint at the start of that.
                     NewState = xdc_vbucket_rep_ckpt:cancel_timer(State),
                     {ok, NewState}
             end,

    case Result of
        {ok, NewState3} ->
            {noreply, NewState3};
        {stop, _, _} ->
            Result
    end;


handle_cast({report_error, Err},
            #rep_state{parent = Parent} = State) ->
    %% relay error from child to parent bucket replicator
    gen_server:cast(Parent, {report_error, Err}),
    {noreply, State};

handle_cast({report_seq, Seq, SnapshotStart, SnapshotEnd},
            #rep_state{seqs_in_progress = SeqsInProgress} = State) ->
    NewSeqsInProgress = ordsets:add_element(Seq, SeqsInProgress),
    ?x_trace(workStart, [{seq, Seq},
                         {snapshotStart, SnapshotStart},
                         {snapshotEnd, SnapshotEnd}]),
    {noreply, State#rep_state{seqs_in_progress = NewSeqsInProgress}}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, #init_state{rep = #rep{target = TargetRef}, parent = P, vb = Vb} = InitState) ->
    ?x_trace(terminateInInitState, [{reason, xdcr_trace_log_formatter:format_pp(Reason)}]),
    report_error(Reason, Vb, P),
    ?xdcr_error("Shutting xdcr vb replicator (~p) down without ever successfully initializing: ~p", [InitState, Reason]),
    remote_clusters_info:invalidate_remote_bucket_by_ref(TargetRef),
    ok;

terminate(Reason, State) when Reason == normal orelse Reason == shutdown ->
    ?x_trace(terminateNormal, []),
    terminate_cleanup(State);

terminate({shutdown, Subreason}, #rep_state{
                                    rep_details = #rep{target = TargetRef}
                                   } = State) ->
    ?xdcr_debug("Got semi-clean shutdown. Will invalidate remote cluster info still: ~p", [Subreason]),
    %% an unhandled error happened. Invalidate target vb map cache.
    remote_clusters_info:invalidate_remote_bucket_by_ref(TargetRef),
    ?x_trace(terminateSemiNormal, [{subreason, xdcr_trace_log_formatter:format_pp(Subreason)}]),
    terminate_cleanup(State);

terminate(Reason, #rep_state{
            source_name = Source,
            target_name = Target,
            rep_details = #rep{id = Id, replication_mode = RepMode, target = TargetRef},
            status = #rep_vb_status{vb = Vb} = Status,
            parent = P
           } = State) ->

    ?x_trace(terminate, [{reason, xdcr_trace_log_formatter:format_pp(Reason)}]),

    case RepMode of
        "capi" ->
            ?xdcr_error("Replication (CAPI mode) `~s` (`~s` -> `~s`) failed: ~s",
                        [Id, Source, misc:sanitize_url(Target), to_binary(Reason)]);
        _ ->
            case Reason of
                {{error, {ErrorStat, _ErrKeys}}, _State} ->
                    ?xdcr_error("Replication (XMem mode) `~s` (`~s` -> `~s`) failed."
                                "Error msg from xmem server: ~p."
                                "Please see ns_server debug log for complete state dump.",
                                [Id, Source, misc:sanitize_url(Target), ErrorStat]);
                _ ->
                    ?xdcr_error("Replication (XMem mode) `~s` (`~s` -> `~s`) failed."
                                "Please see ns_server debug log for complete state dump",
                                [Id, Source, misc:sanitize_url(Target)])
            end
    end,
    update_work_time(State#rep_state{status = Status#rep_vb_status{status = idle}}),
    report_error(Reason, Vb, P),
    %% an unhandled error happened. Invalidate target vb map cache.
    remote_clusters_info:invalidate_remote_bucket_by_ref(TargetRef),
    terminate_cleanup(State).


terminate_cleanup(State0) ->
    State = xdc_vbucket_rep_ckpt:cancel_timer(State0),
    Dbs = [State#rep_state.target],
    [catch couch_api_wrap:db_close(Db) || Db <- Dbs, Db /= undefined].


%% internal helper function

report_error(Err, _Vb, _Parent) when Err == normal orelse Err == shutdown ->
    ok;
report_error(_Err, Vb, Parent) ->
    %% return raw erlang time to make it sortable
    RawTime = erlang:localtime(),
    Time = misc:iso_8601_fmt(RawTime),

    String = iolist_to_binary(io_lib:format("~s [Vb Rep] Error replicating vbucket ~p. "
                                            "Please see logs for details.",
                                            [Time, Vb])),
    gen_server:cast(Parent, {report_error, {RawTime, String}}).

replication_turn_is_done(#rep_state{throttle = T} = State) ->
    ?x_trace(turnIsDone, []),
    new_concurrency_throttle:is_done(T),
    State.

update_work_time(#rep_state{status = VbStatus} = State) ->
    %% compute work time since last update the status, note we only compute
    %% the work time if the status is replicating
    WorkTimeMicros = case VbStatus#rep_vb_status.status of
                         replicating ->
                             case State#rep_state.work_start_time of
                                 0 ->
                                     %% timer not initalized yet
                                     0;
                                 _ ->
                                     timer:now_diff(now(), State#rep_state.work_start_time)
                             end;
                         %% if not replicating (idling or waiting for turn), do not count the work time
                         _ ->
                             0
                     end,

    bump_stats(State, {#xdcr_stats_sample.work_time, WorkTimeMicros}),

    State.

init_replication_state(#init_state{rep = Rep,
                                   vb = Vb,
                                   mode = RepMode,
                                   work_throttle = Throttle,
                                   parent = Parent}) ->
    #rep{
          source = Src,
          target = Tgt,
          options = Options
        } = Rep,
    SrcVbDb = xdc_rep_utils:local_couch_uri_for_vbucket(Src, Vb),
    {ok, CurrRemoteBucket} =
        case remote_clusters_info:get_remote_bucket_by_ref(Tgt, false) of
            {ok, RBucket} ->
                {ok, RBucket};
            Error when is_tuple(Error) andalso element(1, Error) =:= error ->
                ?xdcr_error("Error fetching remote bucket: ~p,"
                            "sleep for ~p secs before retry.",
                            [Error, (?XDCR_SLEEP_BEFORE_RETRY)]),
                %% sleep and retry once
                timer:sleep(1000*?XDCR_SLEEP_BEFORE_RETRY),
                remote_clusters_info:get_remote_bucket_by_ref(Tgt, false)
        end,

    TgtURI = hd(dict:fetch(Vb, CurrRemoteBucket#remote_bucket.capi_vbucket_map)),
    CertPEM = CurrRemoteBucket#remote_bucket.cluster_cert,
    TgtDb = xdc_rep_utils:parse_rep_db(TgtURI, [], [{xdcr_cert, CertPEM} | Options]),
    {ok, Target} = couch_api_wrap:db_open(TgtDb, []),

    XMemRemote = case RepMode of
                     "xmem" ->
                         {ok, #remote_node{host = RemoteHostName, memcached_port = Port} = RN, LatestRemoteBucket} =
                             case remote_clusters_info:get_memcached_vbucket_info_by_ref(Tgt, false, Vb) of
                                 {ok, RemoteNode, TgtBucket} ->
                                     {ok, RemoteNode, TgtBucket};
                                 Error2 ->
                                     ?xdcr_error("Error fetching remote memcached vbucket info: ~p"
                                                 "sleep for ~p secs before retry",
                                                 [Error2, (?XDCR_SLEEP_BEFORE_RETRY)]),
                                     timer:sleep(1000*?XDCR_SLEEP_BEFORE_RETRY),
                                     remote_clusters_info:get_memcached_vbucket_info_by_ref(Tgt, false, Vb)
                             end,

                         {ok, {_ClusterUUID, BucketName}} = remote_clusters_info:parse_remote_bucket_reference(Tgt),
                         Password = binary_to_list(LatestRemoteBucket#remote_bucket.password),

                         %% NOTE: we're disabling datatype because as
                         %% of this writing it's unclear if current
                         %% set of datatypes is compatible with
                         %% whatever we will officially support.

                         %% RemoteBucketCaps = LatestRemoteBucket#remote_bucket.bucket_caps,
                         SupportsDatatype = false, %% lists:member(<<"datatype">>, RemoteBucketCaps),

                         ?x_trace(gotRemoteVBucketDetails,
                                  [{bucket, BucketName},
                                   {bucketUUID, LatestRemoteBucket#remote_bucket.uuid},
                                   {host, RemoteHostName},
                                   {port, Port},
                                   {supportsDatatype, SupportsDatatype},
                                   {haveCert, CertPEM =/= undefined},
                                   {sslProxyPort, remote_proxy_port}]),

                         #xdc_rep_xmem_remote{ip = RemoteHostName, port = Port,
                                              bucket = BucketName, vb = Vb,
                                              username = BucketName, password = Password,
                                              options = [{remote_node, RN},
                                                         {remote_proxy_port, RN#remote_node.ssl_proxy_port},
                                                         {supports_datatype, SupportsDatatype},
                                                         {cert, LatestRemoteBucket#remote_bucket.cluster_cert}]};
                     _ ->
                         ?x_trace(gotRemoteVBucketDetails,
                                  [{capiURL, TgtURI},
                                   {bucketUUID, CurrRemoteBucket#remote_bucket.uuid},
                                   {haveCert, CertPEM =/= undefined}]),
                         nil
                 end,

    ApiRequestBase = xdc_vbucket_rep_ckpt:build_request_base(Target,
                                                             CurrRemoteBucket#remote_bucket.name,
                                                             CurrRemoteBucket#remote_bucket.uuid,
                                                             Vb),

    DisableCkptBackwardsCompat = lists:member(<<"xdcrCheckpointing">>, CurrRemoteBucket#remote_bucket.bucket_caps),

    {StartSeq, SnapshotStart, SnapshotEnd, FailoverUUID,
     RemoteVBOpaque} = xdc_vbucket_rep_ckpt:read_validate_checkpoint(Rep, Vb, ApiRequestBase, DisableCkptBackwardsCompat),

    register_vb_stats(Rep#rep.id, Vb, CurrRemoteBucket, Target, RemoteVBOpaque),

    ?log_debug("Inited replication position: ~p",
               [{StartSeq, SnapshotStart, SnapshotEnd, FailoverUUID,
                 RemoteVBOpaque}]),

    ?x_trace(initedSeq,
             [{seq, StartSeq},
              {snapshotStart, SnapshotStart},
              {snapshotEnd, SnapshotEnd},
              {failoverUUUID, FailoverUUID},
              {remoteVBOpaque, {json, RemoteVBOpaque}}]),

    %% check if we are already behind purger
    %% PurgeSeq = couch_db:get_purge_seq(Source),
    %% BehindPurger  =
    %%     case (PurgeSeq > 0) and (PurgeSeq >= StartSeq) of
    %%         true ->
    %%             ?xdcr_error("WARNING! Database delete purger current sequence is ahead "
    %%                         "of replicator starting sequence for (source:~p, target:~p) "
    %%                         "that means one or more deletion is lost "
    %%                         "(vb: ~p, purger seq: ~p, repl start seq: ~p).",
    %%                         [Src, Tgt, Vb, PurgeSeq, StartSeq]),
    %%             true;
    %%         _ ->
    %%             false
    %%     end,

    couch_api_wrap:db_close(Target),

    RepState = #rep_state{
      rep_details = Rep,
      throttle = Throttle,
      parent = Parent,
      source_name = SrcVbDb,
      target_name = TgtURI,
      target = Target,
      remote_vbopaque = RemoteVBOpaque,
      start_seq = StartSeq,
      current_through_seq = StartSeq,
      current_through_snapshot_seq = SnapshotStart,
      current_through_snapshot_end_seq = SnapshotEnd,
      dcp_failover_uuid = FailoverUUID,
      source_cur_seq = StartSeq,
      rep_starttime = httpd_util:rfc1123_date(),
      last_checkpoint_time = os:timestamp(),
      rep_start_time = os:timestamp(),
      %% temporarily initialized to 0, when vb rep gets the token it will
      %% initialize the work start time in start_replication()
      work_start_time = 0,
      behind_purger = false, %% BehindPurger,
      %% XMem not started
      xmem_location = nil,
      xmem_remote = XMemRemote,
      ckpt_api_request_base = ApiRequestBase,
      status = #rep_vb_status{vb = Vb,
                              pid = self()
                              %% init per vb replication stats from checkpoint doc
                              %% total_docs_checked = TotalDocsChecked,
                              %% total_docs_written = TotalDocsWritten,
                              %% total_data_replicated = TotalDataReplicated,
                             }
     },
    XMemRemoteStr = case XMemRemote of
                        nil ->
                            "none";
                        _ ->
                            ?format_msg("(target node: ~s:~p, target bucket: ~s)",
                                        [XMemRemote#xdc_rep_xmem_remote.ip,
                                         XMemRemote#xdc_rep_xmem_remote.port,
                                         XMemRemote#xdc_rep_xmem_remote.bucket])
                    end,
    ?xdcr_debug("vb ~p replication state initialized: (local db: ~p, remote db: ~p, mode: ~p, xmem remote: ~s)",
                [Vb, RepState#rep_state.source_name,
                 misc:sanitize_url(RepState#rep_state.target_name), RepMode, XMemRemoteStr]),
    RepState.

register_vb_stats(Id, Vb, CurrRemoteBucket, Target, RemoteVBOpaque) ->
    R = #xdcr_vb_stats_sample{id_and_vb = {Id, Vb},
                              pid = self(),
                              httpdb = Target,
                              bucket_uuid = CurrRemoteBucket#remote_bucket.uuid,
                              remote_vbopaque = RemoteVBOpaque},
    ets:insert(xdcr_stats, R).

update_rep_options(#rep_state{rep_details =
                                  #rep{id = Id,
                                       options = OldOptions} = Rep} = State) ->
    NewOptions = xdc_settings:get_all_settings_snapshot_by_doc_id(Id),

    case OldOptions =:= NewOptions of
        true ->
            State;
        false ->
            NewRep = Rep#rep{options = NewOptions},
            State#rep_state{rep_details = NewRep}
    end.

start_replication(#rep_state{
                     target_name = OrigTgtURI,
                     dcp_failover_uuid = FailoverUUID,
                     current_through_seq = StartSeq,
                     current_through_snapshot_seq = SnapshotStart,
                     current_through_snapshot_end_seq = SnapshotEnd,
                     last_checkpoint_time = LastCkptTime,
                     status = #rep_vb_status{vb = Vb},
                     rep_details = #rep{id = Id, options = Options, source = SourceBucket, target = TargetRef},
                     xmem_remote = Remote
                    } = State) ->

    WorkStart = now(),

    NumWorkers = get_value(worker_processes, Options),
    BatchSizeItems = get_value(worker_batch_size, Options),

    %% we re-fetch bucket details to get fresh remote cluster certificate
    {TgtDB, TgtURI} =
        case remote_clusters_info:get_remote_bucket_by_ref(TargetRef, false) of
            {ok, CurrRemoteBucket} ->
                TgtURI0 = hd(dict:fetch(Vb, CurrRemoteBucket#remote_bucket.capi_vbucket_map)),
                CertPEM = CurrRemoteBucket#remote_bucket.cluster_cert,
                case Remote of
                    #xdc_rep_xmem_remote{options = XMemRemoteOptions} ->
                        case get_value(cert, XMemRemoteOptions) =:= CertPEM of
                            true -> ok;
                            false ->
                                erlang:exit({cert_mismatch_restart, Id, Vb})
                        end;
                    _ ->
                        ok
                end,
                {xdc_rep_utils:parse_rep_db(TgtURI0, [], [{xdcr_cert, CertPEM} | Options]), TgtURI0};
            Err ->
                ?xdcr_error("Couldn't re-fetch remote bucket info for ~s (original url: ~s): ~p",
                            [TargetRef, misc:sanitize_url(OrigTgtURI), Err]),
                erlang:exit({get_remote_bucket_failed, Err})
        end,
    {ok, Target} = couch_api_wrap:db_open(TgtDB, []),

    {ok, ChangesQueue} = couch_work_queue:new([
                                               {max_items, BatchSizeItems * NumWorkers * 2},
                                               {max_size, 100 * 1024 * NumWorkers}
                                              ]),
    %% This starts the _changes reader process. It adds the changes from
    %% the source db to the ChangesQueue.
    SupportsDatatype =
        case Remote of
            #xdc_rep_xmem_remote{options = XMemRemoteOptions1} ->
                proplists:get_value(supports_datatype, XMemRemoteOptions1);
            _ ->
                false
        end,
    ChangesReader = spawn_changes_reader(SourceBucket, Vb, ChangesQueue,
                                         StartSeq, SnapshotStart, SnapshotEnd, FailoverUUID,
                                         SupportsDatatype),
    erlang:put(changes_reader, ChangesReader),
    %% Changes manager - responsible for dequeing batches from the changes queue
    %% and deliver them to the worker processes.
    ChangesManager = spawn_changes_manager(self(), ChangesQueue, BatchSizeItems),
    %% This starts the worker processes. They ask the changes queue manager for a
    %% a batch of _changes rows to process -> check which revs are missing in the
    %% target, and for the missing ones, it copies them from the source to the target.
    MaxConns = get_value(http_connections, Options),
    OptRepThreshold = get_value(optimistic_replication_threshold, Options),

    %% start xmem server if it has not started
    Vb = (State#rep_state.status)#rep_vb_status.vb,
    XMemLoc = case Remote of
                  nil ->
                      nil;
                  %% xmem replication mode
                  _XMemRemote  ->
                      ConnectionTimeout = get_value(connection_timeout, Options),
                      xdc_vbucket_rep_xmem:make_location(Remote, ConnectionTimeout)
              end,

    bump_stats(State, {#xdcr_stats_sample.activations, 1}),

    BatchSizeKB = get_value(doc_batch_size_kb, Options),

    %% build start option for worker process
    WorkerOption = #rep_worker_option{
      cp = self(), target = Target,
      source_bucket = SourceBucket,
      changes_manager = ChangesManager, max_conns = MaxConns,
      opt_rep_threshold = OptRepThreshold, xmem_location = XMemLoc,
      batch_size = BatchSizeKB * 1024,
      batch_items = BatchSizeItems},

    Workers = lists:map(
                fun(WorkerID) ->
                        WorkerOption2 = WorkerOption#rep_worker_option{worker_id = WorkerID},
                        {ok, WorkerPid} = xdc_vbucket_rep_worker:start_link(WorkerOption2),
                        WorkerPid
                end,
                lists:seq(1, NumWorkers)),

    ?x_trace(startReplication,
             [{batchSizeItems, BatchSizeItems},
              {numWorkers, NumWorkers},
              {seq, StartSeq},
              {snapshotStart, SnapshotStart},
              {snapshotEnd, SnapshotEnd},
              {failoverUUUID, FailoverUUID},
              {supportsDatatype, SupportsDatatype},
              {changesReader, ChangesReader},
              {changesQueue, ChangesQueue},
              {changesManager, ChangesManager},
              {maxConns, MaxConns},
              {optRepThreshold, OptRepThreshold},
              {workers, {json, [xdcr_trace_log_formatter:format_pid(W) || W <- Workers]}}]),

    IntervalSecs = get_value(checkpoint_interval, Options),
    TimeSinceLastCkpt = timer:now_diff(os:timestamp(), LastCkptTime) div 1000000,

    %% check if we need do checkpointing, replicator will crash if checkpoint failure
    State1 = State#rep_state{
               xmem_location = XMemLoc,
               target = Target},

    {Succ, CkptErrReason, NewState} =
        case TimeSinceLastCkpt > IntervalSecs of
            true ->
                ?x_trace(checkpointAtStart,
                         [{intervalSecs, IntervalSecs},
                          {timeSince, TimeSinceLastCkpt}]),
                xdc_vbucket_rep_ckpt:do_checkpoint(State1);
            _ ->
                {not_needed, [], State1}
        end,

    ResultState = NewState#rep_state{
                    changes_queue = ChangesQueue,
                    workers = Workers,
                    target_name = TgtURI,
                    target = Target,
                    timer = xdc_vbucket_rep_ckpt:start_timer(State),
                    work_start_time = WorkStart
                   },

    %% finally crash myself if fail to commit, after posting status to parent
    case Succ of
        not_needed ->
            ok;
        ok ->
            ok;
        checkpoint_commit_failure ->
            ?xdcr_error("checkpoint commit failure at start of replication for vb ~p", [Vb]),
            exit({failed_to_commit_checkpoint, CkptErrReason})
    end,

    ResultState.

spawn_changes_reader(BucketName, Vb, ChangesQueue, StartSeq,
                     SnapshotStart, SnapshotEnd, FailoverUUID,
                     HonorDatatype) ->
    Parent = self(),
    spawn_link(fun() ->
                       read_changes(BucketName, Vb, ChangesQueue, StartSeq,
                                    SnapshotStart, SnapshotEnd, FailoverUUID, Parent,
                                    HonorDatatype)
               end).

read_changes(BucketName, Vb, ChangesQueue, StartSeq,
             SnapshotStart, SnapshotEnd, FailoverUUID, Parent,
             HonorDatatype) ->
    {start_seq, true} = {start_seq, is_integer(StartSeq)},
    {snapshot_start, true} = {snapshot_start, is_integer(SnapshotStart)},
    {snapshot_end, true} = {snapshot_end, is_integer(SnapshotEnd)},
    {failover_uuid, true} = {failover_uuid, is_integer(FailoverUUID)},
    erlang:process_flag(trap_exit, true),
    xdcr_dcp_streamer:stream_vbucket(
      binary_to_list(BucketName), Vb, FailoverUUID,
      StartSeq, SnapshotStart, SnapshotEnd,
      fun (Event, _) ->
              case Event of
                  please_stop ->
                      {stop, []};
                  {failover_id, _FUUID, _, _, _, _} = FidMsg ->
                      Parent ! FidMsg,
                      {ok, []};
                  {stream_end, _, _, _} = Msg ->
                      Parent ! Msg,
                      {stop, []};
                  #dcp_mutation{} = Mutation0 ->
                      Mutation = maybe_clear_datatype(HonorDatatype, Mutation0),
                      couch_work_queue:queue(ChangesQueue, Mutation),
                      {ok, []}
              end
      end, []),

    couch_work_queue:close(ChangesQueue).

maybe_clear_datatype(true, Mutation) ->
    Mutation;
maybe_clear_datatype(false, #dcp_mutation{datatype = DT,
                                          body = Body0} = Mutation) ->
    case (DT band ?MC_DATATYPE_COMPRESSED) =/= 0 of
        true ->
            case snappy:decompress(Body0) of
                {ok, Body} ->
                    Mutation#dcp_mutation{body = Body,
                                          datatype = 0};
                {error, Err} ->
                    ?xdcr_debug("Got invalid snappy data for compressed doc with id: `~s'."
                                " Will assume it's uncompressed. Snappy error: ~p",
                                [Mutation#dcp_mutation.id, Err]),
                    Mutation#dcp_mutation{datatype = 0}
            end;
        _ ->
            Mutation#dcp_mutation{datatype = 0}
    end.

spawn_changes_manager(Parent, ChangesQueue, BatchSize) ->
    spawn_link(fun() ->
                       changes_manager_loop_open(Parent, ChangesQueue, BatchSize)
               end).

changes_manager_loop_open(Parent, ChangesQueue, BatchSize) ->
    receive
        {get_changes, From} ->
            case couch_work_queue:dequeue(ChangesQueue, BatchSize) of
                closed ->
                    ok; % now done!
                {ok, Changes, _Size} ->
                    #dcp_mutation{local_seq = ReportSeq,
                                  snapshot_start_seq = SnapshotStart,
                                  snapshot_end_seq = SnapshotEnd} = lists:last(Changes),
                    ok = gen_server:cast(Parent, {report_seq, ReportSeq, SnapshotStart, SnapshotEnd}),
                    ?x_trace(sendingChanges,
                             [{length, erlang:length(Changes)},
                              {toWorker, From},
                              {lastSeq, ReportSeq},
                              {lastSnapshotStart, SnapshotStart},
                              {lastSnapshotEnd, SnapshotEnd}]),
                    From ! {changes, self(), Changes, ReportSeq, SnapshotStart, SnapshotEnd},
                    changes_manager_loop_open(Parent, ChangesQueue, BatchSize)
            end
    end.

target_uri_to_node(TgtURI) ->
    TargetURI = binary_to_list(TgtURI),
    [_Prefix, NodeDB] = string:tokens(TargetURI, "@"),
    [Node, _Bucket] = string:tokens(NodeDB, "/"),
    Node.

check_src_db_updated(#rep_state{status = #rep_vb_status{status = idle,
                                                        vb = Vb},
                                current_through_snapshot_seq = SnapshotSeq,
                                rep_details = #rep{source = SourceBucket},
                                current_through_seq = Seq,
                                dcp_failover_uuid = U}) ->
    Self = self(),
    case SnapshotSeq =:= Seq of
        false ->
            Self ! wake_me_up;
        _ ->
            ?x_trace(waitingForNotification, []),
            proc_lib:spawn_link(
              fun () ->
                      RV = (catch dcp_notifier:subscribe(couch_util:to_list(SourceBucket),
                                                         Vb, Seq, U)),
                      ?x_trace(gotNotification, [{rv, xdcr_trace_log_formatter:format_pp(RV)}]),
                      case ns_config:read_key_fast(xdcr_anticipatory_delay, 0) of
                          0 ->
                              Self ! wake_me_up;
                          Delay0 ->
                              %% this randomizes delay by about
                              %% 10%. It helps spread wakeup moments
                              %% for vbuckets. It is implemented in
                              %% order to avoid all vbuckets
                              %% "clumping" into about same wakeup
                              %% moments which was observed in
                              %% practice before randomization was
                              %% implemented.
                              Rnd = erlang:phash2(self(), 16384),
                              Noise = (Rnd * Delay0 + (163840 - 1)) div 163840,
                              Delay = Delay0 + Noise,
                              erlang:send_after(Delay, Self, wake_me_up)
                      end
              end)
    end.

bump_stats(#rep_state{rep_details = #rep{id = Id}} = _State, UpdateOps) ->
    ets:update_counter(xdcr_stats, Id, UpdateOps).
