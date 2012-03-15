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
         kill_all_children/3]).

-type replicator() :: any().

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
                    ?log_info("~p: killed last vbucket (~p) for destination ~p",
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
    ?log_info("Applying changes:~n~p~n", [ChangeTuples]),
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),

    RelevantNodes = proplists:get_value(servers, BucketConfig),
    true = is_list(RelevantNodes),

    %% dict({Src, Dst}, VBuckets)
    Replicators = replicators(Policy, Bucket, RelevantNodes),
    NewReplicators = apply_changes_to_replicators(Replicators, ChangeTuples),

    do_set_replicas(Policy, Bucket, NewReplicators),

    %% return number of actual changes
    changes_count(Replicators, NewReplicators).

-spec do_set_replicas(module(), bucket_name(), dict()) -> ok.
do_set_replicas(Policy, Bucket, Replicators) ->
    LiveNodes = ns_node_disco:nodes_actual_proper(),
    do_set_replicas(Policy, Bucket, Replicators, LiveNodes).

-spec set_replicas(module(), bucket_name(), Replicas, [node()]) -> ok
  when Replica :: {SrcNode::node(), DstNode::node(), vbucket_id()},
       Replicas :: [Replica].
set_replicas(Policy, Bucket, Replicas, AllNodes) when is_list(Replicas) ->
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

            lists:foreach(
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
                                      ?log_error("Unable to start replicators "
                                                 "on ~p for bucket ~p: ~p",
                                                 [Node, Bucket, {E, R}])
                              end
                      end
              end, AllNodes),

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
    VBuckets = ordsets:from_list(VBuckets0),

    Node = Policy:supervisor_node(SrcNode, DstNode),

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
      end, Children).

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
    Supervisor = sup_ref(Policy, Bucket, SupNode),
    ok = supervisor:terminate_child(Supervisor, Replicator),
    ok = supervisor:delete_child(Supervisor, Replicator).

-spec kill_child(module(), bucket_name(), node(), node(), replicator()) -> ok.
kill_child(Policy, Bucket, SrcNode, DstNode, Replicator) ->
    SupNode = Policy:supervisor_node(SrcNode, DstNode),
    kill_child(Policy, Bucket, SupNode, Replicator).

-spec kill_all_children(module(), bucket_name(), node()) -> ok.
kill_all_children(Policy, Bucket, Node) ->
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


-spec start_child(module(), bucket_name(),
                  node(), node(), [vbucket_id(),...]) -> Ret
  when Ret :: {error, any()} | {ok, Child, any()} | {ok, Child},
       Child :: pid() | undefined.
start_child(Policy, Bucket, SrcNode, DstNode, VBuckets) ->
    Args = ebucketmigrator_srv:build_args(Bucket,
                                          SrcNode, DstNode, VBuckets, false),
    ?log_info("Starting replicator with args =~n~p", [Args]),

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
              ?log_info("~nstart_child(~p, ~p, ~p, ~p, ~p)",
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


-ifdef(EUNIT).

replicas_to_replicators_test() ->
    Map = [[1, 2], [1, 2], [1, 2], [1, 2], [2, 1], [2, 1], [2, 1], [2, 1]],
    Replicas = ns_bucket:map_to_replicas(Map),

    ?assertEqual([{{1, 2}, [0, 1, 2, 3]},
                  {{2, 1}, [4, 5, 6, 7]}],
                 lists:sort(dict:to_list(replicas_to_replicators(Replicas)))).

-endif.
