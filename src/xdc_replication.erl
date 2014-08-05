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

% This module represents a bucket replicator. it's responsible for managing
% vbucket replicators and when the map changes, stopping/starting the vbucket
% replicators.

-module(xdc_replication).
-behaviour(gen_server).

-export([stats/1, target/1, latest_errors/1, update_replication/2]).
-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%% rate of replicaiton stat maintained in bucket replicator
-record(ratestat, {
          timestamp = now(),
          item_replicated = 0,
          data_replicated = 0,
          get_meta_batches = 0,
          get_meta_latency = 0,
          set_meta_batches = 0,
          set_meta_latency = 0,
          activations = 0,
          worker_batches = 0,
          docs_checked = 0,
          docs_opt_repd = 0,
          work_time = 0,
          curr_set_meta_latency_agg = 0,
          curr_get_meta_latency_agg = 0,
          curr_set_meta_batches_rate = 0,
          curr_get_meta_batches_rate = 0,
          curr_rate_item = 0,
          curr_rate_data = 0,
          curr_check_rate_item = 0,
          curr_opt_rate_item = 0,
          curr_activations_rate = 0,
          curr_worker_batches_rate = 0,
          curr_work_time_rate = 0
}).

%% bucket level replication state used by module xdc_replication
-record(replication, {
          rep = #rep{},                    % the basic replication settings
          mode,                            % replication mode
          vbucket_sup,                     % the supervisor for vb replicators
          vbs = [],                        % list of vb we should be replicating
          num_tokens = 0,                  % number of available tokens used by throttles
          init_throttle,                   % limits # of concurrent vb replicators initializing
          work_throttle,                   % limits # of concurrent vb replicators working
          num_active = 0,                  % number of active replicators
          num_waiting = 0,                 % number of waiting replicators

          %% rate of replication
          ratestat = #ratestat{},
          %% history of last N errors
          error_reports = ringbuffer:new(?XDCR_ERROR_HISTORY)
         }).

start_link(Rep) ->
    ?xdcr_info("start XDCR bucket replicator for rep: ~p.", [Rep]),
    gen_server:start_link(?MODULE, [Rep], []).

stats(Pid) ->
    gen_server:call(Pid, stats).

target(Pid) ->
    gen_server:call(Pid, target).

latest_errors(Pid) ->
    gen_server:call(Pid, get_errors).

update_replication(Pid, RepDoc) ->
    gen_server:call(Pid, {update_replication, RepDoc}, infinity).

start_vbucket_rep_sup(#rep{options = Options}) ->
    MaxR = proplists:get_value(supervisor_max_r, Options),
    MaxT = proplists:get_value(supervisor_max_t, Options),
    {ok, Sup} = xdc_vbucket_rep_sup:start_link({{one_for_one, MaxR, MaxT}, []}),
    Sup.

init([#rep{source = SrcBucketBinary, replication_mode = RepMode, options = Options} = Rep]) ->
    %% Subscribe to bucket map changes due to rebalance and failover operations
    %% at the source
    Server = self(),
    NsConfigEventsHandler = fun ({buckets, _} = Evt, _Acc) ->
                                    Server ! Evt;
                                (_, Acc) ->
                                    Acc
                            end,
    ns_pubsub:subscribe_link(ns_config_events, NsConfigEventsHandler, []),
    ?xdcr_debug("ns config event handler subscribed", []),

    MaxConcurrentReps = options_to_num_tokens(Options),
    {ok, InitThrottle} = new_concurrency_throttle:start_link({MaxConcurrentReps, ?XDCR_INIT_CONCUR_THROTTLE}, self()),
    {ok, WorkThrottle} = new_concurrency_throttle:start_link({MaxConcurrentReps, ?XDCR_REPL_CONCUR_THROTTLE}, self()),
    ?xdcr_debug("throttle process created (init throttle: ~p, work throttle: ~p). Tokens count is ~p",
                [InitThrottle, WorkThrottle, MaxConcurrentReps]),
    Sup = start_vbucket_rep_sup(Rep),
    ?x_trace(replicationInit,
             [{repID, Rep#rep.id},
              {source, SrcBucketBinary},
              {target, Rep#rep.target}]),
    case ns_bucket:get_bucket(?b2l(SrcBucketBinary)) of
        {ok, SrcBucketConfig} ->
            Vbs = xdc_rep_utils:my_active_vbuckets(SrcBucketConfig),
            RepState0 = #replication{rep = Rep,
                                     mode = RepMode,
                                     vbs = Vbs,
                                     num_tokens = MaxConcurrentReps,
                                     init_throttle = InitThrottle,
                                     work_throttle = WorkThrottle,
                                     vbucket_sup = Sup},
            {ok, start_vb_replicators(RepState0)};
        Error ->
            ?xdcr_error("fail to fetch a valid bucket config and no vb replicator "
                        "would be created (error: ~p)", [Error]),
            RepState = #replication{rep = Rep,
                                    mode = RepMode,
                                    num_tokens = MaxConcurrentReps,
                                    init_throttle = InitThrottle,
                                    work_throttle = WorkThrottle,
                                    vbucket_sup = Sup},
            {ok, RepState}
    end.

handle_call(stats, _From, #replication{rep = #rep{id = RepId} = Rep,
                                       num_active  = ActiveVbReps,
                                       ratestat = OldRateStat,
                                       num_waiting = WaitingVbReps} = State) ->

    [Sample] = ets:lookup(xdcr_stats, RepId),
    #xdcr_stats_sample{
       %% data_replicated = DataReplicated,
       docs_checked = DocsChecked,
       docs_written = DocsWritten,
       %% docs_opt_repd = DocsOptRepd,
       succeeded_checkpoints = OkCheckpoints,
       failed_checkpoints = FailedCheckpoints,
       work_time = WorkTime,
       commit_time = CommitTime
      } = Sample,
    VbSamplesMS = ets:fun2ms(
                    fun (#xdcr_vb_stats_sample{id_and_vb = {I, _},
                                               vbucket_seqno = VS,
                                               through_seqno = TS
                                              })
                          when I =:= RepId, VS >= TS ->
                            VS - TS
                    end),
    ChangesLeft = lists:sum(ets:select(xdcr_stats, VbSamplesMS)),

    RequestedReps = options_to_num_tokens(Rep#rep.options),

    NewRateStat = compute_rate_stat(Sample, OldRateStat),

    WorkTimeRate0 = NewRateStat#ratestat.curr_work_time_rate * 1.0E-6,

    WorkTimeRate = case WorkTimeRate0 > RequestedReps of
                       true ->
                           %% clamp to tokens count to deal with token
                           %% count changes
                           RequestedReps;
                       _ ->
                           WorkTimeRate0
                   end,

    Props = [{changes_left, ChangesLeft},
             {docs_checked, DocsChecked},
             {docs_written, DocsWritten},
             {active_vbreps, ActiveVbReps},
             {max_vbreps, RequestedReps},
             {waiting_vbreps, WaitingVbReps},
             {time_working, WorkTime * 1.0E-6},
             {time_committing, CommitTime * 1.0E-6},
             {time_working_rate, WorkTimeRate},
             {num_checkpoints, OkCheckpoints + FailedCheckpoints},
             {num_failedckpts, FailedCheckpoints},
             {wakeups_rate, NewRateStat#ratestat.curr_activations_rate},
             {worker_batches_rate, NewRateStat#ratestat.curr_worker_batches_rate},
             {rate_replication, NewRateStat#ratestat.curr_rate_item},
             {bandwidth_usage, NewRateStat#ratestat.curr_rate_data},
             {rate_doc_checks, NewRateStat#ratestat.curr_check_rate_item},
             {rate_doc_opt_repd, NewRateStat#ratestat.curr_opt_rate_item},
             {meta_latency_aggr, NewRateStat#ratestat.curr_get_meta_latency_agg},
             {meta_latency_wt, NewRateStat#ratestat.curr_get_meta_batches_rate},
             {docs_latency_aggr, NewRateStat#ratestat.curr_set_meta_latency_agg},
             {docs_latency_wt, NewRateStat#ratestat.curr_set_meta_batches_rate}],

    {reply, {ok, Props}, State#replication{ratestat = NewRateStat}};

handle_call(target, _From, State) ->
    {reply, {ok, (State#replication.rep)#rep.target}, State};

handle_call(get_errors, _From, State) ->
    {reply, {ok, ringbuffer:to_list(State#replication.error_reports)}, State};

handle_call({update_replication, NewRep}, _From,
            #replication{rep = OldRep,
                         init_throttle = InitThrottle,
                         work_throttle = WorkThrottle} = State) ->
    #rep{id = RepId} = OldRep,

    case NewRep#rep{options=[]} =:= OldRep#rep{options=[]} of
        true ->
            #rep{options = NewOptions0} = NewRep,
            #rep{options = OldOptions0} = OldRep,

            NewOptions = lists:keysort(1, NewOptions0),
            OldOptions = lists:keysort(1, OldOptions0),

            OldDistinct = OldOptions -- NewOptions,
            NewDistinct = NewOptions -- OldOptions,

            ?xdcr_debug("Options updated for replication ~s:~n~p ->~n~p",
                        [RepId, OldDistinct, NewDistinct]),

            NewTokens = options_to_num_tokens(NewOptions),

            case NewTokens =/= State#replication.num_tokens of
                true ->
                    ?xdcr_debug("total number of tokens has been changed from ~p to ~p, "
                                "adjust work throttle (pid: ~p) accordingly",
                                [State#replication.num_tokens, NewTokens, WorkThrottle]),
                    new_concurrency_throttle:change_tokens(InitThrottle, NewTokens),
                    new_concurrency_throttle:change_tokens(WorkThrottle, NewTokens);
                _->
                    ok
            end,

            %% replication documents differ only in options; no restart is
            %% needed
            {reply, ok, State#replication{rep = NewRep, num_tokens = NewTokens}};
        false ->
            #rep{source = NewSource, target = NewTarget} = NewRep,
            ?xdcr_debug("replication doc (docId: ~s) modified: source ~s, target ~s;"
                        "replication will be restarted",
                        [RepId, NewSource, misc:sanitize_url(NewTarget)]),

            {reply, restart_needed, State}
    end;

handle_call(Msg, From, State) ->
    ?xdcr_error("replication manager received unexpected call ~p from ~p",
                [Msg, From]),
    {stop, {error, {unexpected_call, Msg}}, State}.

handle_cast({report_error, Err}, #replication{error_reports = Errs} = State) ->
    {noreply, State#replication{error_reports = ringbuffer:add(Err, Errs)}};

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

handle_info({set_throttle_status, {NumActiveReps, NumWaitingReps}},
            State) ->
    {noreply, State#replication{num_active = NumActiveReps,
                                num_waiting = NumWaitingReps}};

handle_info({buckets, Buckets0},
            #replication{rep = #rep{source = SrcBucket} = Rep,
                         vbucket_sup = Sup} = State) ->
    %% The source vbucket map may have changed
    Buckets = consume_all_buckets_changes(Buckets0),
    Configs = proplists:get_value(configs, Buckets),
    case proplists:get_value(?b2l(SrcBucket), Configs) of
        undefined ->
            % our bucket went away or never existed
            xdc_vbucket_rep_sup:shutdown(Sup),
            Sup2 = start_vbucket_rep_sup(Rep),
            ?xdcr_debug("bucket gone or never existed, shut down current vb rep "
                        "supervisor: ~p and create a new one :~p", [Sup, Sup2]),
            {noreply, State#replication{vbucket_sup = Sup2}};
        SrcConfig ->
            NewVbs = xdc_rep_utils:my_active_vbuckets(SrcConfig),
            NewState =
                case (State#replication.vbs == NewVbs) of
                true ->
                    %% no change, skip it
                    State;
                _ ->
                    ?xdcr_debug("vbucket map changed for bucket ~p "
                                "adjust replicators for new vbs :~p",
                                [?b2l(SrcBucket), NewVbs]),
                    start_vb_replicators(State#replication{vbs = NewVbs})
                end,
            {noreply, NewState}
    end.


terminate(_Reason, #replication{vbucket_sup = Sup}) ->
    xdc_vbucket_rep_sup:shutdown(Sup),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

start_vb_replicators(#replication{rep = Rep,
                                  mode = RepMode,
                                  vbucket_sup = Sup,
                                  init_throttle = InitThrottle,
                                  work_throttle = WorkThrottle,
                                  vbs = Vbs} = Replication) ->
    CurrentVbs = xdc_vbucket_rep_sup:vbucket_reps(Sup),
    NewVbs = Vbs -- CurrentVbs,
    RemovedVbs = CurrentVbs -- Vbs,
    % now delete the removed Vbs
    ?xdcr_debug("deleting replicator for expired vbs :~p", [RemovedVbs]),
    lists:foreach(
      fun(RemoveVb) ->
              ok = xdc_vbucket_rep_sup:stop_vbucket_rep(Sup, RemoveVb),
              ets:delete(xdcr_stats, {Rep#rep.id, RemoveVb}),
              ?x_trace(stoppedVbRep,
                       [{repID, Rep#rep.id},
                        {vb, RemoveVb}])
      end, RemovedVbs),
    % now start the new Vbs
    ?xdcr_debug("starting replicators for new vbs :~p", [NewVbs]),
    lists:foreach(
      fun(Vb) ->
              ets:insert(xdcr_stats, #xdcr_vb_stats_sample{id_and_vb = {Rep#rep.id, Vb}}),

              {ok, Pid} = xdc_vbucket_rep_sup:start_vbucket_rep(Sup,
                                                                Rep,
                                                                Vb,
                                                                InitThrottle,
                                                                WorkThrottle,
                                                                self(),
                                                                RepMode),
              ?x_trace(startedVbRep,
                       [{repID, Rep#rep.id},
                        {vb, Vb},
                        {childPID, Pid}])
      end, misc:shuffle(NewVbs)),
    Replication.


%% compute the replicaiton rate, and return the new rate stat
-spec compute_rate_stat(#xdcr_stats_sample{}, #ratestat{}) -> #ratestat{}.
compute_rate_stat(#xdcr_stats_sample{docs_written = Written1,
                                     data_replicated = DataRepd1,
                                     docs_checked = NewChecked,
                                     docs_opt_repd = NewOptRepd,
                                     get_meta_batches = NewGetMetaBatches,
                                     get_meta_latency = NewGetMetaLatency,
                                     set_meta_batches = NewSetMetaBatches,
                                     set_meta_latency = NewSetMetaLatency,
                                     activations = NewActivations,
                                     worker_batches = NewWorkerBatches,
                                     work_time = NewWorkTime},
                  #ratestat{
                     timestamp = T1,
                     item_replicated = OldWritten,
                     data_replicated = OldRepd,
                     get_meta_batches = OldGetMetaBatches,
                     get_meta_latency = OldGetMetaLatency,
                     set_meta_batches = OldSetMetaBatches,
                     set_meta_latency = OldSetMetaLatency,
                     activations = OldActivations,
                     worker_batches = OldWorkerBatches,
                     docs_checked = OldChecked,
                     docs_opt_repd = OldOptRepd,
                     work_time = OldWorkTime
                    } = RateStat) ->
    T2 = os:timestamp(),
    %% compute elapsed time in microsecond
    Delta = timer:now_diff(T2, T1),
    %% convert from us to secs
    DeltaMilliSecs = Delta / 1000,
    %% to smooth the stats, only compute rate when interval is big enough
    Interval = ns_config:read_key_fast(xdcr_rate_stat_interval_ms, ?XDCR_RATE_STAT_INTERVAL_MS),
    NewRateStat = case DeltaMilliSecs < Interval of
                      true ->
                          %% sampling interval is too small,
                          %% just return the last results
                          RateStat;
                      _ ->
                          InvDeltaSec = 1.0E3 / DeltaMilliSecs,
                          GetMetaLatencyDiff = NewGetMetaLatency - OldGetMetaLatency,
                          SetMetaLatencyDiff = NewSetMetaLatency - OldSetMetaLatency,
                          GetMetaBatchesDiff = NewGetMetaBatches - OldGetMetaBatches,
                          SetMetaBatchesDiff = NewSetMetaBatches - OldSetMetaBatches,
                          GetMetaBatchesRate = GetMetaBatchesDiff * InvDeltaSec,
                          SetMetaBatchesRate = SetMetaBatchesDiff * InvDeltaSec,
                          ActivationsDiff = NewActivations - OldActivations,
                          WorkerBatchesDiff = NewWorkerBatches - OldWorkerBatches,
                          CheckedDiff = NewChecked - OldChecked,
                          OptRepdDiff = NewOptRepd - OldOptRepd,
                          WorkTimeDiff = NewWorkTime - OldWorkTime,
                          %% compute vb replicator rate stat
                          %% replication rate in terms of # items per second
                          RateItem1 = (Written1 - OldWritten) * InvDeltaSec,
                          %% replicaiton rate in terms of bytes per second
                          RateData1 = (DataRepd1 - OldRepd) * InvDeltaSec,
                          %% NOTE:
                          %% average latency is latency_diff / batches_diff
                          %%
                          %% Because final computation is done in
                          %% menelaus_stats (after aggregating
                          %% latencies and batches from all node) and
                          %% because we don't maintain batches_diff,
                          %% but rather batches_rate (batches_diff /
                          %% delta), we also divide latency diff by
                          %% delta so that deltas cancel when
                          %% latency_agg is divided by batches rate.
                          %%
                          %% 1E-3 factor is due to conversion from
                          %% microseconds to milliseconds
                          LatencyCoeff = InvDeltaSec * 1.0E-3,
                          %% update rate stat
                          RateStat#ratestat{timestamp = T2,
                                            item_replicated = Written1,
                                            data_replicated = DataRepd1,
                                            curr_rate_item = RateItem1,
                                            curr_rate_data = RateData1,
                                            get_meta_batches = NewGetMetaBatches,
                                            set_meta_batches = NewSetMetaBatches,
                                            get_meta_latency = NewGetMetaLatency,
                                            set_meta_latency = NewSetMetaLatency,
                                            activations = NewActivations,
                                            worker_batches = NewWorkerBatches,
                                            docs_checked = NewChecked,
                                            docs_opt_repd = NewOptRepd,
                                            work_time = NewWorkTime,
                                            curr_get_meta_latency_agg = GetMetaLatencyDiff * LatencyCoeff,
                                            curr_set_meta_latency_agg = SetMetaLatencyDiff * LatencyCoeff,
                                            curr_get_meta_batches_rate = GetMetaBatchesRate,
                                            curr_set_meta_batches_rate = SetMetaBatchesRate,
                                            curr_activations_rate = ActivationsDiff * InvDeltaSec,
                                            curr_worker_batches_rate = WorkerBatchesDiff * InvDeltaSec,
                                            curr_check_rate_item = CheckedDiff * InvDeltaSec,
                                            curr_opt_rate_item = OptRepdDiff * InvDeltaSec,
                                            curr_work_time_rate = WorkTimeDiff * InvDeltaSec
                                           }
                  end,

    NewRateStat.

options_to_num_tokens(Options) ->
    case proplists:get_bool(pause_requested, Options) of
        true ->
            0;
        _ ->
            proplists:get_value(max_concurrent_reps, Options)
    end.
