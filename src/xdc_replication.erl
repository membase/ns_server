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

-export([stats/1, target/1, latest_errors/1]).
-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").

start_link(Rep) ->
    ?xdcr_info("start XDCR bucket replicator for rep: ~p.", [Rep]),
    gen_server:start_link(?MODULE, [Rep], []).

stats(Pid) ->
    gen_server:call(Pid, stats).

target(Pid) ->
    gen_server:call(Pid, target).

latest_errors(Pid) ->
    gen_server:call(Pid, get_errors).

init([#rep{source = SrcBucketBinary} = Rep]) ->
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

    MaxConcurrentReps = misc:getenv_int("MAX_CONCURRENT_REPS_PER_DOC",
                                        ?MAX_CONCURRENT_REPS_PER_DOC),
    SrcSize = size(SrcBucketBinary),
    NotifyFun = fun({updated, {<<Src:SrcSize/binary, $/, VbStr/binary>>, _}})
                            when Src == SrcBucketBinary->
                        VbName = binary_to_list(VbStr),
                        %% if with view, we may see "master" db update msg
                        case VbName =:= "master" of
                            true ->
                                ok;
                            %% if not master db, it should be a vbucket update
                            _ ->
                                Vb = list_to_integer(VbName),
                                Server ! {src_db_updated, Vb}
                        end;
                   (_Evt) ->
                        ok
                end,

    {ok, _} = couch_db_update_notifier:start_link(NotifyFun),
    ?xdcr_debug("couch_db update notifier started", []),
    {ok, InitThrottle} = concurrency_throttle:start_link(MaxConcurrentReps, self()),
    {ok, WorkThrottle} = concurrency_throttle:start_link(MaxConcurrentReps, self()),
    ?xdcr_debug("throttle process created (init throttle: ~p, work throttle: ~p)",
                [InitThrottle, WorkThrottle]),
    {ok, Sup} = xdc_vbucket_rep_sup:start_link([]),
    case ns_bucket:get_bucket(?b2l(SrcBucketBinary)) of
        {ok, SrcBucketConfig} ->
            Vbs = xdc_rep_utils:my_active_vbuckets(SrcBucketConfig),
            RepState0 = #replication{rep = Rep,
                                     vbs = Vbs,
                                     init_throttle = InitThrottle,
                                     work_throttle = WorkThrottle,
                                     vbucket_sup = Sup},
            RepState = start_vb_replicators(RepState0);
        Error ->
            ?xdcr_error("fail to fetch a valid bucket config and no vb replicator "
                        "would be created (error: ~p)", [Error]),
            RepState = #replication{rep = Rep,
                                    init_throttle = InitThrottle,
                                    work_throttle = WorkThrottle,
                                    vbucket_sup = Sup}
    end,
    {ok, RepState}.

handle_call(stats, _From, #replication{vb_rep_dict = Dict,
                                       num_active  = ActiveVbReps,
                                       num_waiting = WaitingVbReps} = State) ->
    % sum all the vb stats and collect list of vb replicating
    Stats = dict:fold(
                    fun(_,
                        #rep_vb_status{vb = Vb,
                                       status = Status,
                                       num_changes_left = Left,
                                       num_checkpoints = NumCheckpoint,
                                       num_failedckpts = NumFailedCkpts,
                                       docs_changes_queue = DocsQueue,
                                       size_changes_queue = SizeQueue,
                                       docs_checked = Checked,
                                       docs_written = Written,
                                       data_replicated = DataRepd,
                                       total_work_time = WorkTime,
                                       total_commit_time = CommitTime},
                        {WorkLeftAcc,
                         CheckedAcc,
                         WrittenAcc,
                         DataRepdAcc,
                         WorkTimeAcc,
                         CommitTimeAcc,
                         NumCkptAcc,
                         NumFailedCkptAcc,
                         DocsQueueAcc,
                         SizeQueueAcc,
                         VbReplicatingAcc}) ->
                                {WorkLeftAcc + Left,
                                 CheckedAcc + Checked,
                                 WrittenAcc + Written,
                                 DataRepdAcc + DataRepd,
                                 WorkTimeAcc + WorkTime,
                                 CommitTimeAcc + CommitTime,
                                 NumCkptAcc + NumCheckpoint,
                                 NumFailedCkptAcc + NumFailedCkpts,
                                 DocsQueueAcc + DocsQueue,
                                 SizeQueueAcc + SizeQueue,
                                 if Status == replicating ->
                                     [Vb | VbReplicatingAcc];
                                 true ->
                                     VbReplicatingAcc
                                 end}
                        end, {0, 0, 0, 0,
                              0, 0, 0, 0,
                              0, 0, []}, Dict),
    {Left1, Checked1, Written1, DataRepd1,
     WorkTime1, CommitTime1, NumCheckpoints1,
     NumFailedCkpts1, DocsChangesQueue1, SizeChangesQueue1, VbsReplicating1} = Stats,
    Props = [{changes_left, Left1},
             {docs_checked, Checked1},
             {docs_written, Written1},
             {data_replicated, DataRepd1},
             {active_vbreps, ActiveVbReps},
             {waiting_vbreps, WaitingVbReps},
             {time_working, WorkTime1 div 1000},
             {time_committing, CommitTime1 div 1000},
             {num_checkpoints, NumCheckpoints1},
             {num_failedckpts, NumFailedCkpts1},
             {docs_rep_queue, DocsChangesQueue1},
             {size_rep_queue, SizeChangesQueue1},
             {vbs_replicating, VbsReplicating1}],
    {reply, {ok, Props}, State};

handle_call(target, _From, State) ->
    {reply, {ok, (State#replication.rep)#rep.target}, State};

handle_call(get_errors, _From, State) ->
    {reply, {ok, ringbuffer:to_list(State#replication.error_reports)}, State};

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

handle_info({src_db_updated, Vb}, #replication{vb_rep_dict = Dict} = State) ->
    case dict:find(Vb, Dict) of
        {ok, #rep_vb_status{pid = Pid}} ->
            Pid ! src_db_updated;
        error ->
            % no state yet, or already erased
            ok
    end,
    {noreply, State};

handle_info({set_vb_rep_status, #rep_vb_status{vb = Vb} = NewStat},
            #replication{vb_rep_dict = Dict} = State) ->
    Stat = case dict:is_key(Vb, Dict) of
               false ->
                   %% first time the vb rep post the stat
                   NewStat;
                _ ->
                   %% already exists an entry in stat table
                   %% compute accumulated stats
                   OldStat = dict:fetch(Vb, Dict),
                   OldDocsChecked = OldStat#rep_vb_status.docs_checked,
                   OldDocsWritten = OldStat#rep_vb_status.docs_written,
                   OldDataRepd = OldStat#rep_vb_status.data_replicated,
                   OldWorkTime = OldStat#rep_vb_status.total_work_time,
                   OldCkptTime = OldStat#rep_vb_status.total_commit_time,
                   OldNumCkpts = OldStat#rep_vb_status.num_checkpoints,
                   OldNumFailedCkpts = OldStat#rep_vb_status.num_failedckpts,

                   %% compute accumulated stats
                   AccuDocsChecked = OldDocsChecked + NewStat#rep_vb_status.docs_checked,
                   AccuDocsWritten = OldDocsWritten + NewStat#rep_vb_status.docs_written,
                   AccuDataRepd = OldDataRepd + NewStat#rep_vb_status.data_replicated,
                   AccuWorkTime = OldWorkTime + NewStat#rep_vb_status.total_work_time,
                   AccuCkptTime = OldCkptTime + NewStat#rep_vb_status.total_commit_time,
                   AccuNumCkpts = OldNumCkpts + NewStat#rep_vb_status.num_checkpoints,
                   AccuNumFailedCkpts = OldNumFailedCkpts + NewStat#rep_vb_status.num_failedckpts,

                   %% update with the accumulated stats
                   NewStat#rep_vb_status{
                     docs_checked = AccuDocsChecked,
                     docs_written = AccuDocsWritten,
                     data_replicated = AccuDataRepd,
                     total_work_time = AccuWorkTime,
                     total_commit_time = AccuCkptTime,
                     num_checkpoints = AccuNumCkpts,
                     num_failedckpts = AccuNumFailedCkpts}
           end,

    Dict2 = dict:store(Vb, Stat, Dict),
    {noreply, State#replication{vb_rep_dict = Dict2}};

handle_info({set_throttle_status, {NumActiveReps, NumWaitingReps}},
            State) ->
    {noreply, State#replication{num_active = NumActiveReps,
                                num_waiting = NumWaitingReps}};

handle_info({buckets, Buckets0},
            #replication{rep = #rep{source = SrcBucket},
                         vbucket_sup = Sup} = State) ->
    %% The source vbucket map may have changed
    Buckets = consume_all_buckets_changes(Buckets0),
    Configs = proplists:get_value(configs, Buckets),
    case proplists:get_value(?b2l(SrcBucket), Configs) of
        undefined ->
            % our bucket went away or never existed
            xdc_vbucket_rep_sup:shutdown(Sup),
            {ok, Sup2} = xdc_vbucket_rep_sup:start_link([]),
            ?xdcr_debug("bucket gone or never existed, shut down current vb rep "
                        "supervisor: ~p and create a new one :~p", [Sup, Sup2]),
            NewState = State#replication{vbucket_sup = Sup2};
        SrcConfig ->
            NewVbs = xdc_rep_utils:my_active_vbuckets(SrcConfig),
            ?xdcr_debug("vbucket map changed for bucket ~p "
                        "adjust replicators for new vbs :~p", [?b2l(SrcBucket), NewVbs]),
            NewState = start_vb_replicators(State#replication{vbs = NewVbs})
    end,
    {noreply, NewState}.


terminate(_Reason, #replication{vbucket_sup = Sup}) ->
    xdc_vbucket_rep_sup:shutdown(Sup),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

start_vb_replicators(#replication{rep = Rep,
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
                        dict:erase(RemoveVb, DictAcc)
                end, Dict, RemovedVbs),
    % now start the new Vbs
    ?xdcr_debug("starting replicators for new vbs :~p", [NewVbs]),
    lists:foreach(
                fun(Vb) ->
                        {ok, _Pid} = xdc_vbucket_rep_sup:start_vbucket_rep(Sup,
                                                                           Rep,
                                                                           Vb,
                                                                           InitThrottle,
                                                                           WorkThrottle,
                                                                           self())
                end, misc:shuffle(NewVbs)),
    Replication#replication{vb_rep_dict = Dict2}.
