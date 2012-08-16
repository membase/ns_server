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

-export([stats/1]).
-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").

-record(replication, {
    rep,                    % the basic replication settings
    vbucket_sup,            % the supervisor for vb replicators
    vbs = [],               % list of vb we should be replicating
    concurrency_throttle,   % limits # of concurrent vb replicators
    vb_rep_dict = dict:new()% contains state and stats for each replicator
    }).


start_link(Rep) ->
    gen_server:start_link(?MODULE, [Rep], []).

stats(Pid) ->
    gen_server:call(Pid, stats).


init([#rep{source = SrcBucketBinary} = Rep]) ->
    %% Subscribe to bucket map changes due to rebalance and failover operations
    %% at the source
    Server = self(),
    NsConfigEventsHandler = fun ({buckets, _} = Evt, _Acc) ->
                                    Server ! Evt;
                                (_, Acc) ->
                                    Acc
                            end,
                        ?xdcr_error("initting 0", []),
    ns_pubsub:subscribe_link(ns_config_events, NsConfigEventsHandler, []),

    MaxConcurrentReps = misc:getenv_int("MAX_CONCURRENT_REPS_PER_DOC",
                                        ?MAX_CONCURRENT_REPS_PER_DOC),
    SrcSize = size(SrcBucketBinary),
    NotifyFun = fun({updated, {<<Src:SrcSize/binary, $/, VbStr/binary>>, _}})
                            when Src == SrcBucketBinary->
                        Vb = list_to_integer(binary_to_list(VbStr)),
                        Server ! {src_db_updated, Vb};
                    (_Evt) ->
                        ok
                end,
    ?xdcr_error("initting 1", []),
    {ok, _} = couch_db_update_notifier:start_link(NotifyFun),
?xdcr_error("initting 2", []),
    {ok, Throttle} = concurrency_throttle:start_link(MaxConcurrentReps),
?xdcr_error("initting 3", []),
    {ok, Sup} = xdc_vbucket_rep_sup:start_link([]),
?xdcr_error("initting 4", []),
    case ns_bucket:get_bucket(?b2l(SrcBucketBinary)) of
    {ok, SrcBucketConfig} ->
        Vbs = xdc_rep_utils:my_active_vbuckets(SrcBucketConfig),
        RepState0 = #replication{rep = Rep,
                                 vbs = Vbs,
                                 concurrency_throttle = Throttle,
                                 vbucket_sup = Sup},
        RepState = start_vb_replicators(RepState0);
    _Else ->
        RepState = #replication{rep = Rep,
                                concurrency_throttle = Throttle,
                                vbucket_sup = Sup}
    end,
    {ok, RepState}.

handle_call(stats, _From, #replication{vb_rep_dict = Dict} = State) ->
    Stats = dict:fold(
                    fun(_,
                        #rep_vb_status{vb = Vb,
                                       status = Status,
                                       num_changes_left = Left,
                                       docs_checked = Checked,
                                       docs_written = Written},
                        {WorkLeftAcc, CheckedAcc, WrittenAcc, VbReplicatingAcc}) ->
                                {WorkLeftAcc + Left,
                                 CheckedAcc + Checked,
                                 WrittenAcc + Written,
                                 if Status == replicating ->
                                     [Vb | VbReplicatingAcc];
                                 true ->
                                     VbReplicatingAcc
                                 end}
                        end, {0, 0, 0, []}, Dict),
    {Left1, Checked1, Written1, VbsReplicating1} = Stats,
    Props = [{changes_left, Left1},
             {docs_checked, Checked1},
             {docs_written, Written1},
             {vbs_replicating, VbsReplicating1}],
    {reply, {ok, Props}, State};

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

handle_info({src_db_updated, Vb}, #replication{vb_rep_dict = Dict} = State) ->
    case dict:find(Vb, Dict) of
    {ok, #rep_vb_status{pid = Pid}} ->
        Pid ! src_db_updated;
    error ->
        % no state yet, or already erased
        ok
    end,
    {noreply, State};

handle_info({set_vb_rep_status, #rep_vb_status{vb = Vb} = VbState},
            #replication{vb_rep_dict = Dict} = State) ->
    Dict2 = dict:store(Vb, VbState, Dict),
    {noreply, State#replication{vb_rep_dict = Dict2}};

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
            NewState = State#replication{vbucket_sup = Sup2};
        SrcConfig ->
            NewVbs = xdc_rep_utils:my_active_vbuckets(SrcConfig),
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
                                concurrency_throttle = Throttle,
                                vbs = Vbs,
                                vb_rep_dict = Dict} = Replication) ->
    CurrentVbs = [element(1, Spec) || Spec <- supervisor:which_children(Sup)],
    NewVbs = Vbs -- CurrentVbs,
    RemovedVbs = CurrentVbs -- Vbs,
    % now delete the removed Vbs
    Dict2 = lists:foldl(
                    fun(RemoveVb, DictAcc) ->
                            ok = supervisor:terminate_child(Sup, RemoveVb),
                            ok = supervisor:delete_child(Sup, RemoveVb),
                            dict:erase(RemoveVb, DictAcc)
                    end, Dict, RemovedVbs),
    % now start the new Vbs
    lists:foreach(
                    fun(Vb) ->
                            Spec = {Vb,
                                    {xdc_vbucket_rep, start_link, [Rep, Vb, Throttle, self()]},
                                    permanent,
                                    100,
                                    worker,
                                    [xdc_vbucket_rep]
                                   },
                            supervisor:start_child(Sup, Spec)
                    end, NewVbs),
    Replication#replication{vb_rep_dict = Dict2}.
