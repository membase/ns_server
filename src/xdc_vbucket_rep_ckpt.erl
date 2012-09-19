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

%% XDC Replicator Checkpoint Functions
-module(xdc_vbucket_rep_ckpt).

%% public functions
-export([start_timer/1, cancel_timer/1]).
-export([do_last_checkpoint/1, do_checkpoint/1]).
-export([source_cur_seq/1]).

-include("xdc_replicator.hrl").

start_timer(_State) ->
    {value, DefaultAfterSecs} = ns_config:search(xdcr_checkpoint_interval),
    AfterSecs = misc:getenv_int("XDCR_CHECKPOINT_INTERVAL", DefaultAfterSecs),
    %% convert to milliseconds
    After = AfterSecs*1000,
    case timer:apply_after(After, gen_server, cast, [self(), checkpoint]) of
        {ok, Ref} ->
            Ref;
        Error ->
            ?xdcr_error("Replicator, error scheduling checkpoint:  ~p", [Error]),
            nil
    end.

cancel_timer(#rep_state{timer = nil} = State) ->
    State;
cancel_timer(#rep_state{timer = Timer} = State) ->
    {ok, cancel} = timer:cancel(Timer),
    State#rep_state{timer = nil}.

do_last_checkpoint(#rep_state{seqs_in_progress = [],
                              highest_seq_done = ?LOWEST_SEQ} = State) ->
    cancel_timer(State);
do_last_checkpoint(#rep_state{seqs_in_progress = [],
                              highest_seq_done = Seq} = State) ->
    case do_checkpoint(State#rep_state{current_through_seq = Seq}) of
        {ok, NewState} ->
            cancel_timer(NewState);
        Error ->
            cancel_timer(State),
            throw(Error)
    end.

do_checkpoint(#rep_state{current_through_seq=Seq, committed_seq=Seq} = State) ->
    SourceCurSeq = source_cur_seq(State),
    NewState = State#rep_state{source_seq = SourceCurSeq},
    {ok, NewState};
do_checkpoint(State) ->
    #rep_state{
               source_name=SourceName,
               target_name=TargetName,
               source = Source,
               target = Target,
               src_master_db = SrcMasterDb,
               tgt_master_db = TgtMasterDb,
               history = OldHistory,
               start_seq = StartSeq,
               current_through_seq = NewSeq,
               source_log = SourceLog,
               target_log = TargetLog,
               rep_starttime = ReplicationStartTime,
               src_starttime = SrcInstanceStartTime,
               tgt_starttime = TgtInstanceStartTime,
               session_id = SessionId,
               status = #rep_vb_status{docs_checked = Checked,
                                     docs_written = Written}
              } = State,
    case commit_to_both(Source, Target) of
        {source_error, Reason} ->
            {checkpoint_commit_failure,
             <<"Failure on source commit: ", (to_binary(Reason))/binary>>};
        {target_error, Reason} ->
            {checkpoint_commit_failure,
             <<"Failure on target commit: ", (to_binary(Reason))/binary>>};
        {SrcInstanceStartTime, TgtInstanceStartTime} ->
            ?xdcr_info("recording a checkpoint for `~s` -> `~s` at source update_seq ~p",
                       [SourceName, TargetName, NewSeq]),
            StartTime = ?l2b(ReplicationStartTime),
            EndTime = ?l2b(httpd_util:rfc1123_date()),
            NewHistoryEntry = {[
                                {<<"session_id">>, SessionId},
                                {<<"start_time">>, StartTime},
                                {<<"end_time">>, EndTime},
                                {<<"start_last_seq">>, StartSeq},
                                {<<"end_last_seq">>, NewSeq},
                                {<<"recorded_seq">>, NewSeq},
                                {<<"docs_checked">>, Checked},
                                {<<"docs_written">>, Written}
                               ]},
            BaseHistory = [
                           {<<"session_id">>, SessionId},
                           {<<"source_last_seq">>, NewSeq},
                           {<<"start_time">>, StartTime},
                           {<<"end_time">>, EndTime},
                           {<<"docs_checked">>, Checked},
                           {<<"docs_written">>, Written}
                         ],
            %% limit history to 50 entries
            NewRepHistory = {
              BaseHistory ++
                  [{<<"history">>, lists:sublist([NewHistoryEntry | OldHistory], 50)}]
             },

            Rand = crypto:rand_uniform(0, 16#100000000),
            RandBin = <<Rand:32/integer>>,
            try
                SrcRev = update_checkpoint(
                           SrcMasterDb, SourceLog#doc{body = NewRepHistory, rev={1, RandBin}}, source),
                TgtRev = update_checkpoint(
                           TgtMasterDb, TargetLog#doc{body = NewRepHistory, rev={1, RandBin}}, target),
                SourceCurSeq = source_cur_seq(State),
                NewState = State#rep_state{
                             source_seq = SourceCurSeq,
                             checkpoint_history = NewRepHistory,
                             committed_seq = NewSeq,
                             source_log = SourceLog#doc{rev=SrcRev},
                             target_log = TargetLog#doc{rev=TgtRev}
                            },
                {ok, NewState}
            catch throw:{checkpoint_commit_failure, _} = Failure ->
                    Failure
            end;
        {SrcInstanceStartTime, _NewTgtInstanceStartTime} ->
            {checkpoint_commit_failure, <<"Target database out of sync. "
                                          "Try to increase max_dbs_open at the target's server.">>};
        {_NewSrcInstanceStartTime, TgtInstanceStartTime} ->
            {checkpoint_commit_failure, <<"Source database out of sync. "
                                          "Try to increase max_dbs_open at the source's server.">>};
        {_NewSrcInstanceStartTime, _NewTgtInstanceStartTime} ->
            {checkpoint_commit_failure, <<"Source and target databases out of "
                                          "sync. Try to increase max_dbs_open at both servers.">>}
    end.


update_checkpoint(Db, Doc, DbType) ->
    try
        update_checkpoint(Db, Doc)
    catch throw:{checkpoint_commit_failure, Reason} ->
            throw({checkpoint_commit_failure,
                   <<"Error updating the ", (to_binary(DbType))/binary,
                     " checkpoint document: ", (to_binary(Reason))/binary>>})
    end.

update_checkpoint(Db, #doc{id = LogId, body = LogBody, rev = Rev} = Doc) ->
    try
        case couch_api_wrap:update_doc(Db, Doc#doc{id = LogId}, [delay_commit]) of
            ok ->
                Rev;
            {error, Reason} ->
                throw({checkpoint_commit_failure, Reason})
        end
    catch throw:conflict ->
            case (catch couch_api_wrap:open_doc(Db, LogId, [ejson_body])) of
                {ok, #doc{body = LogBody, rev = Rev}} ->
                    %% This means that we were able to update successfully the
                    %% checkpoint doc in a previous attempt but we got a connection
                    %% error (timeout for e.g.) before receiving the success response.
                    %% Therefore the request was retried and we got a conflict, as the
                    %% revision we sent is not the current one.
                    %% We confirm this by verifying the doc body we just got is the same
                    %% that we have just sent.
                    Rev;
                _ ->
                    throw({checkpoint_commit_failure, conflict})
            end
    end.

commit_to_both(Source, Target) ->
    %% commit the src async
    ParentPid = self(),
    SrcCommitPid = spawn_link(
                     fun() ->
                             Result = (catch couch_api_wrap:ensure_full_commit(Source)),
                             ParentPid ! {self(), Result}
                     end),

    %% commit tgt sync
    TargetResult = (catch couch_api_wrap:ensure_full_commit(Target)),

    SourceResult = receive
                       {SrcCommitPid, Result} ->
                           unlink(SrcCommitPid),
                           receive {'EXIT', SrcCommitPid, _} -> ok after 0 -> ok end,
                           Result;
                       {'EXIT', SrcCommitPid, Reason} ->
                           {error, Reason}
                   end,
    case TargetResult of
        {ok, TargetStartTime} ->
            case SourceResult of
                {ok, SourceStartTime} ->
                    {SourceStartTime, TargetStartTime};
                SourceError ->
                    {source_error, SourceError}
            end;
        TargetError ->
            {target_error, TargetError}
    end.


source_cur_seq(#rep_state{source = #db{} = Db, source_seq = Seq}) ->
    {ok, Info} = couch_api_wrap:get_db_info(Db),
    get_value(<<"update_seq">>, Info, Seq);

source_cur_seq(#rep_state{source_seq = Seq} = State) ->
    ?xdcr_debug("unknown source in state: ~p", [State]),
    Seq.
