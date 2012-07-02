%% @author Couchbase <info@couchbase.com>
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

-module(cb_gen_vbm_sup).

-behaviour(supervisor).

-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([init/1]).

-export([start_link/2,
         add_replica/5,
         kill_replica/5,
         set_replicas/4,
         apply_changes/3,
         stop_replications/5,
         replicas/3,
         node_replicator_triples/3,
         kill_all_children/3,
         perform_vbucket_filter_change/5]).

-type replicator() :: any().

-define(RPC_TIMEOUT, infinity).

%%
%% API
%%
start_link(Policy, Bucket) ->
    supervisor:start_link({local, Policy:server_name(Bucket)}, ?MODULE, []).

%%
%% Supervisor callbacks
%%

init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.

%% @doc Add a vbucket to the filter for a given source and destination
%% node.
-spec add_replica(module(), bucket_name(), node(), node(), vbucket_id()) -> ok.
add_replica(Policy, Bucket, SrcNode, DstNode, VBucket) ->
    assert_is_master_node(),

    VBuckets =
        case get_replicator(Policy, Bucket, SrcNode, DstNode) of
            undefined ->
                [VBucket];
            Replicator ->
                Vs = Policy:replicator_vbuckets(Replicator),
                kill_child(Policy, Bucket, SrcNode, DstNode, Replicator),
                ordsets:add_element(VBucket, Vs)
        end,

    {ok, _} = start_child(Policy, Bucket, SrcNode, DstNode, VBuckets),
    ok.

%% @doc Kill any replication for a given destination node and vbucket.
-spec kill_replica(module(), bucket_name(), node(), node(), vbucket_id()) -> ok.
kill_replica(Policy, Bucket, SrcNode, DstNode, VBucket) ->
    assert_is_master_node(),

    case get_replicator(Policy, Bucket, SrcNode, DstNode) of
        undefined ->
            ok;
        Replicator ->
            %% Kill the child and start it again without this vbucket.
            kill_child(Policy, Bucket, SrcNode, DstNode, Replicator),
            VBuckets = Policy:replicator_vbuckets(Replicator),
            case VBuckets of
                [VBucket] ->
                    %% just kill when it was last vbucket
                    ?log_debug("~p: killed last vbucket (~p) for destination ~p",
                               [SrcNode, VBucket, DstNode]),
                    ok;
                _ ->
                    NewVBuckets = ordsets:del_element(VBucket, VBuckets),
                    {ok, _} = start_child(Policy,
                                          Bucket, SrcNode, DstNode, NewVBuckets),
                    ok
            end
    end.

-spec apply_changes(module(), bucket_name(), [Change]) -> integer()
   when Change :: {Type, SrcNode :: node(), DstNode :: node(), vbucket_id()},
        Type :: add_replica | kill_replica.
apply_changes(Policy, Bucket, ChangeTuples) ->
    assert_is_master_node(),

    ?log_info("Applying changes:~n~p~n", [ChangeTuples]),

    %% In 1.8.1 we clearly know what nodes are affected by change
    %% tuples (source). But in 1.8.2 it's either source or
    %% destination. Lets count both just in case.
    RelevantNodes = lists:usort([N || {_, S, D, _} <- ChangeTuples,
                                      N <- [S, D]]),

    %% dict({Src, Dst}, VBuckets)
    Replicators = replicators(Policy, Bucket, RelevantNodes),
    NewReplicators = apply_changes_to_replicators(Replicators, ChangeTuples),

    do_set_replicas(Policy, Bucket, NewReplicators, RelevantNodes),

    %% return number of actual changes
    changes_count(Replicators, NewReplicators).

-spec set_replicas(module(), bucket_name(), Replicas, [node()]) -> ok
  when Replica :: {SrcNode::node(), DstNode::node(), vbucket_id()},
       Replicas :: [Replica].
set_replicas(Policy, Bucket, Replicas, AllNodes) when is_list(Replicas) ->
    assert_is_master_node(),

    Replicators = replicas_to_replicators(Replicas),
    do_set_replicas(Policy, Bucket, Replicators, AllNodes).

-spec do_set_replicas(module(), bucket_name(), dict(), [node()]) -> ok.
do_set_replicas(Policy, Bucket, Replicators, AllNodes) ->
    ReplicationEnabled =
        ns_config:search_node_prop(node(), ns_config:get(), replication,
                                   enabled, true),

    case ReplicationEnabled of
        true ->
            GrouppedReplicators = group_by_node(Policy, AllNodes, Replicators),

            try
                misc:parallel_map(
                  fun (Node) ->
                          NodeReplicators = dict:fetch(Node, GrouppedReplicators),

                          case dict:size(NodeReplicators) of
                              0 ->
                                  kill_all_children(Policy, Bucket, Node);
                              _ ->
                                  try
                                      set_node_replicas(Policy, Bucket,
                                                        Node, NodeReplicators)
                                  catch
                                      E:R ->
                                          Stack = erlang:get_stacktrace(),
                                          ?log_error("Unable to start replicators "
                                                     "on ~p for bucket ~p: ~p~n"
                                                     "Here's stacktrace:~n~p",
                                                     [Node, Bucket, {E, R}, Stack])
                                  end
                          end
                  end, AllNodes, ?RPC_TIMEOUT)
            catch
                exit:timeout ->
                    ?log_error("Timeouted while trying to "
                               "start replications for bucket ~p. Ignoring.",
                               [Bucket])
            end,

            ok;
        false ->
            ok
    end.

%% Kills replicators affecting given vbuckets on certain nodes. NOTE: it
%% actually kills replicators instead of removing requested vbuckets from
%% vbucket filter.
-spec stop_replications(module(), bucket_name(),
                        node(), node(), [vbucket_id()]) -> ok.
stop_replications(Policy, Bucket, SrcNode, DstNode, VBuckets0) ->
    assert_is_master_node(),

    VBuckets = ordsets:from_list(VBuckets0),

    Node = Policy:supervisor_node(SrcNode, DstNode),

    try
        Children =
            lists:filter(
              fun (Child) ->
                      Vs = Policy:replicator_vbuckets(Child),
                      {SrcNode, DstNode} =:= Policy:replicator_nodes(Node, Child)
                          andalso (not ordsets:is_disjoint(VBuckets, Vs))
              end, children(Policy, Bucket, Node)),

        lists:foreach(
          fun (Child) ->
                  kill_child(Policy, Bucket, Node, Child)
          end, Children)
    catch
        %% old nodes do not have new supervisor
        exit:{noproc, _} ->
            ok
    end.

-spec replicas(module(), bucket_name(), [node()]) -> [Replica]
  when Replica :: {SrcNode::node(), DstNode::node(), vbucket_id()}.
replicas(Policy, Bucket, Nodes) ->
    Replicators = replicators_list(Policy, Bucket, Nodes),
    Replicas =
        lists:flatmap(
          fun ({{SrcNode, DstNode}, VBuckets}) ->
                  [{SrcNode, DstNode, VBucket} || VBucket <- VBuckets]
          end, Replicators),
    lists:sort(Replicas).

node_replicator_triples(Policy, Bucket, Node) ->
    Children =
        try
            children(Policy, Bucket, Node)
        catch
            _:_ ->
                []
        end,

    lists:map(
      fun (Child) ->
              {SrcNode, DstNode} = Policy:replicator_nodes(Node, Child),
              VBuckets = Policy:replicator_vbuckets(Child),

              {SrcNode, DstNode, VBuckets}
      end, Children).

%% Internal functions
changes_count(Replicators, NewReplicators) ->
    dict:fold(fun (K, V, Count) ->
                      case dict:find(K, Replicators) of
                          {ok, V} ->        % NOTE: V is bound
                              Count;
                          _ -> Count + 1
                      end
              end, 0, NewReplicators)
        + dict:fold(fun (K, _V, Count) ->
                            case dict:find(K, NewReplicators) of
                                {ok, _} ->
                                    Count;
                                _ -> Count + 1
                            end
                    end, 0, Replicators).

apply_changes_to_replicators(Replicators, Changes) ->
    lists:foldl(fun ({Type, SrcNode, DstNode, VBucket}, CurrentReplicators) ->
                        Key = {SrcNode, DstNode},
                        VBuckets = case dict:find(Key, CurrentReplicators) of
                                       {ok, X} -> X;
                                       error -> []
                                   end,
                        NewVBuckets =
                            case Type of
                                kill_replica ->
                                    ordsets:del_element(VBucket, VBuckets);
                                add_replica ->
                                    ordsets:add_element(VBucket, VBuckets)
                            end,

                        case NewVBuckets of
                            [] ->
                                dict:erase(Key, CurrentReplicators);
                            _ ->
                                dict:store(Key, NewVBuckets, CurrentReplicators)
                        end
                end, Replicators, Changes).

-spec kill_child(module(), bucket_name(), node(), replicator()) -> ok.
kill_child(Policy, Bucket, SupNode, Replicator) ->
    ?log_debug("Stopping replicator:~p on ~p", [Replicator, {SupNode, Bucket}]),
    Supervisor = sup_ref(Policy, Bucket, SupNode),
    ok = supervisor:terminate_child(Supervisor, Replicator),
    ok = supervisor:delete_child(Supervisor, Replicator),
    ?log_info("Stopped replicator:~p on ~p", [Replicator, {SupNode, Bucket}]),
    ok.

-spec kill_child(module(), bucket_name(), node(), node(), replicator()) -> ok.
kill_child(Policy, Bucket, SrcNode, DstNode, Replicator) ->
    SupNode = Policy:supervisor_node(SrcNode, DstNode),
    kill_child(Policy, Bucket, SupNode, Replicator).

-spec kill_all_children(module(), bucket_name(), node() | [node()]) -> ok.
kill_all_children(Policy, Bucket, Node) when is_atom(Node) ->
    assert_is_master_node(),
    do_kill_all_children(Policy, Bucket, Node);
kill_all_children(Policy, Bucket, Nodes) ->
    assert_is_master_node(),

    try
        misc:parallel_map(
          fun (Node) ->
                  do_kill_all_children(Policy, Bucket, Node)
          end, Nodes, ?RPC_TIMEOUT)
    catch
        exit:timeout ->
            ?log_error("Failed to kill some of the replications for bucket ~p",
                       [Bucket]),
            throw({kill_all_children_failed, Bucket});
        exit:{child_died, Reason} ->
            ?log_error("Failed to kill some of the replications for bucket ~p: ~p",
                       [Bucket, Reason]),
            throw({kill_all_children_failed, Bucket, Reason})
    end,

    ok.

-spec start_child(module(), bucket_name(),
                  node(), node(), [vbucket_id(),...]) -> Ret
  when Ret :: {error, any()} | {ok, Child, any()} | {ok, Child},
       Child :: pid() | undefined.
start_child(Policy, Bucket, SrcNode, DstNode, VBuckets) ->
    Args = ebucketmigrator_srv:build_args(Bucket,
                                          SrcNode, DstNode, VBuckets, false),
    ?log_debug("Starting replicator with args =~n~p", [Args]),

    Replicator = Policy:make_replicator(SrcNode, DstNode, VBuckets),
    ChildSpec = {Replicator,
                 {ebucketmigrator_srv, start_link, Args},
                 permanent, 60000, worker, [ebucketmigrator_srv]},
    Supervisor = sup_ref(Policy, Bucket, SrcNode, DstNode),

    supervisor:start_child(Supervisor, ChildSpec).

-spec sup_ref(module(), bucket_name(), node()) -> {atom(), node()}.
sup_ref(Policy, Bucket, SupNode) ->
    Name = Policy:server_name(Bucket),
    {Name, SupNode}.

-spec sup_ref(module(), bucket_name(), node(), node()) -> {atom(), node()}.
sup_ref(Policy, Bucket, SrcNode, DstNode) ->
    Node = Policy:supervisor_node(SrcNode, DstNode),
    sup_ref(Policy, Bucket, Node).

-spec children(Supervisor) -> [replicator()]
  when Supervisor :: {atom(), node()}.
children(Supervisor) ->
    [Id || {Id, _, _, _} <- supervisor:which_children(Supervisor)].

-spec children(module(), bucket_name(), node()) -> [replicator()].
children(Policy, Bucket, SupNode) ->
    Supervisor = sup_ref(Policy, Bucket, SupNode),
    children(Supervisor).

%% @doc Get the replicator for a given source and destination node.
-spec get_replicator(module(), bucket_name(), node(), node()) -> Ret
  when Ret :: replicator() | undefined.
get_replicator(Policy, Bucket, SrcNode, DstNode) ->
    SupNode = Policy:supervisor_node(SrcNode, DstNode),
    Children = children(Policy, Bucket, SupNode),

    Matching =
        lists:filter(
          fun (Child) ->
                  Policy:replicator_nodes(SupNode, Child) =:= {SrcNode, DstNode}
          end, Children),

    case Matching of
        [Child] ->
            Child;
        [] ->
            undefined
    end.

-spec replicators_list(module(), bucket_name(), [node()]) -> [Replica]
  when Replica :: {{node(), node()}, [vbucket_id(), ...]}.
replicators_list(Policy, Bucket, Nodes) ->
    lists:flatmap(
      fun (Node) ->
              Children =
                  try
                      children(Policy, Bucket, Node)
                  catch
                      _:_ -> []
                  end,

              [{Policy:replicator_nodes(Node, Child),
                Policy:replicator_vbuckets(Child)} || Child <- Children]
      end, Nodes).

-spec replicators(module(), bucket_name(), [node()]) -> dict().
replicators(Policy, Bucket, Nodes) ->
    dict:from_list(replicators_list(Policy, Bucket, Nodes)).

-spec replicas_to_replicators(Replicas) -> dict()
  when Replicas :: [{Src::node(), Dst::node(), vbucket_id()}].
replicas_to_replicators(Replicas) ->
    lists:foldl(
      fun ({SrcNode, DstNode, VBucket}, D) ->
              dict:update(
                {SrcNode, DstNode},
                fun (VBuckets) ->
                        ordsets:add_element(VBucket, VBuckets)
                end, [VBucket], D)
      end, dict:new(), Replicas).

mk_downstream_retriever(Id) ->
    %% this function's closure will be kept in supervisor, so I want
    %% it to reference as few stuff as possible thus separate closure maker
    fun () ->
            case ns_process_registry:lookup_pid(vbucket_filter_changes_registry, Id) of
                missing -> undefined;
                TxnPid ->
                    case (catch gen_server:call(TxnPid, get_downstream, infinity)) of
                        {ok, Downstream} ->
                            ?log_info("Got vbucket filter change downstream. Proceeding vbucket filter change operation"),
                            Downstream;
                        TxnCrap ->
                            ?log_info("Getting downstream for vbucket change operation failed:~n~p", [TxnCrap]),
                            undefined
                    end
            end
    end.

perform_vbucket_filter_change(Bucket,
                              OldChildId, NewChildId,
                              InitialArgs,
                              Server) ->
    RegistryId = {Bucket, NewChildId, erlang:make_ref()},
    Args = ebucketmigrator_srv:add_args_option(InitialArgs,
                                               passed_downstream_retriever,
                                               mk_downstream_retriever(RegistryId)),
    Childs = supervisor:which_children(Server),
    MaybeThePid = [Pid || {Id, Pid, _, _} <- Childs,
                          Id =:= OldChildId],
    NewChildSpec = {NewChildId,
                    {ebucketmigrator_srv, start_link, Args},
                    permanent, 60000, worker, [ebucketmigrator_srv]},
    case MaybeThePid of
        [ThePid] ->
            misc:executing_on_new_process(
              fun () ->
                      ns_process_registry:register_pid(vbucket_filter_changes_registry, RegistryId, self()),
                      ?log_debug("Registered myself under id:~p~nArgs:~p", [RegistryId, Args]),
                      {ok, NewDownstream} = ebucketmigrator_srv:start_vbucket_filter_change(ThePid),
                      ?log_debug("Got new downstream: ~p from previous ebucketmigrator: ~p", [NewDownstream, ThePid]),
                      erlang:process_flag(trap_exit, true),
                      ok = supervisor:terminate_child(Server, OldChildId),
                      ok = supervisor:delete_child(Server, OldChildId),
                      Me = self(),
                      proc_lib:spawn_link(
                        fun () ->
                                {ok, Pid} = supervisor:start_child(Server, NewChildSpec),
                                Me ! {done, Pid}
                        end),
                      Loop = fun (Loop, SentAlready) ->
                                     receive
                                         {'EXIT', _From, _Reason} = ExitMsg ->
                                             ?log_error("Got unexpected exit signal in vbucket change txn body: ~p", [ExitMsg]),
                                             exit({txn_crashed, ExitMsg});
                                         {done, RV} ->
                                             RV;
                                         {'$gen_call', {Pid, _} = From, get_downstream} ->
                                             case SentAlready of
                                                 false ->
                                                     ?log_debug("Sent new downstream to new instance"),
                                                     gen_tcp:controlling_process(NewDownstream, Pid),
                                                     gen_server:reply(From, {ok, NewDownstream});
                                                 true ->
                                                     gen_server:reply(From, refused)
                                             end,
                                             Loop(Loop, true)
                                     end
                             end,
                      Loop(Loop, false)
              end);
        [] ->
            no_child
    end.

-spec set_node_replicas(module(), bucket_name(), node(), dict()) -> ok.
set_node_replicas(Policy, Bucket, Node, Replicators) ->
    NeededReplicas0 =
        lists:foldl(
          fun (Child, D) ->
                  ActualVBuckets = Policy:replicator_vbuckets(Child),
                  Nodes = Policy:replicator_nodes(Node, Child),
                  {SrcNode, DstNode} = Nodes,

                  case dict:find(Nodes, Replicators) of
                      {ok, ActualVBuckets} ->   % bound above
                          dict:erase(Nodes, D);
                      {ok, NewVBuckets} ->
                          true = (NewVBuckets =/= []),
                          case Policy:change_vbucket_filter(Bucket, SrcNode, DstNode, Child, NewVBuckets) of
                              not_supported ->
                                  system_stats_collector:increment_counter(old_style_vbucket_filter_changes, 1),
                                  %% NOTE: we do not erase node from pending list of changes
                                  ?log_info("~nkill_child(~p, ~p, ~p, ~p, ~p) (due to not_supported)",
                                            [Policy, Bucket, SrcNode, DstNode, Child]),
                                  kill_child(Policy, Bucket, SrcNode, DstNode, Child),
                                  D;
                              {ok, _Pid} ->
                                  ?log_info("change_vbucket_filter ~p from ~n~p~nto~n~p succeeded", [Nodes, ActualVBuckets, NewVBuckets]),
                                  dict:erase(Nodes, D)
                          end;
                      _ ->
                          ?log_info("~nkill_child(~p, ~p, ~p, ~p, ~p)",
                                    [Policy, Bucket, SrcNode, DstNode, Child]),
                          kill_child(Policy, Bucket, SrcNode, DstNode, Child),
                          D
                  end
          end, Replicators, children(Policy, Bucket, Node)),

    NeededReplicas = dict:to_list(NeededReplicas0),

    lists:foreach(
      fun ({{SrcNode, DstNode}, VBuckets}) ->
              ?log_info("~nstart_child(~p, ~p, ~p, ~p,~n~p)",
                        [Policy, Bucket, SrcNode, DstNode, VBuckets]),
              start_child(Policy, Bucket, SrcNode, DstNode, VBuckets)
      end, NeededReplicas),

    ok.

group_by_node(Policy, AllNodes, Replicators) ->
    dict:fold(
      fun ({SrcNode, DstNode} = Nodes, VBuckets, D) ->
              SupNode = Policy:supervisor_node(SrcNode, DstNode),
              case lists:member(SupNode, AllNodes) of
                  true ->
                      dict:update(
                        SupNode,
                        fun (NodeDict) ->
                                dict:store(Nodes, VBuckets, NodeDict)
                        end, D);
                  false ->
                      D
              end
      end, dict:from_list([{N, dict:new()} || N <- AllNodes]), Replicators).

assert_is_master_node() ->
    true = mb_master:master_node() =:= node().

do_kill_all_children(Policy, Bucket, Node) ->
    try children(Policy, Bucket, Node) of
        Children ->
            lists:foreach(
              fun (Child) ->
                      kill_child(Policy, Bucket, Node, Child)
              end, Children)
    catch exit:{noproc, _} ->
            %% If the supervisor isn't running, obviously there's no
            %% replication.
            ok
    end.

-ifdef(EUNIT).

replicas_to_replicators_test() ->
    Map = [[1, 2], [1, 2], [1, 2], [1, 2], [2, 1], [2, 1], [2, 1], [2, 1]],
    Replicas = ns_bucket:map_to_replicas(Map),

    ?assertEqual([{{1, 2}, [0, 1, 2, 3]},
                  {{2, 1}, [4, 5, 6, 7]}],
                 lists:sort(dict:to_list(replicas_to_replicators(Replicas)))).

-endif.
