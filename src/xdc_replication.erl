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

%% rate of replicaiton stat maintained in bucket replicator
-record(ratestat, {
          timestamp = now(),
          item_replicated = 0,
          data_replicated = 0,
          curr_rate_item = 0,
          curr_rate_data = 0
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
          vb_rep_dict = dict:new(),        % contains state and stats for each replicator

          %% rate of replication
          ratestat = #ratestat{},
          %% history of last N errors
          error_reports = ringbuffer:new(?XDCR_ERROR_HISTORY),
          %% history of last N checkpoints
          checkpoint_history = ringbuffer:new(?XDCR_CHECKPOINT_HISTORY)
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
    ThrottleMod = case ns_config:read_key_fast(xdcr_use_old_throttle, false) of
                      true ->
                          concurrency_throttle;
                      _ ->
                          new_concurrency_throttle
                  end,
    {ok, InitThrottle} = ThrottleMod:start_link({MaxConcurrentReps, ?XDCR_INIT_CONCUR_THROTTLE}, self()),
    {ok, WorkThrottle} = ThrottleMod:start_link({MaxConcurrentReps, ?XDCR_REPL_CONCUR_THROTTLE}, self()),
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

handle_call(stats, _From, #replication{vb_rep_dict = Dict,
                                       rep = Rep,
                                       num_active  = ActiveVbReps,
                                       num_waiting = WaitingVbReps,
                                       checkpoint_history = CkptHistory} = State) ->

    % sum all the vb stats and collect list of vb replicating
    Stats = dict:fold(
                    fun(_,
                        #rep_vb_status{status = Status,
                                       num_changes_left = Left,
                                       docs_changes_queue = DocsQueue,
                                       size_changes_queue = SizeQueue,
                                       docs_checked = Checked,
                                       docs_written = Written,
                                       docs_opt_repd = DocsOptRepd,
                                       data_replicated = DataRepd,
                                       work_time = WorkTime,
                                       commit_time = CommitTime,
                                       meta_latency_aggr = MetaLatency,
                                       meta_latency_wt = MetaLatencyWt,
                                       docs_latency_aggr = DocsLatency,
                                       docs_latency_wt = DocsLatencyWt},
                        {WorkLeftAcc,
                         CheckedAcc,
                         WrittenAcc,
                         DataRepdAcc,

                         WorkTimeAcc,
                         CommitTimeAcc,
                         DocsQueueAcc,
                         SizeQueueAcc,

                         MetaLatencyAcc,
                         MetaLatencyWtAcc,
                         DocsLatencyAcc,
                         DocsLatencyWtAcc,

                         DocsOptRepdAcc}) ->

                            %% only count replicating vb reps when computing latency stats and replication rates
                            {MetaL, MetaLWt} = case Status of
                                                   replicating ->
                                                       {MetaLatency, MetaLatencyWt};
                                                   _ -> {0, 0}
                                               end,
                            {DocsL, DocsLWt} = case Status of
                                                 replicating ->
                                                     {DocsLatency, DocsLatencyWt};
                                                 _ -> {0, 0}
                                             end,

                            {WorkLeftAcc + Left,
                             CheckedAcc + Checked,
                             WrittenAcc + Written,
                             DataRepdAcc + DataRepd,

                             WorkTimeAcc + WorkTime,
                             CommitTimeAcc + CommitTime,
                             DocsQueueAcc + DocsQueue,
                             SizeQueueAcc + SizeQueue,

                             MetaLatencyAcc + MetaL,
                             MetaLatencyWtAcc + MetaLWt,
                             DocsLatencyAcc + DocsL,
                             DocsLatencyWtAcc + DocsLWt,

                             DocsOptRepdAcc + DocsOptRepd}
                    end, {0, 0, 0, 0,
                          0, 0, 0, 0,
                          0, 0, 0, 0,
                          0}, Dict),
    {Left1, Checked1, Written1, DataRepd1,
     WorkTime1, CommitTime1, DocsChangesQueue1, SizeChangesQueue1,
     MetaLatency1, MetaLatencyWt1, DocsLatency1, DocsLatencyWt1,
     DocsOptRepd1} = Stats,
    %% get checkpoint stats
    {NumCheckpoints1, NumFailedCkpts1} = checkpoint_status(CkptHistory),

    NewRateStat = compute_rate_stat(Written1, DataRepd1, State#replication.ratestat),

    RequestedReps = options_to_num_tokens(Rep#rep.options),

    Props = [{changes_left, Left1},
             {docs_checked, Checked1},
             {docs_written, Written1},
             {docs_opt_repd, DocsOptRepd1},
             {data_replicated, DataRepd1},
             {active_vbreps, ActiveVbReps},
             {max_vbreps, RequestedReps},
             {waiting_vbreps, WaitingVbReps},
             {time_working, WorkTime1 div 1000},
             {time_committing, CommitTime1 div 1000},
             {num_checkpoints, NumCheckpoints1},
             {num_failedckpts, NumFailedCkpts1},
             {docs_rep_queue, DocsChangesQueue1},
             {size_rep_queue, SizeChangesQueue1},
             {rate_replication, round(NewRateStat#ratestat.curr_rate_item)},
             {bandwidth_usage, round(NewRateStat#ratestat.curr_rate_data)},
             {meta_latency_aggr, round(MetaLatency1)},
             {meta_latency_wt, MetaLatencyWt1},
             {docs_latency_aggr, round(DocsLatency1)},
             {docs_latency_wt, DocsLatencyWt1}],
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
                    concurrency_throttle:change_tokens(InitThrottle, NewTokens),
                    concurrency_throttle:change_tokens(WorkThrottle, NewTokens);
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

handle_info({set_vb_rep_status, #rep_vb_status{vb = Vb} = NewStat},
            #replication{vb_rep_dict = Dict} = State) ->
    Stat = case dict:is_key(Vb, Dict) of
               false ->
                   %% first time the vb rep post the stats
                   NewStat;
                _ ->
                   %% already exists an entry in stat table
                   %% compute accumulated stats
                   OldStat = dict:fetch(Vb, Dict),
                   OldDocsChecked = OldStat#rep_vb_status.docs_checked,
                   OldDocsWritten = OldStat#rep_vb_status.docs_written,
                   OldDocsOptRepd = OldStat#rep_vb_status.docs_opt_repd,
                   OldDataRepd = OldStat#rep_vb_status.data_replicated,
                   OldWorkTime = OldStat#rep_vb_status.work_time,
                   OldCkptTime = OldStat#rep_vb_status.commit_time,
                   OldNumCkpts = OldStat#rep_vb_status.num_checkpoints,
                   OldNumFailedCkpts = OldStat#rep_vb_status.num_failedckpts,

                   %% compute accumulated stats
                   AccuDocsChecked = OldDocsChecked + NewStat#rep_vb_status.docs_checked,
                   AccuDocsWritten = OldDocsWritten + NewStat#rep_vb_status.docs_written,
                   AccuDocsOptRepd = OldDocsOptRepd + NewStat#rep_vb_status.docs_opt_repd,
                   AccuDataRepd = OldDataRepd + NewStat#rep_vb_status.data_replicated,
                   AccuWorkTime = OldWorkTime + NewStat#rep_vb_status.work_time,
                   AccuCkptTime = OldCkptTime + NewStat#rep_vb_status.commit_time,
                   AccuNumCkpts = OldNumCkpts + NewStat#rep_vb_status.num_checkpoints,
                   AccuNumFailedCkpts = OldNumFailedCkpts + NewStat#rep_vb_status.num_failedckpts,

                   %% update with the accumulated stats
                   NewStat#rep_vb_status{
                     docs_checked = AccuDocsChecked,
                     docs_written = AccuDocsWritten,
                     docs_opt_repd = AccuDocsOptRepd,
                     data_replicated = AccuDataRepd,
                     work_time = AccuWorkTime,
                     commit_time = AccuCkptTime,
                     num_checkpoints = AccuNumCkpts,
                     num_failedckpts = AccuNumFailedCkpts}
           end,

    Dict2 = dict:store(Vb, Stat, Dict),
    {noreply, State#replication{vb_rep_dict = Dict2}};

handle_info({set_checkpoint_status, #rep_checkpoint_status{vb = VBucket,
                                                           ts = TimeStamp,
                                                           time = TimeString,
                                                           succ = Succ}},
            #replication{checkpoint_history = CkptHistory, rep = Rep} = State) ->

    Entry = {TimeStamp, TimeString, VBucket, Succ},
    NewCkptHistory = ringbuffer:add(Entry, CkptHistory),

    ?xdcr_debug("add a ckpt entry (~p) to ckpt history of replication (src: ~p, target: ~p)",
                [Entry, Rep#rep.source, Rep#rep.target]),

    {noreply, State#replication{checkpoint_history = NewCkptHistory}};

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
                                  vbs = Vbs,
                                  vb_rep_dict = Dict} = Replication) ->
    CurrentVbs = xdc_vbucket_rep_sup:vbucket_reps(Sup),
    NewVbs = Vbs -- CurrentVbs,
    RemovedVbs = CurrentVbs -- Vbs,
    % now delete the removed Vbs
    ?xdcr_debug("deleting replicator for expired vbs :~p", [RemovedVbs]),
    Dict2 = lists:foldl(
                fun(RemoveVb, DictAcc) ->
                        ok = xdc_vbucket_rep_sup:stop_vbucket_rep(Sup, RemoveVb),
                        ?x_trace(stoppedVbRep,
                                 [{repID, Rep#rep.id},
                                  {vb, RemoveVb}]),
                        dict:erase(RemoveVb, DictAcc)
                end, Dict, RemovedVbs),
    % now start the new Vbs
    ?xdcr_debug("starting replicators for new vbs :~p", [NewVbs]),
    Dict3 = lists:foldl(
              fun(Vb, DictAcc) ->
                      {ok, Pid} = xdc_vbucket_rep_sup:start_vbucket_rep(Sup,
                                                                        Rep,
                                                                        Vb,
                                                                        InitThrottle,
                                                                        WorkThrottle,
                                                                        self(),
                                                                        RepMode),
                      VbStatus = #rep_vb_status{pid = Pid},
                      ?x_trace(startedVbRep,
                               [{repID, Rep#rep.id},
                                {vb, Vb},
                                {childPID, Pid}]),
                      dict:store(Vb, VbStatus, DictAcc)
              end, Dict2, misc:shuffle(NewVbs)),
    ?xdcr_debug("total number of started vb replicator: ~p", [dict:size(Dict3)]),
    Replication#replication{vb_rep_dict = Dict3}.

%% get the number of succ and failed checkpoints from checkpoint history
checkpoint_status(CheckpointHistory) ->
    %% get most recent N entry in history
    HistoryList = ringbuffer:to_list(?XDCR_CHECKPOINT_HISTORY, CheckpointHistory),

    %% count # of successful ckpts and failed ckpts
    {NumSuccCkpts, NumFailedCkpts} = lists:foldl(
                                       fun ({_TimeStamp, _TimeString, _Vb, Succ}, {SuccAcc, FailedAcc}) ->
                                               case Succ of
                                                   true ->
                                                       {SuccAcc + 1, FailedAcc};
                                                   false ->
                                                       {SuccAcc, FailedAcc + 1}
                                               end
                                       end,
                                       {0, 0},
                                       HistoryList),
    {NumSuccCkpts, NumFailedCkpts}.



%% compute the replicaiton rate, and return the new rate stat
-spec compute_rate_stat(integer(), integer(), #ratestat{}) -> #ratestat{}.
compute_rate_stat(Written1, DataRepd1, RateStat) ->
    T2 = os:timestamp(),
    T1 = RateStat#ratestat.timestamp,
    %% compute elapsed time in microsecond
    Delta = timer:now_diff(T2, T1),
    %% convert from us to secs
    DeltaMilliSecs = Delta / 1000,
    %% to smooth the stats, only compute rate when interval is big enough
    Interval = misc:getenv_int("XDCR_RATE_STAT_INTERVAL_MS", ?XDCR_RATE_STAT_INTERVAL_MS),
    NewRateStat = case DeltaMilliSecs < Interval of
                      true ->
                          %% sampling interval is too small,
                          %% just return the last results
                          RateStat;
                      _ ->
                          %% compute vb replicator rate stat
                          %% replication rate in terms of # items per second
                          RateItem1 = (1000*(Written1 - RateStat#ratestat.item_replicated)) / DeltaMilliSecs,
                          %% replicaiton rate in terms of bytes per second
                          RateData1 = (1000*(DataRepd1 - RateStat#ratestat.data_replicated)) / DeltaMilliSecs,
                          %% update rate stat
                          RateStat#ratestat{timestamp = T2,
                                            item_replicated = Written1,
                                            data_replicated = DataRepd1,
                                            curr_rate_item = RateItem1,
                                            curr_rate_data = RateData1
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
