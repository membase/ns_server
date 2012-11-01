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
-export([start_link/5]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").

-record(init_state, {
          rep,
          vb,
          init_throttle,
          work_throttle,
          parent}).

start_link(Rep, Vb, InitThrottle, WorkThrottle, Parent) ->
    InitState = #init_state{rep = Rep,
                            vb = Vb,
                            init_throttle = InitThrottle,
                            work_throttle = WorkThrottle,
                            parent = Parent},
    gen_server:start_link(?MODULE, InitState, []).


%% gen_server behavior callback functions
init(#init_state{init_throttle = InitThrottle} = InitState) ->
    process_flag(trap_exit, true),
    %% signal to self to initialize
    ok = concurrency_throttle:send_back_when_can_go(InitThrottle, init),
    {ok, InitState}.

handle_info({'EXIT',_Pid, normal}, St) ->
    {noreply, St};

handle_info({'EXIT',_Pid, Reason}, St) ->
    {stop, Reason, St};

handle_info(init, #init_state{init_throttle = InitThrottle} = InitState) ->
    try
        State = init_replication_state(InitState),
        self() ! src_db_updated, % signal to self to check for changes
        {noreply, update_status_to_parent(State)}
    catch
        ErrorType:Error ->
            ?xdcr_error("Error initializing vb replicator (~p):~p", [InitState, {ErrorType,Error}]),
            {stop, Error, InitState}
    after
        concurrency_throttle:is_done(InitThrottle)
    end;

handle_info(src_db_updated,
            #rep_state{status = #rep_vb_status{status = idle}} = St) ->
    misc:flush(src_db_updated),
    case update_number_of_changes(St) of
        #rep_state{status = #rep_vb_status{num_changes_left = 0}} = St2 ->
            {noreply, St2};
        #rep_state{status =VbStatus, throttle = Throttle, target_name = TgtURI} = St2 ->
            #rep_vb_status{vb = Vb} = VbStatus,
            TargetNode =  target_uri_to_node(TgtURI),
            ?xdcr_debug("ask for token for rep of vb: ~p to target node: ~p", [Vb, TargetNode]),
            ok = concurrency_throttle:send_back_when_can_go(Throttle, TargetNode, start_replication),
            {noreply, update_status_to_parent(St2#rep_state{status = VbStatus#rep_vb_status{status = waiting_turn}})}
    end;

handle_info(src_db_updated,
            #rep_state{status = #rep_vb_status{status = waiting_turn}} = St) ->
    misc:flush(src_db_updated),
    {noreply, update_status_to_parent(update_number_of_changes(St))};

handle_info(src_db_updated, #rep_state{status = #rep_vb_status{status = replicating}} = St) ->
    %% we ignore this message when replicating, because it's difficult to
    %% compute accurately while actively replicating.
    %% When done replicating, we will check for new changes always.
    misc:flush(src_db_updated),
    {noreply, St};

handle_info(start_replication, #rep_state{throttle = Throttle,
                                          status = #rep_vb_status{vb = Vb, status = waiting_turn} = VbStatus} = St) ->

    ?xdcr_debug("get start-replication token for vb ~p from throttle (pid: ~p)", [Vb, Throttle]),
    {noreply, start_replication(St#rep_state{status = VbStatus#rep_vb_status{status = replicating}})}.

handle_call({report_seq_done, Seq, NumChecked, NumWritten, DataReplicated}, From,
            #rep_state{seqs_in_progress = SeqsInProgress,
                       highest_seq_done = HighestDone,
                       current_through_seq = ThroughSeq,
                       status = #rep_vb_status{num_changes_left = ChangesLeft,
                                               docs_checked = TotalChecked,
                                               docs_written = TotalWritten,
                                               data_replicated = TotalDataReplicated,
                                               vb = Vb} = VbStatus} = State) ->
    gen_server:reply(From, ok),
    {NewThroughSeq0, NewSeqsInProgress} = case SeqsInProgress of
                                              [Seq | Rest] ->
                                                  {Seq, Rest};
                                              [_ | _] ->
                                                  {ThroughSeq, ordsets:del_element(Seq, SeqsInProgress)}
                                          end,
    NewHighestDone = lists:max([HighestDone, Seq]),
    NewThroughSeq = case NewSeqsInProgress of
                        [] ->
                            lists:max([NewThroughSeq0, NewHighestDone]);
                        _ ->
                            NewThroughSeq0
                    end,
    ?xdcr_debug("Replicator of vbucket ~p: worker reported seq ~p, through seq was ~p, "
                "new through seq is ~p, highest seq done was ~p, "
                "new highest seq done is ~p~n"
                "Seqs in progress were: ~p~nSeqs in progress are now: ~p"
                "(total docs checked: ~p, total docs written: ~p)",
                [Vb, Seq, ThroughSeq, NewThroughSeq, HighestDone,
                 NewHighestDone, SeqsInProgress, NewSeqsInProgress,
                 TotalChecked, TotalWritten]),
    SourceCurSeq = xdc_vbucket_rep_ckpt:source_cur_seq(State),

    %% get stats
    {ChangesQueueSize, ChangesQueueDocs} = get_changes_queue_stats(State),

    NewState = State#rep_state{
                 current_through_seq = NewThroughSeq,
                 seqs_in_progress = NewSeqsInProgress,
                 highest_seq_done = NewHighestDone,
                 source_seq = SourceCurSeq,
                 status = VbStatus#rep_vb_status{num_changes_left = ChangesLeft - NumChecked,
                                                 docs_changes_queue = ChangesQueueDocs,
                                                 size_changes_queue = ChangesQueueSize,
                                                 data_replicated = TotalDataReplicated + DataReplicated,
                                                 docs_checked = TotalChecked + NumChecked,
                                                 docs_written = TotalWritten + NumWritten}
                },
    {noreply, update_status_to_parent(NewState)};

handle_call({worker_done, Pid}, _From,
            #rep_state{workers = Workers, status = VbStatus} = State) ->
    case Workers -- [Pid] of
        Workers ->
            {stop, {unknown_worker_done, Pid}, ok, State};
        [] ->
            %% all workers completed. Now shutdown everything and prepare for
            %% more changes from src

            %% allow another replicator to go
            State2 = replication_turn_is_done(State),
            couch_api_wrap:db_close(State2#rep_state.source),
            couch_api_wrap:db_close(State2#rep_state.src_master_db),
            couch_api_wrap:db_close(State2#rep_state.target),
            couch_api_wrap:db_close(State2#rep_state.tgt_master_db),
            %% force check for changes since we last snapshop
            self() ! src_db_updated,
            misc:flush(checkpoint),

            %% changes may or may not be closed
            VbStatus2 = VbStatus#rep_vb_status{size_changes_queue = 0,
                                               docs_changes_queue = 0},
            %% dump a bunch of stats
            Vb = VbStatus2#rep_vb_status.vb,
            Throttle = State2#rep_state.throttle,
            HighestDone = State2#rep_state.highest_seq_done,
            ChangesLeft = VbStatus2#rep_vb_status.num_changes_left,
            TotalChecked = VbStatus2#rep_vb_status.docs_checked,
            TotalWritten = VbStatus2#rep_vb_status.docs_written,
            TotalDataRepd = VbStatus2#rep_vb_status.data_replicated,
            NumCkpts = VbStatus2#rep_vb_status.num_checkpoints,
            NumFailedCkpts = VbStatus2#rep_vb_status.num_failedckpts,
            LastCkptTime = State2#rep_state.last_checkpoint_time,
            StartRepTime = State2#rep_state.rep_start_time,
            ?xdcr_debug("Replicator of vbucket ~p done, return token to throttle: ~p~n"
                        "(highest seq done is ~p, number of changes left: ~p~n"
                        "total docs checked: ~p, total docs written: ~p (total data repd: ~p)~n"
                        "total number of succ ckpts: ~p (failed ckpts: ~p)~n"
                        "last succ ckpt time: ~p, replicator start time: ~p.",
                        [Vb, Throttle, HighestDone, ChangesLeft, TotalChecked, TotalWritten, TotalDataRepd,
                         NumCkpts, NumFailedCkpts,
                         calendar:now_to_local_time(LastCkptTime),
                         calendar:now_to_local_time(StartRepTime)
                        ]),
            %% report stats to bucket replicator
            NewState = update_status_to_parent(State2#rep_state{
                                                  workers = [],
                                                  status = VbStatus2,
                                                  source = undefined,
                                                  src_master_db = undefined,
                                                  target = undefined,
                                                  tgt_master_db = undefined}),

            %% finally we mark the vb rep  status to idle after reporting stats to bucket replicator
            VbStatus3 = VbStatus2#rep_vb_status{status = idle},
            {reply, ok, NewState#rep_state{status = VbStatus3}};
        Workers2 ->
            {reply, ok, State#rep_state{workers = Workers2}}
    end.


handle_cast(checkpoint, #rep_state{status = VbStatus} = State) ->
    Result = case VbStatus#rep_vb_status.status of
                 replicating ->
                     Start = now(),
                     case xdc_vbucket_rep_ckpt:do_checkpoint(State) of
                         {ok, _, NewState} ->
                             CommitTime = timer:now_diff(now(), Start) div 1000,
                             TotalCommitTime = CommitTime + NewState#rep_state.status#rep_vb_status.total_commit_time,
                             VbStatus2 = NewState#rep_state.status#rep_vb_status{total_commit_time = TotalCommitTime},
                             NewState2 = NewState#rep_state{timer = xdc_vbucket_rep_ckpt:start_timer(State),
                                                            status = VbStatus2},
                             {ok, NewState2};
                         Error ->
                             %% update the failed ckpt stats to bucket replicator
                             {stop, Error, update_status_to_parent(State)}
                     end;
                 _ ->
                     %% if get checkpoint when not in replicating state, continue to wait until we
                     %% get our next turn, we'll do the checkpoint at the start of that.
                     misc:flush(checkpoint),
                     NewState = xdc_vbucket_rep_ckpt:cancel_timer(State),
                     {ok, NewState}
             end,

    case Result of
        {ok, NewState3} ->
            {noreply, NewState3};
        {stop, _, _} ->
            Result
    end;

handle_cast({report_seq, Seq},
            #rep_state{seqs_in_progress = SeqsInProgress} = State) ->
    NewSeqsInProgress = ordsets:add_element(Seq, SeqsInProgress),
    {noreply, State#rep_state{seqs_in_progress = NewSeqsInProgress}}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, #init_state{rep = #rep{target = TargetRef}, parent = P, vb = Vb} = InitState) ->
    report_error(Reason, Vb, P),
    ?xdcr_error("Shutting xdcr vb replicator (~p) down without ever successfully initializing: ~p", [InitState, Reason]),
    remote_clusters_info:invalidate_remote_bucket_by_ref(TargetRef),
    ok;

terminate(Reason, State) when Reason == normal orelse Reason == shutdown ->
    terminate_cleanup(State);

terminate(Reason, #rep_state{
            source_name = Source,
            target_name = Target,
            rep_details = #rep{id = Id, target = TargetRef},
            status = #rep_vb_status{vb = Vb} = Status,
            parent = P
           } = State) ->
    ?xdcr_error("Replication `~s` (`~s` -> `~s`) failed: ~s",
                [Id, Source, Target, to_binary(Reason)]),
    update_status_to_parent(State#rep_state{status =
                                                Status#rep_vb_status{status = idle,
                                                                     num_changes_left = 0,
                                                                     docs_changes_queue = 0,
                                                                     size_changes_queue = 0
                                                                    }}),
    report_error(Reason, Vb, P),
    %% an unhandled error happened. Invalidate target vb map cache.
    remote_clusters_info:invalidate_remote_bucket_by_ref(TargetRef),
    terminate_cleanup(State).


terminate_cleanup(State) ->
    Dbs = [State#rep_state.source,
           State#rep_state.target,
           State#rep_state.src_master_db,
           State#rep_state.tgt_master_db],
    [catch couch_api_wrap:db_close(Db) || Db <- Dbs, Db /= undefined].


%% internal helper function

report_error(Err, _Vb, _Parent) when Err == normal orelse Err == shutdown ->
    ok;
report_error(Err, Vb, Parent) ->
    %% return raw erlang time to make it sortable
    RawTime = erlang:localtime(),
    Time = misc:iso_8601_fmt(RawTime),
    String = iolist_to_binary(io_lib:format("~s - Error replicating vbucket ~p: ~p",
                                            [Time, Vb, Err])),
    gen_server:cast(Parent, {report_error, {RawTime, String}}).

replication_turn_is_done(#rep_state{throttle = T} = State) ->
    concurrency_throttle:is_done(T),
    State.

update_status_to_parent(#rep_state{parent = Parent,
                                   status = VbStatus} = State) ->
    %% compute work time since last update the status, note we only compute
    %% the work time if the status is replicating
    WorkTime = case VbStatus#rep_vb_status.status of
                   replicating ->
                       case State#rep_state.work_start_time of
                           0 ->
                               %% timer not initalized yet
                               0;
                           _ ->
                               timer:now_diff(now(), State#rep_state.work_start_time) div 1000
                       end;
                   %% if not replicating (idling or waiting for turn), do not count the work time
                   _ ->
                       0
               end,

    %% post to parent bucket replicator
    Parent ! {set_vb_rep_status,  VbStatus#rep_vb_status{total_work_time = WorkTime}},

    %% reset accumulated stats and start work time
    NewVbStat = VbStatus#rep_vb_status{
                  docs_checked = 0,
                  docs_written = 0,
                  data_replicated = 0,
                  total_work_time = 0,
                  total_commit_time = 0,
                  num_checkpoints = 0,
                  num_failedckpts = 0},
    State#rep_state{status = NewVbStat,
                    work_start_time = now()}.

init_replication_state(#init_state{rep = Rep,
                                   vb = Vb,
                                   work_throttle = Throttle,
                                   parent = Parent}) ->
    #rep{
          source = Src,
          target = Tgt,
          options = Options
        } = Rep,
    SrcVbDb = xdc_rep_utils:local_couch_uri_for_vbucket(Src, Vb),
    {ok, RemoteBucket} = remote_clusters_info:get_remote_bucket_by_ref(Tgt,
                                                                       false),
    TgtURI = hd(dict:fetch(Vb, RemoteBucket#remote_bucket.vbucket_map)),
    TgtDb = xdc_rep_utils:parse_rep_db(TgtURI),
    {ok, Source} = couch_api_wrap:db_open(SrcVbDb, []),
    {ok, Target} = couch_api_wrap:db_open(TgtDb, []),

    {ok, SourceInfo} = couch_api_wrap:get_db_info(Source),
    {ok, TargetInfo} = couch_api_wrap:get_db_info(Target),

    {ok, SrcMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Source),
                          []),
    {ok, TgtMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Target),
                          []),

    %% We have to pass the vbucket database along with the master database
    %% because the replication log id needs to be prefixed with the vbucket id
    %% at both the source and the destination.
    [SourceLog, TargetLog] = find_replication_logs(
                               [{Source, SrcMasterDb}, {Target, TgtMasterDb}],
                               Rep),

    {StartSeq0,
     DocsChecked,
     DocsWritten,
     DataReplicated,
     History} = compare_replication_logs(SourceLog, TargetLog),
    ?xdcr_debug("history log at src and dest: startseq: ~p, docs checked: ~p,"
                "docs_written: ~p, data replicated: ~p",
                [StartSeq0, DocsChecked, DocsWritten, DataReplicated]),
    StartSeq = get_value(since_seq, Options, StartSeq0),
    #doc{body={CheckpointHistory}} = SourceLog,
    couch_db:close(Source),
    couch_db:close(SrcMasterDb),
    couch_api_wrap:db_close(TgtMasterDb),
    couch_api_wrap:db_close(Target),
    couch_api_wrap:db_close(TgtMasterDb),
    RepState = #rep_state{
      rep_details = Rep,
      throttle = Throttle,
      parent = Parent,
      source_name = SrcVbDb,
      target_name = TgtURI,
      source = Source,
      target = Target,
      src_master_db = SrcMasterDb,
      tgt_master_db = TgtMasterDb,
      history = History,
      checkpoint_history = {[{<<"no_changes">>, true}| CheckpointHistory]},
      start_seq = StartSeq,
      current_through_seq = StartSeq,
      source_cur_seq = StartSeq,
      source_log = SourceLog,
      target_log = TargetLog,
      rep_starttime = httpd_util:rfc1123_date(),
      src_starttime = get_value(<<"instance_start_time">>, SourceInfo),
      tgt_starttime = get_value(<<"instance_start_time">>, TargetInfo),
      last_checkpoint_time = now(),
      rep_start_time = now(),
      %% temporarily initialized to 0, when vb rep gets the token it will
      %% initialize the work start time in start_replication()
      work_start_time = 0,
      session_id = couch_uuids:random(),
      status = #rep_vb_status{vb = Vb,
                              pid = self(),
                              %% the accumulated stats are cleared here. They
                              %% will be computed during the lifetime of vb
                              %% replicator and aggregated at the parent bucket
                              %% replicator when vb replicator pushes the stats
                              docs_checked = 0,
                              docs_written = 0,
                              total_work_time = 0,
                              total_commit_time = 0,
                              data_replicated = 0,
                              num_checkpoints = 0,
                              num_failedckpts = 0
                             },
      source_seq = get_value(<<"update_seq">>, SourceInfo, ?LOWEST_SEQ)
     },
    ?xdcr_debug("vb ~p replication state initialized: ~p", [Vb, RepState]),
    RepState.

start_replication(#rep_state{
                     source_name = SourceName,
                     target_name = TargetName,
                     current_through_seq = StartSeq,
                     last_checkpoint_time = LastCkptTime,
                     rep_details = #rep{id = Id, options = Options},
                     status = VbStatus
                    } = State) ->

    WorkStart = now(),
    NumWorkers = get_value(worker_processes, Options),
    BatchSize = get_value(worker_batch_size, Options),
    {ok, Source} = couch_api_wrap:db_open(SourceName, []),
    TgtURI = xdc_rep_utils:parse_rep_db(TargetName, [], Options),
    {ok, Target} = couch_api_wrap:db_open(TgtURI, []),
    {ok, SrcMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Source),
                          []),
    {ok, TgtMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Target), []),

    {ok, ChangesQueue} = couch_work_queue:new([
                                               {max_items, BatchSize * NumWorkers * 2},
                                               {max_size, 100 * 1024 * NumWorkers}
                                              ]),
    %% This starts the _changes reader process. It adds the changes from
    %% the source db to the ChangesQueue.
    ChangesReader = spawn_changes_reader(StartSeq, Source, ChangesQueue),
    %% Changes manager - responsible for dequeing batches from the changes queue
    %% and deliver them to the worker processes.
    ChangesManager = spawn_changes_manager(self(), ChangesQueue, BatchSize),
    %% This starts the worker processes. They ask the changes queue manager for a
    %% a batch of _changes rows to process -> check which revs are missing in the
    %% target, and for the missing ones, it copies them from the source to the target.
    MaxConns = get_value(http_connections, Options),

    ?xdcr_info("changes reader process (PID: ~p) and manager process (PID: ~p) "
               "created, now starting worker processes...",
               [ChangesReader, ChangesManager]),
    Changes = couch_db:count_changes_since(Source, StartSeq),

    Workers = lists:map(
                fun(_) ->
                        {ok, Pid} = xdc_vbucket_rep_worker:start_link(
                                      self(), Source, Target, ChangesManager, MaxConns),
                        Pid
                end,
                lists:seq(1, NumWorkers)),

    ?xdcr_info("Replication `~p` is using:~n"
               "~c~p worker processes~n"
               "~ca worker batch size of ~p~n"
               "~c~p HTTP connections~n"
               "~ca connection timeout of ~p milliseconds~n"
               "~c~p retries per request~n"
               "~csocket options are: ~s~s",
               [Id, $\t, NumWorkers, $\t, BatchSize, $\t,
                MaxConns, $\t, get_value(connection_timeout, Options),
                $\t, get_value(retries, Options),
                $\t, io_lib:format("~p", [get_value(socket_options, Options)]),
                case StartSeq of
                    ?LOWEST_SEQ ->
                        "";
                    _ ->
                        io_lib:format("~n~csource start sequence ~p", [$\t, StartSeq])
                end]),

    {value, DefaultIntervalSecs} = ns_config:search(xdcr_checkpoint_interval),
    IntervalSecs =  misc:getenv_int("XDCR_CHECKPOINT_INTERVAL", DefaultIntervalSecs),
    TimeSinceLastCkpt = timer:now_diff(now(), LastCkptTime) div 1000000,
    ?xdcr_debug("Worker pids are: ~p, last checkpt time: ~p"
                "secs since last ckpt: ~p, ckpt interval: ~p)",
                [Workers, calendar:now_to_local_time(LastCkptTime),
                 TimeSinceLastCkpt, IntervalSecs]),

    %% check if we need do checkpointing, replicator will crash if checkpoint failure
    State1 = State#rep_state{
               source = Source,
               target = Target,
               src_master_db = SrcMasterDb,
               tgt_master_db = TgtMasterDb},

    {Succ, ErrorMsg, NewState} = case TimeSinceLastCkpt > IntervalSecs of
                                     true ->
                                         xdc_vbucket_rep_ckpt:do_checkpoint(State1);
                                     _ ->
                                         {ok, <<"no checkpoint">>, State1}
                                 end,

    ResultState = update_status_to_parent(NewState#rep_state{
                                            changes_queue = ChangesQueue,
                                            workers = Workers,
                                            source = Source,
                                            src_master_db = SrcMasterDb,
                                            target = Target,
                                            tgt_master_db = TgtMasterDb,
                                            status = VbStatus#rep_vb_status{num_changes_left = Changes},
                                            timer = xdc_vbucket_rep_ckpt:start_timer(State),
                                            work_start_time = WorkStart
                                           }),

    %% finally crash myself if fail to commit, after posting status to parent
    case Succ of
        ok ->
            ok;
        checkpoint_commit_failure ->
            exit(ErrorMsg)
    end,

    ResultState.

update_number_of_changes(#rep_state{source_name = Src,
                                    current_through_seq = Seq,
                                    status = VbStatus} = State) ->
    case couch_server:open(Src, []) of
        {ok, Db} ->
            Changes = couch_db:count_changes_since(Db, Seq),
            couch_db:close(Db),
            if VbStatus#rep_vb_status.num_changes_left /= Changes ->
                    State#rep_state{status = VbStatus#rep_vb_status{num_changes_left = Changes}};
               true ->
                    State
            end;
        {not_found, no_db_file} ->
            %% oops our file was deleted.
            %% We'll get shutdown when the vbucket map message is processed
            State
    end.


spawn_changes_reader(StartSeq, Db, ChangesQueue) ->
    spawn_link(fun() ->
                       read_changes(StartSeq, Db, ChangesQueue)
               end).

read_changes(StartSeq, Db, ChangesQueue) ->
    couch_db:changes_since(Db, StartSeq,
                           fun(#doc_info{local_seq = Seq} = DocInfo, ok) ->
                                   ok = couch_work_queue:queue(ChangesQueue, DocInfo),
                                   put(last_seq, Seq),
                                   {ok, ok}
                           end, [], ok),
    couch_work_queue:close(ChangesQueue).

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
                    #doc_info{local_seq = Seq} = lists:last(Changes),
                    ReportSeq = Seq,
                    ok = gen_server:cast(Parent, {report_seq, ReportSeq}),
                    From ! {changes, self(), Changes, ReportSeq},
                    changes_manager_loop_open(Parent, ChangesQueue, BatchSize)
            end
    end.

find_replication_logs(DbList, #rep{id = Id} = Rep) ->
    fold_replication_logs(DbList, ?REP_ID_VERSION, Id, Id, Rep, []).


fold_replication_logs([], _Vsn, _LogId, _NewId, _Rep, Acc) ->
    lists:reverse(Acc);

fold_replication_logs([{Db, MasterDb} | Rest] = Dbs, Vsn, LogId0, NewId0, Rep, Acc) ->
    LogId = xdc_rep_utils:get_checkpoint_log_id(Db, LogId0),
    NewId = xdc_rep_utils:get_checkpoint_log_id(Db, NewId0),
    case couch_api_wrap:open_doc(MasterDb, LogId, [ejson_body]) of
        {error, <<"not_found">>} when Vsn > 1 ->
            OldRepId = Rep#rep.id,
            fold_replication_logs(Dbs, Vsn - 1,
                                  OldRepId, NewId0, Rep, Acc);
        {error, <<"not_found">>} ->
            fold_replication_logs(
              Rest, ?REP_ID_VERSION, NewId0, NewId0, Rep, [#doc{id = NewId, body = {[]}} | Acc]);
        {ok, Doc} when LogId =:= NewId ->
            fold_replication_logs(
              Rest, ?REP_ID_VERSION, NewId0, NewId0, Rep, [Doc | Acc]);
        {ok, Doc} ->
            MigratedLog = #doc{id = NewId, body = Doc#doc.body},
            fold_replication_logs(
              Rest, ?REP_ID_VERSION, NewId0, NewId0, Rep, [MigratedLog | Acc])
    end.

compare_replication_logs(SrcDoc, TgtDoc) ->
    #doc{body={RepRecProps}} = SrcDoc,
    #doc{body={RepRecPropsTgt}} = TgtDoc,
    case get_value(<<"session_id">>, RepRecProps) ==
        get_value(<<"session_id">>, RepRecPropsTgt) of
        true ->
            %% if the records have the same session id,
            %% then we have a valid replication history
            OldSeqNum = get_value(<<"source_last_seq">>, RepRecProps, ?LOWEST_SEQ),
            OldHistory = get_value(<<"history">>, RepRecProps, []),
            {OldSeqNum,
             get_value(<<"docs_checked">>, RepRecProps, 0),
             get_value(<<"docs_written">>, RepRecProps, 0),
             get_value(<<"data_replicated">>, RepRecProps, 0),
             OldHistory};
        false ->
            SourceHistory = get_value(<<"history">>, RepRecProps, []),
            TargetHistory = get_value(<<"history">>, RepRecPropsTgt, []),
            ?xdcr_info("Replication records differ. "
                       "Scanning histories to find a common ancestor.", []),
            ?xdcr_debug("Record on source:~p~nRecord on target:~p~n",
                        [RepRecProps, RepRecPropsTgt]),
            compare_rep_history(SourceHistory, TargetHistory)
    end.

compare_rep_history(S, T) when S =:= [] orelse T =:= [] ->
    ?xdcr_info("no common ancestry -- performing full replication", []),
    {?LOWEST_SEQ, 0, 0, 0, []};

compare_rep_history([{S} | SourceRest], [{T} | TargetRest] = Target) ->
    SourceId = get_value(<<"session_id">>, S),
    case has_session_id(SourceId, Target) of
        true ->
            RecordSeqNum = get_value(<<"recorded_seq">>, S, ?LOWEST_SEQ),
            ?xdcr_info("found a common replication record with source_seq ~p",
                       [RecordSeqNum]),
            {RecordSeqNum,
             get_value(<<"docs_checked">>, S, 0),
             get_value(<<"docs_written">>, S, 0),
             get_value(<<"data_replicated">>, S, 0),
             SourceRest};
        false ->
            TargetId = get_value(<<"session_id">>, T),
            case has_session_id(TargetId, SourceRest) of
                true ->
                    RecordSeqNum = get_value(<<"recorded_seq">>, T, ?LOWEST_SEQ),
                    ?xdcr_info("found a common replication record with source_seq ~p",
                               [RecordSeqNum]),
                    {RecordSeqNum,
                     get_value(<<"docs_checked">>, T, 0),
                     get_value(<<"docs_written">>, T, 0),
                     get_value(<<"data_replicated">>, T, 0),
                     TargetRest};
                false ->
                    compare_rep_history(SourceRest, TargetRest)
            end
    end.

has_session_id(_SessionId, []) ->
    false;
has_session_id(SessionId, [{Props} | Rest]) ->
    case get_value(<<"session_id">>, Props, nil) of
        SessionId ->
            true;
        _Else ->
            has_session_id(SessionId, Rest)
    end.

target_uri_to_node(TgtURI) ->
    TargetURI = binary_to_list(TgtURI),
    [_Prefix, NodeDB] = string:tokens(TargetURI, "@"),
    [Node, _Bucket] = string:tokens(NodeDB, "/"),
    Node.

get_changes_queue_stats(#rep_state{changes_queue = ChangesQueue} = _State) ->
    ChangesQueueSize = case couch_work_queue:size(ChangesQueue) of
                           closed ->
                               0;
                           QueueSize ->
                               QueueSize
                       end,
    %% num of docs in changes queue
    ChangesQueueDocs = case couch_work_queue:item_count(ChangesQueue) of
                           closed ->
                               0;
                           QueueDocs ->
                               QueueDocs
                       end,

    {ChangesQueueSize, ChangesQueueDocs}.

