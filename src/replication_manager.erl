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
%% @doc common stab for tap and dcp replication managers
%%
-module(replication_manager).

-behavior(gen_server).

-include("ns_common.hrl").

-record(state, {bucket_name :: bucket_name(),
                repl_type :: bucket_replication_type(),
                desired_replications :: [{node(), [vbucket_id()]}],
                tap_replication_manager :: pid()
               }).

-export([start_link/1,
         get_incoming_replication_map/1,
         set_incoming_replication_map/2,
         change_vbucket_replication/3,
         remove_undesired_replications/2,
         set_replication_type/2,
         dcp_takeover/3]).

-export([split_partitions/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

server_name(Bucket) ->
    list_to_atom("replication_manager-" ++ Bucket).

start_link(Bucket) ->
    gen_server:start_link({local, server_name(Bucket)}, ?MODULE, Bucket, []).

init(Bucket) ->
    process_flag(trap_exit, true),

    TableName = server_name(Bucket),
    ets:new(TableName, [protected, set, named_table]),
    ets:insert(TableName, {repl_type, tap}),

    {ok, #state{
            bucket_name = Bucket,
            repl_type = tap,
            desired_replications = [],
            tap_replication_manager = undefined
           }}.

get_incoming_replication_map(Bucket) ->
    try ets:lookup(server_name(Bucket), repl_type) of
        [{repl_type, ReplType}] ->
            get_actual_replications(Bucket, ReplType);
        [] ->
            not_running
    catch
        error:badarg -> not_running
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

dcp_takeover(Bucket, OldMasterNode, VBucket) ->
    gen_server:call(server_name(Bucket), {dcp_takeover, OldMasterNode, VBucket}, infinity).

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

handle_call({remove_undesired_replications, FutureReps}, From,
            #state{desired_replications = CurrentReps} = State) ->
    Diff = replications_difference(FutureReps, CurrentReps),
    CleanedReps0 = [{N, ordsets:intersection(FutureVBs, CurrentVBs)} || {N, FutureVBs, CurrentVBs} <- Diff],
    CleanedReps = [{N, VBs} || {N, [_|_] = VBs} <- CleanedReps0],
    handle_call({set_desired_replications, CleanedReps}, From, State);
handle_call({set_desired_replications, DesiredReps}, _From,
            #state{bucket_name = Bucket,
                   repl_type = ReplType,
                   tap_replication_manager = TapReplManager} = State) ->
    NewTapReplManager = manage_tap_replication_manager(Bucket, ReplType, TapReplManager),
    State1 = State#state{tap_replication_manager = NewTapReplManager},

    {Tap, Dcp} = split_replications(DesiredReps, State1),
    call_replicators(
      set_desired_replications, [Bucket, Tap],
      set_desired_replications, [Bucket, Dcp],
      ReplType),

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
handle_call({set_replication_type, ReplType}, _From, #state{repl_type = ReplType} = State) ->
    {reply, ok, State};
handle_call({set_replication_type, ReplType}, _From,
            #state{repl_type = OldReplType,
                   desired_replications = DesiredReplications,
                   bucket_name = Bucket} = State) ->

    ?log_debug("Change replication type from ~p to ~p", [OldReplType, ReplType]),

    State1 =
        case DesiredReplications of
            [] ->
                State;
            _ ->
                CleanedReplications =
                    lists:keymap(fun (Partitions) ->
                                         [P || P <- Partitions,
                                               replication_type(P, ReplType) =:=
                                                   replication_type(P, OldReplType)]
                                 end, 2, DesiredReplications),

                {reply, ok, S} =
                    handle_call({set_desired_replications, CleanedReplications}, [], State),
                S
        end,

    ets:insert(server_name(Bucket), {repl_type, ReplType}),
    {reply, ok, State1#state{repl_type = ReplType}};
handle_call({dcp_takeover, OldMasterNode, VBucket}, _From,
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

manage_tap_replication_manager(Bucket, Type, TapReplManager) ->
    case {Type, TapReplManager} of
        {dcp, undefined} ->
            undefined;
        {dcp, Pid} ->
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

-spec split_partitions([vbucket_id()], bucket_replication_type()) ->
                              {[vbucket_id()], [vbucket_id()]}.
split_partitions(Partitions, tap) ->
    {Partitions, []};
split_partitions(Partitions, dcp) ->
    {[], Partitions};
split_partitions(Partitions, {dcp, TapPartitions}) ->
    {ordsets:intersection(Partitions, TapPartitions),
     ordsets:subtract(Partitions, TapPartitions)}.

split_replications(Replications, #state{repl_type = tap}) ->
    {Replications, []};
split_replications(Replications, #state{repl_type = dcp}) ->
    {[], Replications};
split_replications(Replications, State) ->
    split_replications(Replications, State, [], []).

split_replications([], _, Tap, Dcp) ->
    {lists:reverse(Tap), lists:reverse(Dcp)};
split_replications([{SrcNode, Partitions} | Rest], State, Tap, Dcp) ->
    {TapP, DcpP} = split_partitions(Partitions, State#state.repl_type),
    split_replications(Rest, State, [{SrcNode, TapP} | Tap], [{SrcNode, DcpP} | Dcp]).

replication_type(Partition, ReplType) ->
    case ReplType of
        tap ->
            tap;
        dcp ->
            dcp;
        {dcp, TapPartitions} ->
            case ordsets:is_element(Partition, TapPartitions) of
                true ->
                    tap;
                false ->
                    dcp
            end
    end.

replications_difference(RepsA, RepsB) ->
    L = [{N, VBs, []} || {N, VBs} <- RepsA],
    R = [{N, [], VBs} || {N, VBs} <- RepsB],
    MergeFn = fun ({N, VBsL, []}, {N, [], VBsR}) ->
                      {N, VBsL, VBsR}
              end,
    misc:ukeymergewith(MergeFn, 1, L, R).

merge_replications(TapReps, DcpReps, State) ->
    case {TapReps, DcpReps} of
        {not_running, not_running} ->
            not_running;
        {not_running, _} ->
            DcpReps;
        {_, not_running} ->
            TapReps;
        _ ->
            MergeFn = fun ({N, TapP}, {N, DcpP}) ->
                              {N, merge_partitions(TapP, DcpP, State)}
                      end,
            misc:ukeymergewith(MergeFn, 1, TapReps, DcpReps)
    end.

merge_partitions(TapP, DcpP, TapPartitions) ->
    [] = ordsets:intersection(DcpP, TapPartitions) ++
        ordsets:subtract(TapP, TapPartitions),
    lists:sort(TapP ++ DcpP).

call_replicators(TapFun, TapArgs, DcpFun, DcpArgs, ReplType) ->
    call_replicators(TapFun, TapArgs, DcpFun, DcpArgs,
                     fun(_, _, _) -> ok end,
                     ReplType).

call_replicators(TapFun, TapArgs, DcpFun, DcpArgs, MergeCB, ReplType) ->
    case ReplType of
        tap ->
            erlang:apply(tap_replication_manager, TapFun, TapArgs);
        dcp ->
            erlang:apply(upr_sup, DcpFun, DcpArgs);
        {dcp, TapPartitions} ->
            MergeCB(
              erlang:apply(tap_replication_manager, TapFun, TapArgs),
              erlang:apply(upr_sup, DcpFun, DcpArgs), TapPartitions)
    end.

get_actual_replications(Bucket, ReplTypeTuple) ->
    call_replicators(get_actual_replications, [Bucket], get_actual_replications, [Bucket],
                     fun merge_replications/3, ReplTypeTuple).

get_actual_replications_as_list(#state{repl_type = ReplType,
                                       bucket_name = Bucket}) ->
    case get_actual_replications(Bucket, ReplType) of
        not_running ->
            [];
        Reps ->
            Reps
    end.
