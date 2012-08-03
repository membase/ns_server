-module(compaction_daemon).

-behaviour(gen_fsm).

-include("ns_common.hrl").
-include("couch_db.hrl").

%% API
-export([start_link/0,

         force_compact_bucket/1, force_compact_db_files/1, force_compact_view/2,
         cancel_forced_bucket_compaction/1, cancel_forced_db_compaction/1,
         cancel_forced_view_compaction/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         code_change/4, terminate/3]).

-record(state, {buckets_to_compact,
                compactor_pid,
                compactor_config,
                compaction_start_ts,
                scheduled_compaction_tref,

                %% mapping from compactor pid to #forced_compaction{}
                running_forced_compactions,
                %% reverse mapping from #forced_compaction{} to compactor pid
                forced_compaction_pids}).

-record(config, {db_fragmentation,
                 view_fragmentation,
                 allowed_period,
                 parallel_view_compact = false,
                 daemon}).

-record(daemon_config, {check_interval,
                        min_file_size}).

-record(period, {from_hour,
                 from_minute,
                 to_hour,
                 to_minute,
                 abort_outside}).

-record(forced_compaction, {type :: bucket | db | view,
                            name :: binary()}).

% If N vbucket databases of a bucket need to be compacted, we trigger compaction
% for all the vbucket databases of that bucket.
-define(NUM_SAMPLE_VBUCKETS, 16).

-define(RPC_TIMEOUT, 10000).


%% API
start_link() ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

force_compact_bucket(Bucket) ->
    BucketBin = list_to_binary(Bucket),
    R = multi_sync_send_all_state_event({force_compact_bucket, BucketBin}),

    case R of
        [] ->
            ok;
        Failed ->
            ale:error(?USER_LOGGER,
                      "Failed to start bucket compaction "
                      "for `~s` on some nodes: ~n~p", [Bucket, Failed])
    end,

    ok.

force_compact_db_files(Bucket) ->
    BucketBin = list_to_binary(Bucket),
    R = multi_sync_send_all_state_event({force_compact_db_files, BucketBin}),

    case R of
        [] ->
            ok;
        Failed ->
            ale:error(?USER_LOGGER,
                      "Failed to start bucket databases compaction "
                      "for `~s` on some nodes: ~n~p", [Bucket, Failed])
    end,

    ok.

force_compact_view(Bucket, DDocId) ->
    BucketBin = list_to_binary(Bucket),
    DDocIdBin = list_to_binary(DDocId),
    R = multi_sync_send_all_state_event({force_compact_view, BucketBin, DDocIdBin}),

    case R of
        [] ->
            ok;
        Failed ->
            ale:error(?USER_LOGGER,
                      "Failed to start index compaction "
                      "for `~s/~s` on some nodes: ~n~p",
                      [Bucket, DDocId, Failed])
    end,

    ok.

cancel_forced_bucket_compaction(Bucket) ->
    BucketBin = list_to_binary(Bucket),
    R = multi_sync_send_all_state_event({cancel_forced_bucket_compaction, BucketBin}),

    case R of
        [] ->
            ok;
        Failed ->
            ale:error(?USER_LOGGER,
                      "Failed to cancel bucket compaction "
                      "for `~s` on some nodes: ~n~p", [Bucket, Failed])
    end,

    ok.

cancel_forced_db_compaction(Bucket) ->
    BucketBin = list_to_binary(Bucket),
    R = multi_sync_send_all_state_event({cancel_forced_db_compaction, BucketBin}),

    case R of
        [] ->
            ok;
        Failed ->
            ale:error(?USER_LOGGER,
                      "Failed to cancel bucket databases compaction "
                      "for `~s` on some nodes: ~n~p", [Bucket, Failed])
    end,

    ok.

cancel_forced_view_compaction(Bucket, DDocId) ->
    BucketBin = list_to_binary(Bucket),
    DDocIdBin = list_to_binary(DDocId),
    R = multi_sync_send_all_state_event(
          {cancel_forced_view_compaction, BucketBin, DDocIdBin}),

    case R of
        [] ->
            ok;
        Failed ->
            ale:error(?USER_LOGGER,
                      "Failed to cancel index compaction "
                      "for `~s/~s` on some nodes: ~n~p",
                      [Bucket, DDocId, Failed])
    end,

    ok.

%% gen_fsm callbacks
init([]) ->
    process_flag(trap_exit, true),

    Self = self(),

    ns_pubsub:subscribe_link(
      ns_config_events,
      fun ({buckets, _}) ->
              Self ! config_changed;
          ({autocompaction, _}) ->
              Self ! config_changed;
          ({{node, Node, compaction_daemon}, _}) when node() =:= Node ->
              Self ! config_changed;
          (_) ->
              ok
      end),

    Self ! compact,
    {ok, idle, #state{buckets_to_compact=[],
                      compactor_pid=undefined,
                      compactor_config=undefined,
                      compaction_start_ts=undefined,
                      scheduled_compaction_tref=undefined,
                      running_forced_compactions=dict:new(),
                      forced_compaction_pids=dict:new()}}.

handle_event(Event, StateName, State) ->
    ?log_warning("Got unexpected event ~p (when in ~p):~n~p",
                 [Event, StateName, State]),
    {next_state, StateName, State}.

handle_sync_event({force_compact_bucket, Bucket}, _From, StateName, State) ->
    Compaction = #forced_compaction{type=bucket, name=Bucket},

    NewState =
        case is_already_being_compacted(Compaction, State) of
            true ->
                State;
            false ->
                Configs = compaction_config(Bucket),
                Pid = spawn_bucket_compactor(Bucket, Configs, true),
                register_forced_compaction(Pid, Compaction, State)
        end,
    {reply, ok, StateName, NewState};
handle_sync_event({force_compact_db_files, Bucket}, _From, StateName, State) ->
    Compaction = #forced_compaction{type=db, name=Bucket},

    NewState =
        case is_already_being_compacted(Compaction, State) of
            true ->
                State;
            false ->
                {Config, _} = compaction_config(Bucket),
                Pid = spawn_dbs_compactor(Bucket, Config, true, db),
                register_forced_compaction(Pid, Compaction, State)
        end,
    {reply, ok, StateName, NewState};
handle_sync_event({force_compact_view, Bucket, DDocId}, _From, StateName, State) ->
    Name = <<Bucket/binary, $/, DDocId/binary>>,
    Compaction = #forced_compaction{type=view, name=Name},

    NewState =
        case is_already_being_compacted(Compaction, State) of
            true ->
                State;
            false ->
                {Config, _} = compaction_config(Bucket),
                Pid = spawn_view_compactor(Bucket, DDocId, Config, true),
                register_forced_compaction(Pid, Compaction, State)
        end,
    {reply, ok, StateName, NewState};
handle_sync_event({cancel_forced_bucket_compaction, Bucket}, _From,
                  StateName, State) ->
    Compaction = #forced_compaction{type=bucket, name=Bucket},
    {reply, ok, StateName, maybe_cancel_compaction(Compaction, State)};
handle_sync_event({cancel_forced_db_compaction, Bucket}, _From,
                  StateName, State) ->
    Compaction = #forced_compaction{type=db, name=Bucket},
    {reply, ok, StateName, maybe_cancel_compaction(Compaction, State)};
handle_sync_event({cancel_forced_view_compaction, Bucket, DDocId},
                  _From, StateName, State) ->
    Name = <<Bucket/binary, $/, DDocId/binary>>,
    Compaction = #forced_compaction{type=view, name=Name},
    {reply, ok, StateName, maybe_cancel_compaction(Compaction, State)};
handle_sync_event(Event, _From, StateName, State) ->
    ?log_warning("Got unexpected sync event ~p (when in ~p):~n~p",
                 [Event, StateName, State]),
    {reply, ok, StateName, State}.

handle_info(compact, idle,
            #state{buckets_to_compact=Buckets0} = State) ->
    undefined = State#state.compaction_start_ts,
    undefined = State#state.compactor_pid,

    Buckets =
        case Buckets0 of
            [] ->
                lists:map(fun list_to_binary/1,
                          ns_bucket:node_bucket_names_of_type(node(), membase));
            _ ->
                Buckets0
        end,

    NewState0 = State#state{scheduled_compaction_tref=undefined},

    case Buckets of
        [] ->
            ?log_debug("No buckets to compact. Rescheduling compaction."),
            {next_state, idle, schedule_next_compaction(NewState0)};
        _ ->
            ?log_debug("Starting compaction for the following buckets: ~n~p",
                       [Buckets]),
            NewState1 = NewState0#state{buckets_to_compact=Buckets,
                                        compaction_start_ts=now_utc_seconds()},
            NewState = compact_next_bucket(NewState1),
            {next_state, compacting, NewState}
    end;
handle_info({'EXIT', Compactor, Reason}, compacting,
            #state{compactor_pid=Compactor,
                   buckets_to_compact=Buckets} = State) ->
    true = Buckets =/= [],

    case Reason of
        normal ->
            ok;
        shutdown ->
            ?log_debug("Compactor ~p exited with reason ~p", [Compactor, Reason]);
        _ ->
            ?log_error("Compactor ~p exited unexpectedly: ~p. "
                       "Moving to the next bucket.", [Compactor, Reason])
    end,

    NewBuckets =
        case Reason of
            shutdown ->
                %% this can happen either on config change or if compaction
                %% has been stopped due to end of allowed time period; in the
                %% latter case there's no need to compact bucket again; but it
                %% won't hurt: compaction shall be terminated rightaway with
                %% reason normal
                Buckets;
            _ ->
                tl(Buckets)
        end,

    NewState0 = State#state{compactor_pid=undefined,
                            compactor_config=undefined,
                            buckets_to_compact=NewBuckets},
    case NewBuckets of
        [] ->
            ?log_debug("Finished compaction iteration."),
            {next_state, idle, schedule_next_compaction(NewState0)};
        _ ->
            {next_state, compacting, compact_next_bucket(NewState0)}
    end;
handle_info({'EXIT', Pid, Reason}, StateName,
            #state{running_forced_compactions=Compactions} = State) ->
    case dict:find(Pid, Compactions) of
        {ok, #forced_compaction{type=Type, name=Name}} ->
            case Reason of
                normal ->
                    ale:info(?USER_LOGGER,
                             "User-triggered compaction of ~p `~s` completed.",
                             [Type, Name]);
                _ ->
                    ale:error(?USER_LOGGER,
                              "User-triggered compaction of ~p `~s` failed: ~p. "
                              "See logs for detailed reason.",
                              [Type, Name, Reason])
            end,

            {next_state, StateName, unregister_forced_compaction(Pid, State)};
        error ->
            ?log_error("Unexpected process termination ~p: ~p. Dying.",
                       [Pid, Reason]),
            {stop, Reason, State}
    end;
handle_info(config_changed, compacting,
            #state{compactor_pid=Compactor,
                   buckets_to_compact=[CompactedBucket|_],
                   compactor_config=Config} = State) ->
    misc:flush(config_changed),

    {MaybeNewConfig, _} = compaction_config(CompactedBucket),
    case MaybeNewConfig =:= Config of
        true ->
            ok;
        false ->
            ?log_info("Restarting compactor ~p since "
                      "autocompaction config has changed", [Compactor]),
            exit(Compactor, shutdown)
    end,
    {next_state, compacting, State};
handle_info(config_changed, StateName, State) ->
    ?log_debug("Got config_changed in state ~p. "
               "Nothing to do since compaction is not running", [StateName]),
    misc:flush(config_changed),
    {next_state, StateName, State};
handle_info(Info, StateName, State) ->
    ?log_warning("Got unexpected message ~p (when in ~p):~n~p",
                 [Info, StateName, State]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% Internal functions
-spec spawn_bucket_compactor(binary(), {#config{}, list()}) -> pid().
spawn_bucket_compactor(BucketName, Configs) ->
    spawn_bucket_compactor(BucketName, Configs, false).

-spec spawn_bucket_compactor(binary(), {#config{}, list()}, boolean()) -> pid().
spawn_bucket_compactor(BucketName, {Config, ConfigProps}, Force) ->
    proc_lib:spawn_link(
      fun () ->
              case Force of
                  true ->
                      ok;
                  false ->
                      %% effectful
                      check_period(Config)
              end,

              case bucket_exists(BucketName) of
                  true ->
                      ok;
                  false ->
                      %% bucket's gone; so just terminate normally
                      exit(normal)
              end,

              AllBucketDbs = all_bucket_dbs(BucketName),

              %% In certain cases some of the databases might not exists yet
              %% (or already). Generally it's an intermittent state thus it
              %% seems to be ok to skip compaction in such cases. This will
              %% avoid loads of crash reports in the logs with {not_found,
              %% no_db_file} reason.
              check_all_dbs_exist(BucketName, AllBucketDbs),

              try_to_cleanup_indexes(BucketName, AllBucketDbs),

              ?log_info("Compacting bucket ~s with config: ~n~p",
                        [BucketName, ConfigProps]),

              DDocNames = ddoc_names(BucketName),

              DbsCompactor =
                  [{type, database},
                   {important, true},
                   {name, BucketName},
                   {fa, {fun spawn_dbs_compactor/4,
                         [BucketName, Config, Force, bucket]}}],
              DDocCompactors =
                  [ [{type, view},
                     {name, <<BucketName/binary, $/, DDocId/binary>>},
                     {important, false},
                     {fa, {fun spawn_view_compactor/4,
                           [BucketName, DDocId, Config, Force]}}] ||
                      DDocId <- DDocNames ],

              case Config#config.parallel_view_compact of
                  true ->
                      DbsPid = chain_compactors([DbsCompactor]),
                      ViewsPid = chain_compactors(DDocCompactors),

                      misc:wait_for_process(DbsPid, infinity),
                      misc:wait_for_process(ViewsPid, infinity);
                  false ->
                      AllCompactors = [DbsCompactor | DDocCompactors],
                      Pid = chain_compactors(AllCompactors),
                      misc:wait_for_process(Pid, infinity)
              end
      end).

try_to_cleanup_indexes(BucketName, AllBucketDbs) ->
    ?log_info("Cleaning up indexes for bucket `~s`", [BucketName]),

    try
        couch_set_view:cleanup_index_files(BucketName)
    catch SetViewT:SetViewE ->
            ?log_error("Error while doing cleanup of old "
                       "index files for bucket `~s`: ~p~n~p",
                       [BucketName, {SetViewT, SetViewE}, erlang:get_stacktrace()])
    end,

    try
        capi_spatial:cleanup_spatial_index_files(BucketName)
    catch SpatialT:SpatialE ->
            ?log_error("Error while doing cleanup of old "
                       "spatial index files for bucket `~s`: ~p~n~p",
                       [BucketName, {SpatialT, SpatialE}, erlang:get_stacktrace()])
    end,

    %% we still use ordinary views for development subset
    lists:foreach(
      fun (DbName) ->
              try
                  {ok, Db} = couch_db:open_int(DbName, []),

                  try
                      couch_view:cleanup_index_files(Db)
                  after
                      couch_db:close(Db)
                  end
              catch
                  ViewT:ViewE ->
                      ?log_error(
                         "Error while doing cleanup of old "
                         "index files for database `~s`: ~p~n~p",
                         [DbName, {ViewT, ViewE}, erlang:get_stacktrace()])
              end
      end, AllBucketDbs).


chain_compactors(Compactors) ->
    Parent = self(),

    proc_lib:spawn_link(
      fun () ->
              process_flag(trap_exit, true),
              do_chain_compactors(Parent, Compactors)
      end).

do_chain_compactors(_Parent, []) ->
    ok;
do_chain_compactors(Parent, [Compactor | Compactors]) ->
    {Fun, Args} = proplists:get_value(fa, Compactor),
    Important = proplists:get_value(important, Compactor, true),
    Pid = erlang:apply(Fun, Args),

    receive
        {'EXIT', Parent, Reason} = Exit ->
            ?log_debug("Got exit signal from parent: ~p", [Exit]),
            exit(Pid, Reason),
            misc:wait_for_process(Pid, infinity),
            exit(Reason);
        {'EXIT', Pid, normal} ->
            case proplists:get_value(on_success, Compactor) of
                undefined ->
                    ok;
                {SuccessFun, SuccessArgs} ->
                    erlang:apply(SuccessFun, SuccessArgs)
            end,

            do_chain_compactors(Parent, Compactors);
        {'EXIT', Pid, Reason} ->
            Type = proplists:get_value(type, Compactor),
            Name = proplists:get_value(name, Compactor),

            case Important of
                true ->
                    ?log_warning("Compactor for ~p `~s` (pid ~p) terminated "
                                 "unexpectedly: ~p",
                                 [Type, Name, Compactor, Reason]),
                    exit(Reason);
                false ->
                    ?log_warning("Compactor for ~p `~s` (pid ~p) terminated "
                                 "unexpectedly (ignoring this): ~p",
                                 [Type, Name, Compactor, Reason])
            end
    end.

spawn_dbs_compactor(BucketName, Config, Force, OriginalTarget) ->
    Parent = self(),

    proc_lib:spawn_link(
      fun () ->
              VBucketDbs = all_bucket_dbs(BucketName),

              DoCompact =
                  case Force of
                      true ->
                          ?log_info("Forceful compaction of bucket ~s requested",
                                    [BucketName]),
                          true;
                      false ->
                          bucket_needs_compaction(BucketName, VBucketDbs, Config)
                  end,

              DoCompact orelse exit(normal),

              ?log_info("Compacting databases for bucket ~s", [BucketName]),

              Total = length(VBucketDbs),
              TriggerType = case Force of
                                true ->
                                    manual;
                                false ->
                                    scheduled
                            end,

              ok = couch_task_status:add_task(
                     [{type, bucket_compaction},
                      {original_target, OriginalTarget},
                      {trigger_type, TriggerType},
                      {bucket, BucketName},
                      {vbuckets_done, 0},
                      {total_vbuckets, Total},
                      {progress, 0}]),

              Compactors =
                  [ [{type, vbucket},
                     {name, VBucketDb},
                     {important, false},
                     {fa, {fun spawn_vbucket_compactor/1, [VBucketDb]}},
                     {on_success,
                      {fun update_bucket_compaction_progress/2, [Ix, Total]}}] ||
                      {Ix, VBucketDb} <- misc:enumerate(VBucketDbs) ],

              process_flag(trap_exit, true),
              do_chain_compactors(Parent, Compactors),

              ?log_info("Finished compaction of databases for bucket ~s",
                        [BucketName])
      end).

update_bucket_compaction_progress(Ix, Total) ->
    Progress = (Ix * 100) div Total,
    ok = couch_task_status:update(
           [{vbuckets_done, Ix},
            {progress, Progress}]).

spawn_vbucket_compactor(DbName) ->
    Parent = self(),

    proc_lib:spawn_link(
      fun () ->
              {ok, Db} = couch_db:open_int(DbName, []),

              %% effectful
              ensure_can_db_compact(Db),

              ?log_info("Compacting ~p", [DbName]),

              process_flag(trap_exit, true),

              {ok, Compactor} = couch_db:start_compact(Db),

              CompactorRef = erlang:monitor(process, Compactor),

              receive
                  {'EXIT', Parent, Reason} = Exit ->
                      ?log_debug("Got exit signal from parent: ~p", [Exit]),

                      erlang:demonitor(CompactorRef),
                      ok = couch_db:cancel_compact(Db),
                      exit(Reason);
                  {'DOWN', CompactorRef, process, Compactor, normal} ->
                      ok;
                  {'DOWN', CompactorRef, process, Compactor, noproc} ->
                      %% compactor died before we managed to monitor it;
                      %% we will treat this as an error
                      exit({db_compactor_died_too_soon, DbName});
                  {'DOWN', CompactorRef, process, Compactor, Reason} ->
                      exit(Reason)
              end
      end).

spawn_view_compactor(BucketName, DDocId, Config, Force) ->
    Parent = self(),

    proc_lib:spawn_link(
      fun () ->
              process_flag(trap_exit, true),

              Compactors =
                  [ [{type, view},
                     {important, true},
                     {name, view_name(BucketName, DDocId, Type)},
                     {fa, {fun spawn_view_index_compactor/5,
                           [BucketName, DDocId, Type, Config, Force]}}] ||
                      Type <- [main, replica] ],

              do_chain_compactors(Parent, Compactors)
      end).

view_name(BucketName, DDocId, Type) ->
    <<BucketName/binary, $/, DDocId/binary, $/,
      (atom_to_binary(Type, latin1))/binary>>.

spawn_view_index_compactor(BucketName, DDocId, Type, Config, Force) ->
    Parent = self(),

    proc_lib:spawn_link(
      fun () ->
              ViewName = view_name(BucketName, DDocId, Type),

              DoCompact =
                  case Force of
                      true ->
                          ?log_info("Forceful compaction of view ~s requested",
                                    [ViewName]),
                          true;
                      false ->
                          view_needs_compaction(BucketName, DDocId, Type, Config)
                  end,

              DoCompact orelse exit(normal),

              %% effectful
              ensure_can_view_compact(BucketName, DDocId, Type),

              ?log_info("Compacting indexes for ~s", [ViewName]),

              process_flag(trap_exit, true),

              {ok, Compactor} =
                  couch_set_view_compactor:start_compact(BucketName, DDocId, Type),
              CompactorRef = erlang:monitor(process, Compactor),

              receive
                  {'EXIT', Parent, Reason} = Exit ->
                      ?log_debug("Got exit signal from parent: ~p", [Exit]),

                      erlang:demonitor(CompactorRef),
                      ok = couch_set_view_compactor:cancel_compact(
                             BucketName, DDocId, Type),
                      exit(Reason);
                  {'DOWN', CompactorRef, process, Compactor, normal} ->
                      ok;
                  {'DOWN', CompactorRef, process, Compactor, noproc} ->
                      exit({index_compactor_died_too_soon,
                            BucketName, DDocId, Type});
                  {'DOWN', CompactorRef, process, Compactor, Reason} ->
                      exit(Reason)
              end,

              ?log_info("Finished compacting indexes for ~s", [ViewName])
      end).

bucket_needs_compaction(BucketName, VBucketDbs,
                        #config{daemon=#daemon_config{min_file_size=MinFileSize},
                                db_fragmentation=FragThreshold}) ->
    NumVBuckets = length(VBucketDbs),
    SampleVBucketIds = unique_random_ints(NumVBuckets, ?NUM_SAMPLE_VBUCKETS),
    SampleVBucketDbs = select_samples(VBucketDbs, SampleVBucketIds),

    {DataSize, FileSize} = aggregated_size_info(SampleVBucketDbs, NumVBuckets),

    file_needs_compaction(BucketName,
                          DataSize, FileSize, FragThreshold,
                          MinFileSize * NumVBuckets).

select_samples(VBucketDbs, SampleIxs) ->
    select_samples(VBucketDbs, SampleIxs, 1, []).

select_samples(_, [], _, Acc) ->
    Acc;
select_samples([], _, _, Acc) ->
    Acc;
select_samples([V | VRest], [S | SRest] = Samples, Ix, Acc) ->
    case Ix =:= S of
        true ->
            select_samples(VRest, SRest, Ix + 1, [V | Acc]);
        false ->
            select_samples(VRest, Samples, Ix + 1, Acc)
    end.

unique_random_ints(Range, NumSamples) ->
    case Range > NumSamples * 2 of
        true ->
            unique_random_ints(Range, NumSamples, ordsets:new());
        false ->
            case NumSamples >= Range of
                true ->
                    lists:seq(1, Range);
                false ->
                    %% if Range is reasonably close to NumSamples, do simpler
                    %% one-pass pick-with-NumSamples/Range probability
                    %% selection. It'll have on average NumSamples samples, and
                    %% I'm ok with that.
                    [I || I <- lists:seq(1, Range),
                          begin
                              {Dice, _} = random:uniform_s(Range, now()),
                              Dice =< NumSamples
                          end]
            end
    end.

unique_random_ints(_, 0, Seen) ->
    Seen;
unique_random_ints(Range, NumSamples, Seen) ->
    {I, _} = random:uniform_s(Range, now()),
    case ordsets:is_element(I, Seen) of
        true ->
            unique_random_ints(Range, NumSamples, Seen);
        false ->
            unique_random_ints(Range, NumSamples - 1,
                               ordsets:add_element(I, Seen))
    end.


file_needs_compaction(Title, DataSize, FileSize, FragThreshold, MinFileSize) ->
    ?log_debug("Estimated size for `~s`: data ~p, file ~p",
               [Title, DataSize, FileSize]),

    case FileSize < MinFileSize of
        true ->
            ?log_debug("Estimated file size for `~s` is less "
                       "than min_file_size ~p; skipping",
                       [Title, MinFileSize]),
            false;
        false ->
            FragSize = FileSize - DataSize,
            Frag = round((FragSize / FileSize) * 100),

            ?log_debug("Estimated fragmentation for `~s`: ~p bytes/~p%",
                       [Title, FragSize, Frag]),

            check_fragmentation(FragThreshold, Frag, FragSize)
    end.

aggregated_size_info(SampleVBucketDbs, NumVBuckets) ->
    NumSamples = length(SampleVBucketDbs),

    {DataSize, FileSize} =
        lists:foldl(
          fun (DbName, {AccDataSize, AccFileSize}) ->
                  {ok, Db} = couch_db:open_int(DbName, []),

                  %% unfortunately I can't just bind this inside try block
                  %% because compiler (seemingly mistakenly) thinks that this
                  %% is unsafe
                  DbInfo =
                      try
                          {ok, Info} = couch_db:get_db_info(Db),
                          Info
                      after
                          couch_db:close(Db)
                      end,

                  VFileSize = proplists:get_value(disk_size, DbInfo),
                  VDataSize = proplists:get_value(data_size, DbInfo, 0),
                  {AccDataSize + VDataSize, AccFileSize + VFileSize}
          end, {0, 0}, SampleVBucketDbs),

    %% rarely our sample selection routine can return zero samples;
    %% we need to handle it
    case NumSamples of
        0 ->
            {0, 0};
        _ ->
            {round(DataSize * (NumVBuckets / NumSamples)),
             round(FileSize * (NumVBuckets / NumSamples))}
    end.

check_fragmentation({FragLimit, FragSizeLimit}, Frag, FragSize) ->
    true = is_integer(FragLimit),
    true = is_integer(FragSizeLimit),

    (Frag >= FragLimit) orelse (FragSize >= FragSizeLimit).

ensure_can_db_compact(Db) ->
    {ok, DbInfo} = couch_db:get_db_info(Db),
    DataSize = proplists:get_value(data_size, DbInfo, 0),
    SpaceRequired = space_required(DataSize),

    {ok, DbDir} = ns_storage_conf:this_node_dbdir(),
    Free = free_space(DbDir),

    case Free >= SpaceRequired of
        true ->
            ok;
        false ->
            ale:error(?USER_LOGGER,
                      "Cannot compact database `~s`: "
                      "the estimated necessary disk space is about ~p bytes "
                      "but the currently available disk space is ~p bytes.",
                      [Db#db.name, SpaceRequired, Free]),
            exit({not_enough_space, Db#db.name, SpaceRequired, Free})
    end.

space_required(DataSize) ->
    round(DataSize * 2.0).

free_space(Path) ->
    Stats = disksup:get_disk_data(),
    {ok, {_, Total, Usage}} =
        ns_storage_conf:extract_disk_stats_for_path(Stats, Path),
    trunc(Total - (Total * (Usage / 100))) * 1024.

view_needs_compaction(BucketName, DDocId, Type,
                      #config{view_fragmentation=FragThreshold,
                              daemon=#daemon_config{min_file_size=MinFileSize}}) ->
    Info = get_group_data_info(BucketName, DDocId, Type),

    case Info of
        disabled ->
            %% replica index can be disabled; so we'll skip it here instead of
            %% spamming logs with irrelevant crash reports
            false;
        _ ->
            InitialBuild = proplists:get_value(initial_build, Info),
            case InitialBuild of
                true ->
                    false;
                false ->
                    FileSize = proplists:get_value(disk_size, Info),
                    DataSize = proplists:get_value(data_size, Info, 0),

                    Title = <<BucketName/binary, $/, DDocId/binary,
                              $/, (atom_to_binary(Type, latin1))/binary>>,
                    file_needs_compaction(Title, DataSize, FileSize,
                                          FragThreshold, MinFileSize)
            end
    end.

ensure_can_view_compact(BucketName, DDocId, Type) ->
    Info = get_group_data_info(BucketName, DDocId, Type),

    DataSize = proplists:get_value(data_size, Info, 0),
    SpaceRequired = space_required(DataSize),

    {ok, ViewsDir} = ns_storage_conf:this_node_ixdir(),
    Free = free_space(ViewsDir),

    case Free >= SpaceRequired of
        true ->
            ok;
        false ->
            ale:error(?USER_LOGGER,
                      "Cannot compact view ~s/~s/~p: "
                      "the estimated necessary disk space is about ~p bytes "
                      "but the currently available disk space is ~p bytes.",
                      [BucketName, DDocId, Type, SpaceRequired, Free]),
            exit({not_enough_space,
                  BucketName, DDocId, SpaceRequired, Free})
    end.

get_group_data_info(BucketName, DDocId, main) ->
    {ok, Info} = couch_set_view:get_group_data_size(BucketName, DDocId),
    Info;
get_group_data_info(BucketName, DDocId, replica) ->
    MainInfo = get_group_data_info(BucketName, DDocId, main),
    proplists:get_value(replica_group_info, MainInfo, disabled).

ddoc_names(BucketName) ->
    {ok, DDocsSet} = capi_set_view_manager:fetch_ddocs(BucketName, infinity),
    sets:to_list(DDocsSet).

search_node_default(Config, Key, Default) ->
    case ns_config:search_node(Config, Key) of
        false ->
            Default;
        {value, Value} ->
            Value
    end.

compaction_daemon_config() ->
    Config = ns_config:get(),
    compaction_daemon_config(Config).

compaction_daemon_config(Config) ->
    Props = search_node_default(Config, compaction_daemon, []),
    daemon_config_to_record(Props).

compaction_config_props(BucketName) ->
    Config = ns_config:get(),
    Global = search_node_default(Config, autocompaction, []),
    BucketConfig = get_bucket(BucketName, Config),
    PerBucket = case proplists:get_value(autocompaction, BucketConfig, []) of
                    false -> [];
                    SomeValue -> SomeValue
                end,

    lists:foldl(
      fun ({Key, _Value} = KV, Acc) ->
              [KV | proplists:delete(Key, Acc)]
      end, Global, PerBucket).

compaction_config(BucketName) ->
    ConfigProps = compaction_config_props(BucketName),
    DaemonConfig = compaction_daemon_config(),
    Config = config_to_record(ConfigProps, DaemonConfig),

    {Config, ConfigProps}.

config_to_record(Config, DaemonConfig) ->
    do_config_to_record(Config, #config{daemon=DaemonConfig}).

do_config_to_record([], Acc) ->
    Acc;
do_config_to_record([{database_fragmentation_threshold, V} | Rest], Acc) ->
   do_config_to_record(
     Rest, Acc#config{db_fragmentation=normalize_fragmentation(V)});
do_config_to_record([{view_fragmentation_threshold, V} | Rest], Acc) ->
    do_config_to_record(
      Rest, Acc#config{view_fragmentation=normalize_fragmentation(V)});
do_config_to_record([{parallel_db_and_view_compaction, V} | Rest], Acc) ->
    do_config_to_record(Rest, Acc#config{parallel_view_compact=V});
do_config_to_record([{allowed_time_period, V} | Rest], Acc) ->
    do_config_to_record(Rest, Acc#config{allowed_period=allowed_period_record(V)});
do_config_to_record([{OtherKey, _V} | _], _Acc) ->
    %% should not happen
    exit({invalid_config_key_bug, OtherKey}).

normalize_fragmentation({Percentage, Size}) ->
    NormPercencentage =
        case Percentage of
            undefined ->
                100;
            _ when is_integer(Percentage) ->
                Percentage
        end,

    NormSize =
        case Size of
            undefined ->
                %% just set it to something really big (to simplify further
                %% logic a little bit)
                1 bsl 64;
            _ when is_integer(Size) ->
                Size
        end,

    {NormPercencentage, NormSize}.


daemon_config_to_record(Config) ->
    do_daemon_config_to_record(Config, #daemon_config{}).

do_daemon_config_to_record([], Acc) ->
    Acc;
do_daemon_config_to_record([{min_file_size, V} | Rest], Acc) ->
    do_daemon_config_to_record(Rest, Acc#daemon_config{min_file_size=V});
do_daemon_config_to_record([{check_interval, V} | Rest], Acc) ->
    do_daemon_config_to_record(Rest, Acc#daemon_config{check_interval=V}).

allowed_period_record(Config) ->
    do_allowed_period_record(Config, #period{}).

do_allowed_period_record([], Acc) ->
    Acc;
do_allowed_period_record([{from_hour, V} | Rest], Acc) ->
    do_allowed_period_record(Rest, Acc#period{from_hour=V});
do_allowed_period_record([{from_minute, V} | Rest], Acc) ->
    do_allowed_period_record(Rest, Acc#period{from_minute=V});
do_allowed_period_record([{to_hour, V} | Rest], Acc) ->
    do_allowed_period_record(Rest, Acc#period{to_hour=V});
do_allowed_period_record([{to_minute, V} | Rest], Acc) ->
    do_allowed_period_record(Rest, Acc#period{to_minute=V});
do_allowed_period_record([{abort_outside, V} | Rest], Acc) ->
    do_allowed_period_record(Rest, Acc#period{abort_outside=V});
do_allowed_period_record([{OtherKey, _V} | _], _Acc) ->
    %% should not happen
    exit({invalid_period_key_bug, OtherKey}).

-spec check_period(#config{}) -> ok.
check_period(#config{allowed_period=undefined}) ->
    ok;
check_period(#config{allowed_period=Period}) ->
    do_check_period(Period).

do_check_period(#period{from_hour=FromHour,
                        from_minute=FromMinute,
                        to_hour=ToHour,
                        to_minute=ToMinute,
                        abort_outside=AbortOutside}) ->
    {HH, MM, _} = erlang:time(),

    Now0 = time_to_minutes(HH, MM),
    From = time_to_minutes(FromHour, FromMinute),
    To0 = time_to_minutes(ToHour, ToMinute),

    To = case To0 < From of
             true ->
                 To0 + 24 * 60;
             false ->
                 To0
         end,

    Now = case Now0 < From of
              true ->
                  Now0 + 24 * 60;
              false ->
                  Now0
          end,

    CanStart = (Now >= From) andalso (Now < To),
    MinutesLeft = To - Now,

    case CanStart of
        true ->
            case AbortOutside of
                true ->
                    shutdown_compactor_after(MinutesLeft),
                    ok;
                false ->
                    ok
            end;
        false ->
            exit(normal)
    end.

time_to_minutes(HH, MM) ->
    HH * 60 + MM.

shutdown_compactor_after(MinutesLeft) ->
    Compactor = self(),

    MillisLeft = MinutesLeft * 60 * 1000,
    ?log_debug("Scheduling a timer to shut "
               "ourselves down in ~p ms", [MillisLeft]),

    spawn_link(
      fun () ->
              process_flag(trap_exit, true),

              receive
                  {'EXIT', Compactor, _Reason} ->
                      ok;
                  Msg ->
                      exit({unexpected_message_bug, Msg})
              after
                  MillisLeft ->
                      ?log_info("Shutting compactor ~p down "
                                "not to abuse allowed time period", [Compactor]),
                      exit(Compactor, shutdown)
              end
      end).

-spec compact_next_bucket(#state{}) -> #state{}.
compact_next_bucket(#state{buckets_to_compact=Buckets} = State) ->
    undefined = State#state.compactor_pid,
    true = [] =/= Buckets,

    NextBucket = hd(Buckets),
    {Config, _ConfigProps} = Configs = compaction_config(NextBucket),
    Compactor = spawn_bucket_compactor(NextBucket, Configs),

    State#state{compactor_pid=Compactor,
                compactor_config=Config}.

-spec schedule_next_compaction(#state{}) -> #state{}.
schedule_next_compaction(#state{compaction_start_ts=StartTs0,
                                buckets_to_compact=Buckets,
                                scheduled_compaction_tref=TRef} = State) ->
    [] = Buckets,
    undefined = TRef,

    Now = now_utc_seconds(),

    StartTs = case StartTs0 of
                  undefined ->
                      Now;
                  _ ->
                      StartTs0
              end,

    #daemon_config{check_interval=CheckInterval} = compaction_daemon_config(),

    Diff = Now - StartTs,

    NewState0 =
        case Diff < CheckInterval of
            true ->
                RepeatIn = (CheckInterval - Diff),
                ?log_debug("Finished compaction too soon. Next run will be in ~ps",
                           [RepeatIn]),
                {ok, NewTRef} = timer:send_after(RepeatIn * 1000, compact),
                State#state{scheduled_compaction_tref=NewTRef};
            false ->
                self() ! compact,
                State
        end,

    NewState0#state{compaction_start_ts=undefined}.

now_utc_seconds() ->
    calendar:datetime_to_gregorian_seconds(erlang:universaltime()).

db_name(BucketName, SubName) when is_list(SubName) ->
    db_name(BucketName, list_to_binary(SubName));
db_name(BucketName, VBucket) when is_integer(VBucket) ->
    db_name(BucketName, integer_to_list(VBucket));
db_name(BucketName, SubName) when is_binary(SubName) ->
    true = is_binary(BucketName),

    <<BucketName/binary, $/, SubName/binary>>.

all_bucket_dbs(BucketName) ->
    BucketConfig = get_bucket(BucketName),
    NodeVBuckets = ns_bucket:all_node_vbuckets(BucketConfig),
    VBucketDbs = [db_name(BucketName, V) || V <- NodeVBuckets],

    [db_name(BucketName, "master") | VBucketDbs].

get_bucket(BucketName) ->
    get_bucket(BucketName, ns_config:get()).

get_bucket(BucketName, Config) ->
    BucketNameStr = binary_to_list(BucketName),

    case ns_bucket:get_bucket(BucketNameStr, Config) of
        not_present ->
            exit({bucket_not_present, BucketName});
        {ok, BucketConfig} ->
            BucketConfig
    end.

multi_sync_send_all_state_event(Event) ->
    Nodes = ns_node_disco:nodes_actual_proper(),

    Results =
        misc:parallel_map(
          fun (Node) ->
                  gen_fsm:sync_send_all_state_event({?MODULE, Node}, Event,
                                                    ?RPC_TIMEOUT)
          end, Nodes, infinity),

    lists:filter(
      fun ({_Node, Result}) ->
              Result =/= ok
      end, lists:zip(Nodes, Results)).

check_all_dbs_exist(BucketName, RequiredDbs) ->
    ExistingDbs = ns_storage_conf:bucket_databases(BucketName),
    SortedRequiredDbs = lists:usort(RequiredDbs),

    case do_check_all_dbs_exist(ExistingDbs, SortedRequiredDbs) of
        ok ->
            ok;
        {missing, M} ->
            ?log_info("Skipping compaction of bucket `~s` since at least "
                      "database `~s` seems to be missing.", [BucketName, M]),
            exit(normal)
    end.

do_check_all_dbs_exist(_, []) ->
    ok;
do_check_all_dbs_exist([], [R | _]) ->
    {missing, R};
do_check_all_dbs_exist([E | ERest] = _Existing,
                       [R | RRest] = Required) ->
    if
        E < R ->
            %% some additional database starting with 'BucketName/'; this is
            %% probably ok
            do_check_all_dbs_exist(ERest, Required);
        E =:= R ->
            do_check_all_dbs_exist(ERest, RRest);
        true ->
            {missing, R}
    end.

bucket_exists(BucketName) ->
    case ns_bucket:get_bucket_light(binary_to_list(BucketName)) of
        {ok, Config} ->
            (ns_bucket:bucket_type(Config) =:= membase) andalso
                lists:member(node(), ns_bucket:bucket_nodes(Config));
        not_present ->
            false
    end.

-spec register_forced_compaction(pid(), #forced_compaction{},
                                 #state{}) -> #state{}.
register_forced_compaction(Pid, Compaction,
                    #state{running_forced_compactions=Compactions,
                           forced_compaction_pids=CompactionPids} = State) ->
    error = dict:find(Compaction, CompactionPids),

    NewCompactions = dict:store(Pid, Compaction, Compactions),
    NewCompactionPids = dict:store(Compaction, Pid, CompactionPids),

    State#state{running_forced_compactions=NewCompactions,
                forced_compaction_pids=NewCompactionPids}.

-spec unregister_forced_compaction(pid(), #state{}) -> #state{}.
unregister_forced_compaction(Pid,
                             #state{running_forced_compactions=Compactions,
                                    forced_compaction_pids=CompactionPids} = State) ->
    Compaction = dict:fetch(Pid, Compactions),

    NewCompactions = dict:erase(Pid, Compactions),
    NewCompactionPids = dict:erase(Compaction, CompactionPids),

    State#state{running_forced_compactions=NewCompactions,
                forced_compaction_pids=NewCompactionPids}.

-spec is_already_being_compacted(#forced_compaction{}, #state{}) -> boolean().
is_already_being_compacted(Compaction,
                           #state{running_forced_compactions=Compactions}) ->
    dict:find(Compaction, Compactions) =/= error.

-spec maybe_cancel_compaction(#forced_compaction{}, #state{}) -> #state{}.
maybe_cancel_compaction(Compaction,
                        #state{forced_compaction_pids=CompactionPids} = State) ->
    case dict:find(Compaction, CompactionPids) of
        error ->
            State;
        {ok, Pid} ->
            exit(Pid, shutdown),
            receive
                %% let all the other exit messages be handled by corresponding
                %% handle_info clause so that error message is logged
                {'EXIT', Pid, shutdown} ->
                    unregister_forced_compaction(Pid, State);
                {'EXIT', Pid, _Reason} = Exit ->
                    {next_state, ignored, NewState} = handle_info(Exit,
                                                                  ignored, State),
                    NewState
            end
    end.
