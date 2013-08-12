%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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
%% @doc this implements creating replication stream for particular
%% vbucket from some node to bunch of other nodes. It is also possible
%% to shutdown some replications earlier then others.
%%
-module(new_ns_replicas_builder).

-behaviour(gen_server).

-include("ns_common.hrl").

-export([spawn_link/5,
         shutdown_replicator/2,
         get_replicators/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {bucket :: bucket_name(),
                vbucket :: vbucket_id(),
                src_node :: node(),
                replicators :: [{node(), pid()}]}).

%% @doc spawns replicas builder for given bucket, vbucket, source and
%% destination node(s).
-spec spawn_link(Bucket::bucket_name(), VBucket::vbucket_id(), SrcNode::node(),
                 JustBackfillNodes::[node()],
                 ReplicaNodes::[node()])-> pid().
spawn_link(Bucket, VBucket, SrcNode, JustBackfillNodes, ReplicaNodes) ->
    {ok, Pid} = gen_server:start_link(?MODULE, {Bucket, VBucket, SrcNode, JustBackfillNodes, ReplicaNodes}, []),
    Pid.

shutdown_replicator(Pid, DstNode) ->
    gen_server:call(Pid, {shutdown_replicator, DstNode}, infinity).

get_replicators(Pid) ->
    gen_server:call(Pid, get_replicators, infinity).

init({Bucket, VBucket, SrcNode, JustBackfillNodes, ReplicaNodes}) ->
    erlang:process_flag(trap_exit, true),
    Replicators =
        [{DNode, ns_replicas_builder_utils:spawn_replica_builder(Bucket, VBucket, SrcNode, DNode, true)}
         || DNode <- JustBackfillNodes]
        ++ [{DNode, ns_replicas_builder_utils:spawn_replica_builder(Bucket, VBucket, SrcNode, DNode, false)}
            || DNode <- ReplicaNodes],
    {ok, #state{
       bucket = Bucket,
       vbucket = VBucket,
       src_node = SrcNode,
       replicators = Replicators}}.


kill_replicators(Replicators, State) ->
    {Nodes, Pids} = lists:unzip(Replicators),
    misc:try_with_maybe_ignorant_after(
      fun () ->
              misc:sync_shutdown_many_i_am_trapping_exits(Pids)
      end,
      fun () ->
              ns_replicas_builder_utils:kill_tap_names(State#state.bucket,
                                                       State#state.vbucket,
                                                       State#state.src_node,
                                                       Nodes)
      end).

handle_call({shutdown_replicator, DstNode}, _From, #state{replicators = Replicators} = State) ->
    MaybeReplicator = [R || {Dst, _Pid} = R <- Replicators,
                            Dst =:= DstNode],
    case MaybeReplicator of
        [] ->
            {reply, {error, unknown_node}, State};
        [_Pid] ->
            kill_replicators(MaybeReplicator, State),
            State2 = State#state{replicators = Replicators -- MaybeReplicator},
            {reply, ok, State2}
    end;
handle_call(get_replicators, _From, #state{replicators = Replicators} = State) ->
    {reply, Replicators, State}.

handle_cast(_, _State) ->
    erlang:nif_error(unhandled_cast).

handle_info({'EXIT', From, Reason} = ExitMsg, #state{replicators = Replicators} = State) ->
    case lists:member(From, Replicators) of
        true ->
            ?log_error("Got premature exit from one of ebucketmigrators: ~p", [ExitMsg]),
            self() ! ExitMsg, % we'll process it again in terminate
            {stop, {replicator_died, ExitMsg}, State};
        false ->
            ?log_info("Got exit from some stranger: ~p", [ExitMsg]),
            {stop, Reason, State}
    end.

terminate(_Reason, #state{replicators = Replicators} = State) ->
    kill_replicators(Replicators, State).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
