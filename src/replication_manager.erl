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
                desired_replications :: [{node(), [vbucket_id()]}],
                tap_replication_manager :: pid()
               }).

-export([start_link/1,
         get_incoming_replication_map/1,
         set_incoming_replication_map/2,
         change_vbucket_replication/3,
         remove_undesired_replications/2,
         set_replication_type/2,
         upr_takeover/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

server_name(Bucket) ->
    list_to_atom("replication_manager-" ++ Bucket).

start_link(Bucket) ->
    gen_server:start_link({local, server_name(Bucket)}, ?MODULE, Bucket, []).

init(Bucket) ->
    process_flag(trap_exit, true),
    {ok, #state{
            bucket_name = Bucket,
            repl_type = tap,
            remaining_tap_partitions = undefined,
            desired_replications = [],
            tap_replication_manager = undefined
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

-spec set_replication_type(bucket_name(), bucket_replication_type()) -> ok.
set_replication_type(Bucket, ReplType) ->
    gen_server:call(server_name(Bucket), {set_replication_type, ReplType}, infinity).

-spec remove_undesired_replications(bucket_name(), [{node(), [vbucket_id(),...]}]) -> ok.
remove_undesired_replications(Bucket, DesiredReps) ->
    gen_server:call(server_name(Bucket), {remove_undesired_replications, DesiredReps}, infinity).

-spec change_vbucket_replication(bucket_name(), vbucket_id(), node() | undefined) -> ok.
change_vbucket_replication(Bucket, VBucket, ReplicateFrom) ->
    gen_server:call(server_name(Bucket), {change_vbucket_replication, VBucket, ReplicateFrom}, infinity).

upr_takeover(Bucket, OldMasterNode, VBucket) ->
    gen_server:call(server_name(Bucket), {upr_takeover, OldMasterNode, VBucket}, infinity).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

terminate(Reason, #state{tap_replication_manager = TapReplicationManager} = State) ->
    case TapReplicationManager of
        undefined ->
            ok;
        _ ->
            misc:terminate_and_wait(Reason, [TapReplicationManager])
    end,
    ?log_debug("Replication manager died ~p", [{Reason, State}]),
    ok.

handle_info({'EXIT', TapReplicationManager, shutdown},
            #state{tap_replication_manager = TapReplicationManager} = State) ->
    {noreply, State};
handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};
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
handle_call({set_desired_replications, DesiredReps}, _From,
            #state{bucket_name = Bucket,
                   repl_type = Type,
                   tap_replication_manager = TapReplManager} = State) ->
    NewTapReplManager = manage_tap_replication_manager(Bucket, Type, TapReplManager),
    State1 = State#state{tap_replication_manager = NewTapReplManager},

    {Tap, Upr} = split_replications(DesiredReps, State1),
    call_replicators(
      set_desired_replications, [Bucket, Tap],
      set_desired_replications, [Bucket, Upr],
      State1),

    {reply, ok, State1#state{desired_replications = DesiredReps}};
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
    handle_call({set_desired_replications, DesiredReps}, [], State);
handle_call({set_replication_type, ReplType}, _From, State) ->
    {Type, TapPartitions} =
        case ReplType of
            tap ->
                {tap, undefined};
            upr ->
                {upr, undefined};
            {upr, P} ->
                {both, P}
        end,

    do_set_replication_type(Type, TapPartitions, State);
handle_call({upr_takeover, OldMasterNode, VBucket}, _From,
            #state{bucket_name = Bucket,
                   desired_replications = CurrentReps} = State) ->
    DesiredReps = lists:map(fun ({Node, VBuckets}) ->
                                    case Node of
                                        OldMasterNode ->
                                            {Node, ordsets:del_element(VBucket, VBuckets)};
                                        _ ->
                                            {Node, VBuckets}
                                    end
                            end, CurrentReps),
    {reply, upr_replicator:takeover(OldMasterNode, Bucket, VBucket),
     State#state{desired_replications = DesiredReps}}.

do_set_replication_type(Type, TapPartitions,
                        #state{repl_type = Type, remaining_tap_partitions = TapPartitions}
                        = State) ->
    {reply, ok, State};
do_set_replication_type(Type, TapPartitions,
                        #state{repl_type = OldType,
                               remaining_tap_partitions = OldTapPartitions,
                               desired_replications = DesiredReplications} = State) ->
    ?log_debug("Change replication type from ~p to ~p", [{OldType, OldTapPartitions},
                                                         {Type, TapPartitions}]),

    State1 =
        case DesiredReplications of
            [] ->
                State;
            _ ->
                CleanedReplications =
                    lists:keymap(fun (Partitions) ->
                                         [P || P <- Partitions,
                                               replication_type(P, Type, TapPartitions) =:=
                                                   replication_type(P, OldType, OldTapPartitions)]
                                 end, 2, DesiredReplications),

                {reply, ok, S} =
                    handle_call({set_desired_replications, CleanedReplications}, [], State),
                S
        end,
    {reply, ok, State1#state{repl_type = Type,
                             remaining_tap_partitions = TapPartitions}}.

manage_tap_replication_manager(Bucket, Type, TapReplManager) ->
    case {Type, TapReplManager} of
        {upr, undefined} ->
            undefined;
        {upr, Pid} ->
            ?log_debug("Shutdown tap_replication_manager"),
            erlang:unlink(Pid),
            exit(Pid, shutdown),
            misc:wait_for_process(Pid, infinity),
            undefined;
        {_, undefined} ->
            ?log_debug("Start tap_replication_manager"),
            {ok, Pid} = tap_replication_manager:start_link(Bucket),
            Pid;
        {_, Pid} ->
            Pid
    end.

split_partitions(Partitions,
                 #state{repl_type = both, remaining_tap_partitions = TapPartitions}) ->
    {ordsets:intersection(Partitions, TapPartitions),
     ordsets:subtract(Partitions, TapPartitions)}.

split_replications(Replications, #state{repl_type = tap}) ->
    {Replications, []};
split_replications(Replications, #state{repl_type = upr}) ->
    {[], Replications};
split_replications(Replications, State) ->
    split_replications(Replications, State, [], []).

split_replications([], _, Tap, Upr) ->
    {lists:reverse(Tap), lists:reverse(Upr)};
split_replications([{SrcNode, Partitions} | Rest], State, Tap, Upr) ->
    {TapP, UprP} = split_partitions(Partitions, State),
    split_replications(Rest, State, [{SrcNode, TapP} | Tap], [{SrcNode, UprP} | Upr]).

replication_type(Partition, ReplType, TapPartitions) ->
    case {ReplType, TapPartitions} of
        {tap, undefined} ->
            tap;
        {upr, undefined} ->
            upr;
        {both, _} ->
            case ordsets:is_element(Partition, TapPartitions) of
                true ->
                    tap;
                false ->
                    upr
            end
    end.

replications_difference(RepsA, RepsB) ->
    L = [{N, VBs, []} || {N, VBs} <- RepsA],
    R = [{N, [], VBs} || {N, VBs} <- RepsB],
    MergeFn = fun ({N, VBsL, []}, {N, [], VBsR}) ->
                      {N, VBsL, VBsR}
              end,
    misc:ukeymergewith(MergeFn, 1, L, R).

merge_replications(TapReps, UprReps, State) ->
    case {TapReps, UprReps} of
        {not_running, not_running} ->
            not_running;
        {not_running, _} ->
            UprReps;
        {_, not_running} ->
            TapReps;
        _ ->
            MergeFn = fun ({N, TapP}, {N, UprP}) ->
                              {N, merge_partitions(TapP, UprP, State)}
                      end,
            misc:ukeymergewith(MergeFn, 1, TapReps, UprReps)
    end.

merge_partitions(TapP, UprP, #state{remaining_tap_partitions = TapPartitions}) ->
    [] = ordsets:intersection(UprP, TapPartitions) ++
        ordsets:subtract(TapP, TapPartitions),
    lists:sort(TapP ++ UprP).

call_replicators(TapFun, TapArgs, UprFun, UprArgs, State) ->
    call_replicators(TapFun, TapArgs, UprFun, UprArgs,
                     fun(_, _, _) -> ok end,
                     State).

call_replicators(TapFun, TapArgs, UprFun, UprArgs, MergeCB, #state{repl_type = ReplType} = State) ->
    case ReplType of
        tap ->
            erlang:apply(tap_replication_manager, TapFun, TapArgs);
        upr ->
            erlang:apply(upr_sup, UprFun, UprArgs);
        both ->
            MergeCB(
              erlang:apply(tap_replication_manager, TapFun, TapArgs),
              erlang:apply(upr_sup, UprFun, UprArgs), State)
    end.

get_actual_replications(#state{bucket_name = Bucket} = State) ->
    call_replicators(get_actual_replications, [Bucket], get_actual_replications, [Bucket],
                     fun merge_replications/3, State).

get_actual_replications_as_list(State) ->
    case get_actual_replications(State) of
        not_running ->
            [];
        Reps ->
            Reps
    end.
