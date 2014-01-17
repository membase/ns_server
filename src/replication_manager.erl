%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc common stab for tap and upr replication managers
%%
-module(replication_manager).

-behavior(gen_server).

-include("ns_common.hrl").

-record(state, {bucket_name :: bucket_name(),
                repl_type :: tap | upr | both,
                remaining_tap_partitions = undefined :: [vbucket_id()] | undefined,
                desired_replications :: [{node(), [vbucket_id()]}]
               }).

-export([start_link/1,
         get_incoming_replication_map/1,
         set_incoming_replication_map/2,
         change_vbucket_replication/3,
         remove_undesired_replications/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

server_name(Bucket) ->
    list_to_atom("replication_manager-" ++ Bucket).

start_link(Bucket) ->
    gen_server:start_link({local, server_name(Bucket)}, ?MODULE, Bucket, []).

init(Bucket) ->
    {ReplType, TapPartitions} = get_replication_type(Bucket),

    case ReplType of
        upr ->
            ok;
        _ ->
            ?log_info("Start tap_replication_manager"),
            {ok, _} = tap_replication_manager:start_link(Bucket)
    end,

    {ok, #state{
            bucket_name = Bucket,
            repl_type = ReplType,
            remaining_tap_partitions = TapPartitions,
            desired_replications = []
           }}.

get_incoming_replication_map(Bucket) ->
    try gen_server:call(server_name(Bucket), get_incoming_replication_map, infinity) of
        Result ->
            Result
    catch exit:{noproc, _} ->
            not_running
    end.

-spec set_incoming_replication_map(bucket_name(),
                                   [{node(), [vbucket_id(),...]}]) -> ok.
set_incoming_replication_map(Bucket, DesiredReps) ->
    gen_server:call(server_name(Bucket), {set_desired_replications, DesiredReps}, infinity).

-spec remove_undesired_replications(bucket_name(), [{node(), [vbucket_id(),...]}]) -> ok.
remove_undesired_replications(Bucket, DesiredReps) ->
    gen_server:call(server_name(Bucket), {remove_undesired_replications, DesiredReps}, infinity).

-spec change_vbucket_replication(bucket_name(), vbucket_id(), node() | undefined) -> ok.
change_vbucket_replication(Bucket, VBucket, ReplicateFrom) ->
    gen_server:call(server_name(Bucket), {change_vbucket_replication, VBucket, ReplicateFrom}, infinity).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

terminate(_Reason, _State) ->
    ok.

handle_info(_Msg, State) ->
    {noreply, State}.

handle_call(get_incoming_replication_map, _From, State) ->
    {reply, get_actual_replications(State), State};
handle_call({remove_undesired_replications, FutureReps}, From,
            #state{desired_replications = CurrentReps} = State) ->
    Diff = replications_difference(FutureReps, CurrentReps),
    CleanedReps0 = [{N, ordsets:intersection(FutureVBs, CurrentVBs)} || {N, FutureVBs, CurrentVBs} <- Diff],
    CleanedReps = [{N, VBs} || {N, [_|_] = VBs} <- CleanedReps0],
    handle_call({set_desired_replications, CleanedReps}, From, State);
handle_call({set_desired_replications, DesiredReps}, _From, #state{} = State) ->
    ok = do_set_incoming_replication_map(State, DesiredReps),
    {reply, ok, State#state{desired_replications = DesiredReps}};
handle_call({change_vbucket_replication, VBucket, NewSrc}, _From, State) ->
    CurrentReps = get_actual_replications_as_list(State),
    CurrentReps0 = [{Node, ordsets:del_element(VBucket, VBuckets)}
                    || {Node, VBuckets} <- CurrentReps],
    %% TODO: consider making it faster
    DesiredReps = case NewSrc of
                      undefined ->
                          CurrentReps0;
                      _ ->
                          misc:ukeymergewith(fun ({Node, VBucketsA}, {_, VBucketsB}) ->
                                                     {Node, ordsets:union(VBucketsA, VBucketsB)}
                                             end, 1,
                                             CurrentReps0, [{NewSrc, [VBucket]}])
                  end,
    handle_call({set_desired_replications, DesiredReps}, [], State).

do_set_incoming_replication_map(State, DesiredReps) ->
    CurrentReps = get_actual_replications_as_list(State),
    do_set_incoming_replication_map(State, DesiredReps, CurrentReps).

categorize_replications([] = _Diff, AccToKill, AccToStart, AccToChange) ->
    {AccToKill, AccToStart, AccToChange};
categorize_replications([{N, NewVBs, OldVBs} = T | Rest], AccToKill, AccToStart, AccToChange) ->
    if
        NewVBs =:= [] -> categorize_replications(Rest, [{N, OldVBs} | AccToKill], AccToStart, AccToChange);
        OldVBs =:= [] -> categorize_replications(Rest, AccToKill, [{N, NewVBs} | AccToStart], AccToChange);
        NewVBs =:= OldVBs -> categorize_replications(Rest, AccToKill, AccToStart, AccToChange);
        true -> categorize_replications(Rest, AccToKill, AccToStart, [T | AccToChange])
    end.

do_set_incoming_replication_map(State, DesiredReps, CurrentReps) ->
    Diff = replications_difference(DesiredReps, CurrentReps),
    {NodesToKill, NodesToStart, NodesToChange} = categorize_replications(Diff, [], [], []),
    [kill_replication(SrcNode, Partitions, State)
     || {SrcNode, Partitions} <- NodesToKill],
    [start_replication(SrcNode, Partitions, State)
     || {SrcNode, Partitions} <- NodesToStart],
    [modify_replication(SrcNode, OldPartitions, NewPartitions, State)
     || {SrcNode, NewPartitions, OldPartitions} <- NodesToChange],
    ok.

start_replication(SrcNode, Partitions, #state{bucket_name = Bucket} = State) ->
    {TapP, UprP} = split_partitions(Partitions, State),
    call_replicators(start_replication, [Bucket, SrcNode, TapP],
                     setup_replication, [Bucket, SrcNode, UprP], State).

kill_replication(SrcNode, Partitions, #state{bucket_name = Bucket} = State) ->
    {TapP, _UprP} = split_partitions(Partitions, State),
    call_replicators(kill_replication, [Bucket, SrcNode, TapP],
                     setup_replication, [Bucket, SrcNode, []], State).

modify_replication(SrcNode, OldPartitions, NewPartitions, #state{bucket_name = Bucket} = State) ->
    {NewTapP, NewUprP} = split_partitions(NewPartitions, State),
    {OldTapP, _OldUprP} = split_partitions(OldPartitions, State),
    call_replicators(modify_replication, [Bucket, SrcNode, OldTapP, NewTapP],
                     setup_replication, [Bucket, SrcNode, NewUprP], State).

split_partitions(Partitions,
                 #state{repl_type = ReplType, remaining_tap_partitions = TapPartitions}) ->
    case ReplType of
        tap ->
            {Partitions, undefined};
        upr ->
            {undefined, Partitions};
        both ->
            PartitionsSet = ordsets:from_list(Partitions),
            {ordsets:to_list(ordsets:intersection(PartitionsSet, TapPartitions)),
             ordsets:to_list(ordsets:subtract(PartitionsSet, TapPartitions))}
    end.

replications_difference(RepsA, RepsB) ->
    L = [{N, VBs, []} || {N, VBs} <- RepsA],
    R = [{N, [], VBs} || {N, VBs} <- RepsB],
    MergeFn = fun ({N, VBsL, []}, {N, [], VBsR}) ->
                      {N, VBsL, VBsR}
              end,
    misc:ukeymergewith(MergeFn, 1, L, R).

merge_replications(RepsA, RepsB) ->
    case {RepsA, RepsB} of
        {not_running, not_running} ->
            not_running;
        {not_running, _} ->
            RepsB;
        {_, not_running} ->
            RepsA;
        _ ->
            MergeFn = fun ({N, PartitionsA}, {N, PartitionsB}) ->
                              {N, PartitionsA ++ PartitionsB}
                      end,
            misc:ukeymergewith(MergeFn, 1, RepsA, RepsB)
    end.

call_replicators(TapFun, TapArgs, UprFun, UprArgs, State) ->
    call_replicators(TapFun, TapArgs, UprFun, UprArgs,
                     fun(A, B) -> ok = A = B end,
                     State).

call_replicators(TapFun, TapArgs, UprFun, UprArgs, MergeCB, #state{repl_type = ReplType}) ->
    case ReplType of
        tap ->
            erlang:apply(tap_replication_manager, TapFun, TapArgs);
        upr ->
            erlang:apply(upr_sup, UprFun, UprArgs);
        both ->
            MergeCB(
              erlang:apply(tap_replication_manager, TapFun, TapArgs),
              erlang:apply(upr_sup, UprFun, UprArgs))
    end.

get_actual_replications(#state{bucket_name = Bucket} = State) ->
    call_replicators(get_actual_replications, [Bucket], get_actual_replications, [Bucket],
                     fun merge_replications/2, State).

get_actual_replications_as_list(State) ->
    case get_actual_replications(State) of
        not_running ->
            [];
        Reps ->
            Reps
    end.

get_replication_type(Bucket) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:replication_type(BucketConfig) of
        tap ->
            {tap, undefined};
        upr ->
            {upr, undefined};
        {upr, Partitions} ->
            {both, ordsets:from_list(Partitions)}
    end.
