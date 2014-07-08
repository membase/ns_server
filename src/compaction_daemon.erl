-module(compaction_daemon).

-behaviour(gen_fsm).

-include("ns_common.hrl").
-include("couch_db.hrl").

%% API
-export([start_link/0,
         inhibit_view_compaction/3, uninhibit_view_compaction/3]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         code_change/4, terminate/3]).

-record(state, {buckets_to_compact :: [binary()],
                compactor_pid,
                compactor_config,
                scheduler,

                %% bucket for which view compaction is inhibited (note
                %% it's also set when we're running 'uninhibit' views
                %% compaction as 'final stage')
                view_compaction_inhibited_bucket :: undefined | binary(),
                %% if view compaction is inhibited this field will
                %% hold monitor ref of the guy who requested it. If
                %% that guy dies, inhibition will be canceled
                view_compaction_inhibited_ref :: (undefined | reference()),
                %% when we have 'uninhibit' request, we're starting
                %% our compaction with 'forced' view compaction asap
                %%
                %% requested indicates we have this request
                view_compaction_uninhibit_requested = false :: boolean(),
                %% started indicates we have started such compaction
                %% and waiting for it to complete
                view_compaction_uninhibit_started = false :: boolean(),
                %% this is From to reply to when such compaction is
                %% done
                view_compaction_uninhibit_requested_waiter,

                %% mapping from compactor pid to #forced_compaction{}
                running_forced_compactions,
                %% reverse mapping from #forced_compaction{} to compactor pid
                forced_compaction_pids}).

-record(config, {db_fragmentation,
                 view_fragmentation,
                 allowed_period,
                 parallel_view_compact = false,
                 do_purge = false,
                 daemon}).

-record(daemon_config, {check_interval,
                        min_file_size}).

-record(period, {from_hour,
                 from_minute,
                 to_hour,
                 to_minute,
                 abort_outside}).

-record(forced_compaction, {type :: bucket | bucket_purge | db | view,
                            name :: binary()}).

%% API
start_link() ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).


get_last_rebalance_or_failover_timestamp() ->
    case ns_config:search_raw(ns_config:get(), counters) of
        {value, [{'_vclock', VClock} | _]} ->
            GregorianSecondsTS = vclock:get_latest_timestamp(VClock),
            GregorianSecondsTS - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}});
        _ -> 0
    end.


%% While Pid is alive prevents autocompaction of views for given
%% bucket and given node. Returned Ref can be used to uninhibit
%% autocompaction.
%%
%% If views of given bucket are being compacted right now, it'll wait
%% for end of compaction rather than aborting it.
%%
%% Attempt to inhibit already inhibited compaction will result in nack.
%%
%% Note: we assume that caller of both inhibit_view_compaction and
%% uninhibit_view_compaction is somehow related to Pid and will die
%% automagically if Pid dies, because autocompaction daemon may
%% actually forget about this calls.
-spec inhibit_view_compaction(bucket_name(), node(), pid()) ->
                                     {ok, reference()} | nack.
inhibit_view_compaction(Bucket, Node, Pid) ->
    gen_fsm:sync_send_all_state_event({?MODULE, Node},
                                      {inhibit_view_compaction, list_to_binary(Bucket), Pid},
                                      infinity).


%% Using Ref returned from inhibit_view_compaction undoes it's
%% effect. It'll also consider kicking views autocompaction for given
%% bucket asap. And it's do it _before_ replying.
-spec uninhibit_view_compaction(bucket_name(), node(), reference()) -> ok | nack.
uninhibit_view_compaction(Bucket, Node, Ref) ->
    gen_fsm:sync_send_all_state_event({?MODULE, Node},
                                      {uninhibit_view_compaction, list_to_binary(Bucket), Ref},
                                      infinity).

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

    CheckInterval = get_check_interval(ns_config:get()),

    Self ! compact,
    {ok, idle, #state{buckets_to_compact=[],
                      compactor_pid=undefined,
                      compactor_config=undefined,
                      scheduler = compaction_scheduler:init(CheckInterval, compact),
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
handle_sync_event({force_purge_compact_bucket, Bucket}, _From, StateName, State) ->
    Compaction = #forced_compaction{type=bucket_purge, name=Bucket},

    NewState =
        case is_already_being_compacted(Compaction, State) of
            true ->
                State;
            false ->
                {Config, Props} = compaction_config(Bucket),
                Pid = spawn_bucket_compactor(Bucket,
                    {Config#config{do_purge = true}, Props}, true),
                State1 = register_forced_compaction(Pid, Compaction, State),
                ale:info(?USER_LOGGER,
                         "Started deletion purge compaction for bucket `~s`",
                         [Bucket]),
                State1
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
                OriginalTarget = {[{type, db}]},
                Pid = spawn_dbs_compactor(Bucket, Config, true, OriginalTarget),
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
                OriginalTarget = {[{type, view},
                                   {name, DDocId}]},
                Pid = spawn_view_compactor(Bucket, DDocId, Config, true,
                                           OriginalTarget),
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
handle_sync_event({inhibit_view_compaction, BinBucketName, Pid}, From, StateName,
                  #state{view_compaction_inhibited_ref = OldRef,
                         view_compaction_uninhibit_requested = UninhibitRequested,
                         buckets_to_compact = BucketsToCompact} = State) ->
    case OldRef =/= undefined orelse UninhibitRequested of
        true ->
            gen_server:reply(From, nack),
            {next_state, StateName, State};
        _ ->
            MRef = erlang:monitor(process, Pid),
            NewState = State#state{
                         view_compaction_inhibited_bucket = BinBucketName,
                         view_compaction_inhibited_ref = MRef,
                         view_compaction_uninhibit_requested = false},
            case StateName =:= compacting andalso hd(BucketsToCompact) =:= BinBucketName of
                true ->
                    ?log_info("Killing currently running compactor to handle inhibit_view_compaction request for ~s", [BinBucketName]),
                    erlang:exit(NewState#state.compactor_pid, shutdown);
                false ->
                    ok
            end,
            {reply, {ok, MRef}, StateName, NewState}
    end;
handle_sync_event({uninhibit_view_compaction, BinBucketName, MRef}, From, StateName,
                  #state{view_compaction_inhibited_bucket = ABinBucketName,
                         view_compaction_inhibited_ref = AnMRef,
                         view_compaction_uninhibit_requested = false} = State)
  when AnMRef =:= MRef andalso ABinBucketName =:= BinBucketName ->
    State1 = case StateName of
                 compacting ->
                     ?log_info("Killing current compactor to speed up uninhibit_view_compaction: ~p", [State]),
                     erlang:exit(State#state.compactor_pid, shutdown),
                     State;
                 idle ->
                     schedule_immediate_compaction(State)
             end,
    erlang:demonitor(State#state.view_compaction_inhibited_ref),
    {next_state, StateName, State1#state{view_compaction_uninhibit_requested_waiter = From,
                                         view_compaction_inhibited_ref = undefined,
                                         view_compaction_uninhibit_started = false,
                                         view_compaction_uninhibit_requested = true}};
handle_sync_event({uninhibit_view_compaction, _BinBucketName, _MRef} = Msg, _From, StateName, State) ->
    ?log_debug("Sending back nack on uninhibit_view_compaction: ~p, state: ~p", [Msg, State]),
    {reply, nack, StateName, State};
handle_sync_event(Event, _From, StateName, State) ->
    ?log_warning("Got unexpected sync event ~p (when in ~p):~n~p",
                 [Event, StateName, State]),
    {reply, ok, StateName, State}.

handle_info(compact, idle,
            #state{buckets_to_compact=Buckets0,
                   scheduler = Scheduler} = State) ->
    undefined = State#state.compactor_pid,

    Buckets =
        case Buckets0 of
            [] ->
                lists:map(fun list_to_binary/1,
                          ns_bucket:node_bucket_names_of_type(node(), membase));
            _ ->
                Buckets0
        end,

    case Buckets of
        [] ->
            ?log_debug("No buckets to compact. Rescheduling compaction."),
            {next_state, idle, State#state{scheduler =
                                               compaction_scheduler:schedule_next(Scheduler)}};
        _ ->
            ?log_debug("Starting compaction for the following buckets: ~n~p",
                       [Buckets]),
            NewState1 = State#state{buckets_to_compact=Buckets,
                                    scheduler=
                                        compaction_scheduler:start_now(Scheduler)},
            NewState = compact_next_bucket(NewState1),
            {next_state, compacting, NewState}
    end;
handle_info({'DOWN', MRef, _, _, _}, StateName, #state{view_compaction_inhibited_ref=MRef,
                                                       view_compaction_inhibited_bucket=BinBucket}=State) ->
    ?log_debug("Looks like vbucket mover inhibiting view compaction for for bucket \"~s\" is dead."
               " Canceling inhibition", [BinBucket]),
    {next_state, StateName, State#state{view_compaction_inhibited_ref = undefined,
                                        view_compaction_inhibited_bucket = undefined}};
handle_info({'EXIT', Compactor, Reason}, compacting,
            #state{compactor_pid=Compactor,
                   buckets_to_compact=Buckets,
                   scheduler=Scheduler} = State) ->
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

    {DoneBucket, NewBuckets} =
        case Reason of
            shutdown ->
                %% this can happen either on config change or if compaction
                %% has been stopped due to end of allowed time period; in the
                %% latter case there's no need to compact bucket again; but it
                %% won't hurt: compaction shall be terminated rightaway with
                %% reason normal
                {undefined, Buckets};
            _ ->
                {hd(Buckets), tl(Buckets)}
        end,

    NewState0 = case (DoneBucket =:= State#state.view_compaction_inhibited_bucket
                      andalso State#state.view_compaction_uninhibit_started) of
                    true ->
                        gen_server:reply(State#state.view_compaction_uninhibit_requested_waiter, ok),
                        State#state{view_compaction_inhibited_bucket = undefined,
                                    view_compaction_uninhibit_requested_waiter = undefined,
                                    view_compaction_uninhibit_requested = false,
                                    view_compaction_uninhibit_started = false};
                    _ ->
                        State
                end,

    NewState1 = NewState0#state{compactor_pid=undefined,
                                compactor_config=undefined,
                                buckets_to_compact=NewBuckets},
    case NewBuckets of
        [] ->
            ?log_debug("Finished compaction iteration."),
            {next_state, idle, NewState1#state{scheduler =
                                                   compaction_scheduler:schedule_next(Scheduler)}};
        _ ->
            {next_state, compacting, compact_next_bucket(NewState1)}
    end;
handle_info({'EXIT', Pid, Reason}, StateName,
            #state{running_forced_compactions=Compactions} = State) ->
    case dict:find(Pid, Compactions) of
        {ok, #forced_compaction{type=Type, name=Name}} ->
            case Reason of
                normal ->
                    case Type of
                        bucket_purge ->
                            ale:info(?USER_LOGGER,
                                     "Purge deletion compaction of bucket `~s` completed",
                                     [Name]);
                        _ ->
                            ale:info(?USER_LOGGER,
                                     "User-triggered compaction of ~p `~s` completed.",
                                     [Type, Name])
                    end;
                _ ->
                    case Type of
                        bucket_purge ->
                            ale:info(?USER_LOGGER,
                                     "Purge deletion compaction of bucket `~s` failed: ~p. "
                                     "See logs for detailed reason.",
                                     [Name, Reason]);
                        _ ->
                            ale:error(?USER_LOGGER,
                                      "User-triggered compaction of ~p `~s` failed: ~p. "
                                      "See logs for detailed reason.",
                                      [Type, Name, Reason])
                    end
            end,

            {next_state, StateName, unregister_forced_compaction(Pid, State)};
        error ->
            ?log_error("Unexpected process termination ~p: ~p. Dying.",
                       [Pid, Reason]),
            {stop, Reason, State}
    end;
handle_info(config_changed, StateName,
            #state{scheduler = Scheduler} = State) ->
    misc:flush(config_changed),
    Config = ns_config:get(),
    CheckInterval = get_check_interval(Config),
    NewScheduler = compaction_scheduler:set_interval(CheckInterval, Scheduler),

    case StateName of
        compacting ->
            maybe_restart_compactor(Config, State);
        idle ->
            ok
    end,

    {next_state, StateName, State#state{scheduler = NewScheduler}};
handle_info(Info, StateName, State) ->
    ?log_warning("Got unexpected message ~p (when in ~p):~n~p",
                 [Info, StateName, State]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

maybe_restart_compactor(NewConfig, #state{compactor_pid=Compactor,
                                          buckets_to_compact=[CompactedBucket|_],
                                          compactor_config=Config}) ->
    {MaybeNewConfig, _} = compaction_config(NewConfig, CompactedBucket),
    case MaybeNewConfig =:= Config of
        true ->
            ok;
        false ->
            ?log_info("Restarting compactor ~p since "
                      "autocompaction config has changed", [Compactor]),
            exit(Compactor, shutdown)
    end.

get_check_interval(Config) ->
    #daemon_config{check_interval=CheckInterval} = compaction_daemon_config(Config),
    CheckInterval.

%% Internal functions
-spec spawn_bucket_compactor(binary(), {#config{}, list()}, boolean() | view_inhibited) -> pid().
spawn_bucket_compactor(BucketName, {Config, ConfigProps}, Force) ->
    proc_lib:spawn_link(
      fun () ->
              case Force of
                  true ->
                      ok;
                  _ ->
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

              try_to_cleanup_indexes(BucketName),

              ?log_info("Compacting bucket ~s with config: ~n~p",
                        [BucketName, ConfigProps]),

              DDocNames = ddoc_names(BucketName),

              OriginalTarget = {[{type, bucket}]},
              DbsCompactor =
                  [{type, database},
                   {important, true},
                   {name, BucketName},
                   {fa, {fun spawn_dbs_compactor/4,
                         [BucketName, Config, Force =:= true, OriginalTarget]}}],

              DDocCompactors =
                  case Force =/= view_inhibited of
                      true ->
                          [ [{type, view},
                             {name, <<BucketName/binary, $/, DDocId/binary>>},
                             {important, false},
                             {fa, {fun spawn_view_compactor/5,
                                   [BucketName, DDocId, Config, Force =:= true, OriginalTarget]}}] ||
                              DDocId <- DDocNames ];
                      _ ->
                          []
                  end,

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

try_to_cleanup_indexes(BucketName) ->
    ?log_info("Cleaning up indexes for bucket `~s`", [BucketName]),

    try
        couch_set_view:cleanup_index_files(mapreduce_view, BucketName)
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
    MasterDbName = db_name(BucketName, <<"master">>),
    case couch_db:open_int(MasterDbName, []) of
        {ok, Db} ->
            try
                couch_view:cleanup_index_files(Db)
            catch
                ViewE:ViewT ->
                    ?log_error(
                       "Error while doing cleanup of old "
                       "index files for database `~s`: ~p~n~p",
                       [MasterDbName, {ViewT, ViewE}, erlang:get_stacktrace()])
            after
                couch_db:close(Db)
            end;
        Error ->
            ?log_error("Failed to open database `~s`: ~p",
                       [MasterDbName, Error])
    end.

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
              Total = length(VBucketDbs),

              DoCompact =
                  case Force of
                      true ->
                          ?log_info("Forceful compaction of bucket ~s requested",
                                    [BucketName]),
                          true;
                      false ->
                          bucket_needs_compaction(BucketName, Total - 1, Config)
                  end,

              DoCompact orelse exit(normal),

              ?log_info("Compacting databases for bucket ~s", [BucketName]),

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

              {Options, SafeViewSeqs} =
                  case Config#config.do_purge of
                      true ->
                          {{0, 0, true}, []};
                      _ ->
                          {NowMegaSec, NowSec, _} = os:timestamp(),
                          NowEpoch = NowMegaSec * 1000000 + NowSec,

                          Interval0 = compaction_api:get_purge_interval(BucketName) * 3600 * 24,
                          Interval = erlang:round(Interval0),

                          PurgeTS0 = NowEpoch - Interval,

                          RebTS = get_last_rebalance_or_failover_timestamp(),

                          PurgeTS = case RebTS > PurgeTS0 of
                                        true ->
                                            RebTS - Interval;
                                        false ->
                                            PurgeTS0
                                    end,

                          {{PurgeTS, 0, false}, capi_set_view_manager:get_safe_purge_seqs(BucketName)}
                  end,



              Compactors =
                  [ [{type, vbucket},
                     {name, element(2, VBucketAndDbName)},
                     {important, false},
                     {fa, {fun spawn_vbucket_compactor/5,
                           [BucketName, VBucketAndDbName, Config, Force,
                            make_per_vbucket_compaction_options(Options, VBucketAndDbName, SafeViewSeqs)]}},
                     {on_success,
                      {fun update_bucket_compaction_progress/2, [Ix, Total]}}] ||
                      {Ix, VBucketAndDbName} <- misc:enumerate(VBucketDbs) ],

              process_flag(trap_exit, true),
              do_chain_compactors(Parent, Compactors),

              ?log_info("Finished compaction of databases for bucket ~s",
                        [BucketName])
      end).

make_per_vbucket_compaction_options({TS, 0, DD} = GeneralOption, {Vb, _}, SafeViewSeqs) ->
    case lists:keyfind(Vb, 1, SafeViewSeqs) of
        false ->
            GeneralOption;
        {_, Seq} ->
            {TS, Seq, DD}
    end.

update_bucket_compaction_progress(Ix, Total) ->
    Progress = (Ix * 100) div Total,
    ok = couch_task_status:update(
           [{vbuckets_done, Ix},
            {progress, Progress}]).

open_db(BucketName, {VBucket, DbName}) ->
    case couch_db:open_int(DbName, []) of
        {ok, Db} ->
            {ok, Db};
        {not_found, no_db_file} = NotFoundError ->
            %% It can be a real error which we don't want to hide. But at the
            %% same time it can be a result of, for instance, rebalance. In
            %% the second case we can expect many databases to be missing. So
            %% we don't want all the resulting harmless errors be spamming the
            %% log. To handle this we will check if the vbucket corresponding
            %% to the database still belongs to our node according to vbucket
            %% map. And if it's not the case we'll indicate that the error can
            %% be ignored.
            case is_integer(VBucket) of
                true ->
                    BucketConfig = get_bucket(BucketName),
                    NodeVBuckets = ns_bucket:all_node_vbuckets(BucketConfig),

                    case ordsets:is_element(VBucket, NodeVBuckets) of
                        true ->
                            %% this is a real error we want to report
                            NotFoundError;
                        false ->
                            vbucket_moved
                    end;
                false ->
                    NotFoundError
            end;
         Error ->
            Error
    end.

open_db_or_fail(BucketName, {_, DbName} = VBucketAndDbName) ->
    case open_db(BucketName, VBucketAndDbName) of
        {ok, Db} ->
            Db;
        vbucket_moved ->
            exit(normal);
        Error ->
            ?log_error("Failed to open database `~s`: ~p", [DbName, Error]),
            exit({open_db_failed, Error})
    end.

vbucket_needs_compaction({DataSize, FileSize}, Config) ->
    #config{daemon=#daemon_config{min_file_size=MinFileSize},
            db_fragmentation=FragThreshold} = Config,

    file_needs_compaction(DataSize, FileSize, FragThreshold, MinFileSize).

get_master_db_size_info(BucketName, VBucketAndDb) ->
    Db = open_db_or_fail(BucketName, VBucketAndDb),

    try
        {ok, DbInfo} = couch_db:get_db_info(Db),

        {proplists:get_value(data_size, DbInfo, 0),
         proplists:get_value(disk_size, DbInfo)}
    after
        couch_db:close(Db)
    end.

get_db_size_info(Bucket, VBucket) ->
    {ok, Props} = ns_memcached:get_vbucket_details_stats(Bucket, VBucket),

    {list_to_integer(proplists:get_value("db_data_size", Props)),
     list_to_integer(proplists:get_value("db_file_size", Props))}.

maybe_compact_vbucket(BucketName, {VBucket, DbName} = VBucketAndDb,
                      Config, Force, Options) ->
    Bucket = binary_to_list(BucketName),

    SizeInfo = case VBucket of
                   master ->
                       get_master_db_size_info(BucketName, VBucketAndDb);
                   _ ->
                       get_db_size_info(Bucket, VBucket)
               end,

    case Force orelse vbucket_needs_compaction(SizeInfo, Config) of
        true ->
            ok;
        false ->
            exit(normal)
    end,

    %% effectful
    ensure_can_db_compact(DbName, SizeInfo),

    ?log_info("Compacting `~s' (~p)", [DbName, Options]),
    Ret = case VBucket of
              master ->
                  compact_master_vbucket(BucketName, DbName);
              _ ->
                  ns_memcached:compact_vbucket(Bucket, VBucket, Options)
          end,
    ?log_info("Compaction of ~p has finished with ~p", [DbName, Ret]),
    Ret.

spawn_vbucket_compactor(BucketName, VBucketAndDb, Config, Force, Options) ->
    proc_lib:spawn_link(
      fun () ->
              case maybe_compact_vbucket(BucketName, VBucketAndDb, Config, Force, Options) of
                  ok ->
                      ok;
                  Result ->
                      exit(Result)
              end
      end).

compact_master_vbucket(BucketName, DbName) ->
    Db = open_db_or_fail(BucketName, {master, DbName}),
    process_flag(trap_exit, true),

    {ok, Compactor} = couch_db:start_compact(Db, [dropdeletes]),

    CompactorRef = erlang:monitor(process, Compactor),

    receive
        {'EXIT', _Parent, Reason} = Exit ->
            ?log_debug("Got exit signal from parent: ~p", [Exit]),

            erlang:demonitor(CompactorRef),
            ok = couch_db:cancel_compact(Db),
            Reason;
        {'DOWN', CompactorRef, process, Compactor, normal} ->
            ok;
        {'DOWN', CompactorRef, process, Compactor, noproc} ->
            %% compactor died before we managed to monitor it;
            %% we will treat this as an error
            {db_compactor_died_too_soon, DbName};
        {'DOWN', CompactorRef, process, Compactor, Reason} ->
            Reason
    end.

spawn_view_compactor(BucketName, DDocId, Config, Force, OriginalTarget) ->
    Parent = self(),

    proc_lib:spawn_link(
      fun () ->
              process_flag(trap_exit, true),

              Compactors =
                  [ [{type, view},
                     {important, true},
                     {name, view_name(BucketName, DDocId, Type)},
                     {fa, {fun spawn_view_index_compactor/6,
                           [BucketName, DDocId,
                            Type, Config, Force, OriginalTarget]}}] ||
                      Type <- [main, replica] ],

              do_chain_compactors(Parent, Compactors)
      end).

view_name(BucketName, DDocId, Type) ->
    <<BucketName/binary, $/, DDocId/binary, $/,
      (atom_to_binary(Type, latin1))/binary>>.

spawn_view_index_compactor(BucketName, DDocId,
                           Type, Config, Force, OriginalTarget) ->
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

              TriggerType = case Force of
                                true ->
                                    manual;
                                false ->
                                    scheduled
                            end,

              InitialStatus = [{original_target, OriginalTarget},
                               {trigger_type, TriggerType}],

              do_spawn_view_index_compactor(Parent, BucketName,
                                            DDocId, Type, InitialStatus),

              ?log_info("Finished compacting indexes for ~s", [ViewName])
      end).

do_spawn_view_index_compactor(Parent, BucketName, DDocId, Type, InitialStatus) ->
    Compactor = start_view_index_compactor(BucketName, DDocId,
                                           Type, InitialStatus),
    CompactorRef = erlang:monitor(process, Compactor),

    receive
        {'EXIT', Parent, Reason} = Exit ->
            ?log_debug("Got exit signal from parent: ~p", [Exit]),

            erlang:demonitor(CompactorRef),
            ok = couch_set_view_compactor:cancel_compact(mapreduce_view,
                                                         BucketName, DDocId,
                                                         Type, prod),
            exit(Reason);
        {'DOWN', CompactorRef, process, Compactor, normal} ->
            ok;
        {'DOWN', CompactorRef, process, Compactor, noproc} ->
            exit({index_compactor_died_too_soon,
                  BucketName, DDocId, Type});
        {'DOWN', CompactorRef, process, Compactor, Reason}
          when Reason =:= shutdown;
               Reason =:= {updater_died, shutdown};
               Reason =:= {updated_died, noproc};
               Reason =:= {updater_died, {updater_error, shutdown}} ->
            do_spawn_view_index_compactor(Parent, BucketName,
                                          DDocId, Type, InitialStatus);
        {'DOWN', CompactorRef, process, Compactor, Reason} ->
            exit(Reason)
    end.

start_view_index_compactor(BucketName, DDocId, Type, InitialStatus) ->
    case couch_set_view_compactor:start_compact(mapreduce_view, BucketName,
                                                DDocId, Type, prod,
                                                InitialStatus) of
        {ok, Pid} ->
            Pid;
        {error, initial_build} ->
            exit(normal)
    end.

bucket_needs_compaction(BucketName, NumVBuckets,
                        #config{daemon=#daemon_config{min_file_size=MinFileSize},
                                db_fragmentation=FragThreshold}) ->
    {DataSize, FileSize} = aggregated_size_info(binary_to_list(BucketName)),

    ?log_debug("`~s` data size is ~p, disk size is ~p",
               [BucketName, DataSize, FileSize]),

    file_needs_compaction(DataSize, FileSize,
                          FragThreshold, MinFileSize * NumVBuckets).

file_needs_compaction(DataSize, FileSize, FragThreshold, MinFileSize) ->
    %% NOTE: If there are no vbuckets on this node MinFileSize will be
    %% 0 so less then or _equals_ is really important to avoid
    %% division by zero
    case FileSize =< MinFileSize of
        true ->
            false;
        false ->
            FragSize = FileSize - DataSize,
            Frag = round((FragSize / FileSize) * 100),

            check_fragmentation(FragThreshold, Frag, FragSize)
    end.

aggregated_size_info(Bucket) ->
    {ok, {DS, FS}} =
        ns_memcached:raw_stats(node(), Bucket, <<"diskinfo">>,
                               fun (<<"ep_db_file_size">>, V, {DataSize, _}) ->
                                       {DataSize, V};
                                   (<<"ep_db_data_size">>, V, {_, FileSize}) ->
                                       {V, FileSize};
                                   (_, _, Tuple) ->
                                       Tuple
                               end, {<<"0">>, <<"0">>}),
    {list_to_integer(binary_to_list(DS)),
     list_to_integer(binary_to_list(FS))}.

check_fragmentation({FragLimit, FragSizeLimit}, Frag, FragSize) ->
    true = is_integer(FragLimit),
    true = is_integer(FragSizeLimit),

    (Frag >= FragLimit) orelse (FragSize >= FragSizeLimit).

ensure_can_db_compact(DbName, {DataSize, _}) ->
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
                      [DbName, SpaceRequired, Free]),
            exit({not_enough_space, DbName, SpaceRequired, Free})
    end.

space_required(DataSize) ->
    round(DataSize * 2.0).

free_space(Path) ->
    Stats = ns_disksup:get_disk_data(),
    {ok, RealPath} = misc:realpath(Path, "/"),
    {ok, {_, Total, Usage}} =
        ns_storage_conf:extract_disk_stats_for_path(Stats, RealPath),
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

                    ?log_debug("`~s/~s/~s` data_size is ~p, disk_size is ~p",
                               [BucketName, DDocId, Type, DataSize, FileSize]),

                    file_needs_compaction(DataSize, FileSize,
                                          FragThreshold, MinFileSize)
            end
    end.

ensure_can_view_compact(BucketName, DDocId, Type) ->
    Info = get_group_data_info(BucketName, DDocId, Type),

    case Info of
        disabled ->
            exit(normal);
        _ ->
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
            end
    end.

get_group_data_info(BucketName, DDocId, main) ->
    {ok, Info} = couch_set_view:get_group_data_size(mapreduce_view,
                                                    BucketName, DDocId),
    Info;
get_group_data_info(BucketName, DDocId, replica) ->
    MainInfo = get_group_data_info(BucketName, DDocId, main),
    proplists:get_value(replica_group_info, MainInfo, disabled).

ddoc_names(BucketName) ->
    capi_ddoc_replication_srv:fetch_ddoc_ids(BucketName).

search_node_default(Config, Key, Default) ->
    case ns_config:search_node(Config, Key) of
        false ->
            Default;
        {value, Value} ->
            Value
    end.

compaction_daemon_config(Config) ->
    Props = search_node_default(Config, compaction_daemon, []),
    daemon_config_to_record(Props).

compaction_config_props(Config, BucketName) ->
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
    compaction_config(ns_config:get(), BucketName).

compaction_config(Config, BucketName) ->
    ConfigProps = compaction_config_props(Config, BucketName),
    DaemonConfig = compaction_daemon_config(Config),
    ConfigRecord = config_to_record(ConfigProps, DaemonConfig),

    {ConfigRecord, ConfigProps}.

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
do_config_to_record([{_OtherKey, _V} | Rest], Acc) ->
    %% NOTE !!!: releases before 2.2.0 raised error here
    do_config_to_record(Rest, Acc).

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
compact_next_bucket(#state{buckets_to_compact=Buckets,
                           view_compaction_inhibited_bucket = InhibitedBucket} = State) ->
    undefined = State#state.compactor_pid,
    true = [] =/= Buckets,

    PausedBucket = case State of
                       #state{view_compaction_inhibited_bucket = CandidatePausedBucket,
                              view_compaction_uninhibit_requested = true} ->
                           CandidatePausedBucket;
                       _ ->
                           undefined
                   end,

    Buckets1 = case PausedBucket =/= undefined of
                   true ->
                       [PausedBucket | lists:delete(PausedBucket, Buckets)];
                   _ ->
                       Buckets
               end,

    NextBucket = hd(Buckets1),

    {InitialConfig, _ConfigProps} = Configs0 = compaction_config(NextBucket),
    Configs = case PausedBucket =/= undefined of
                  true ->
                      ?log_debug("Going to spawn bucket compaction with forced view compaction for bucket ~s", [NextBucket]),
                      {OldConfig, OldConfigProps} = Configs0,
                      %% for 'uninhibit' compaction we don't want to
                      %% wait for db compaction because we assume DBs
                      %% are going to be much bigger than views. Plus
                      %% we _do_ need to wait for index compaction,
                      %% but we don't need to wait for db compaction.
                      {OldConfig#config{view_fragmentation = {0, 0},
                                        db_fragmentation = {100, 1 bsl 64},
                                        allowed_period = undefined},
                       [forced_previously_inhibited_view_compaction | OldConfigProps]};
                  _ ->
                      Configs0
              end,

    MaybeViewInhibited = case State of
                             #state{view_compaction_inhibited_bucket = InhibitedBucket,
                                    view_compaction_uninhibit_requested = false}
                               when InhibitedBucket =:= NextBucket ->
                                 {paused, undefined} = {paused, PausedBucket},
                                 view_inhibited;
                             _ ->
                                 false
                         end,

    Compactor = spawn_bucket_compactor(NextBucket, Configs, MaybeViewInhibited),

    case PausedBucket =/= undefined of
        true ->
            ?log_debug("Spawned 'uninhibited' compaction for ~s", [PausedBucket]),
            master_activity_events:note_forced_inhibited_view_compaction(PausedBucket),
            {next_bucket, NextBucket} = {next_bucket, PausedBucket},
            {next_bucket, InhibitedBucket} = {next_bucket, PausedBucket},
            State#state{compactor_pid = Compactor,
                        compactor_config = InitialConfig,
                        view_compaction_uninhibit_started = true};
        _ ->
            State#state{compactor_pid = Compactor,
                        compactor_config = InitialConfig}
    end.

-spec schedule_immediate_compaction(#state{}) -> #state{}.
schedule_immediate_compaction(#state{buckets_to_compact=Buckets,
                                     compactor_pid=Compactor,
                                     scheduler=Scheduler} = State0) ->
    [] = Buckets,
    undefined = Compactor,

    State1 = State0#state{scheduler=compaction_scheduler:cancel(Scheduler)},
    self() ! compact,
    State1.

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
    VBucketDbs = [{V, db_name(BucketName, V)} || V <- NodeVBuckets],

    [{master, db_name(BucketName, "master")} | VBucketDbs].

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
                           #state{forced_compaction_pids=CompactionPids}) ->
    dict:find(Compaction, CompactionPids) =/= error.

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
