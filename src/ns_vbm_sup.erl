%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
-module(ns_vbm_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-record(new_child_id, {vbuckets::[vbucket_id(), ...],
                       src_node::node()}).

-export([start_link/1,
         add_replica/4,
         kill_replica/4,
         stop_incoming_replications/3,
         replicators/2,
         set_replicas_dst/2,
         apply_changes/2,
         spawn_mover/4]).

-export([init/1]).

%%
%% API
%%
start_link(Bucket) ->
    supervisor:start_link({local, server(Bucket)}, ?MODULE, []).


%% @doc Add a vbucket to the filter for a given source and destination
%% node.
add_replica(Bucket, SrcNode, DstNode, VBucket) ->
    VBuckets =
        case get_replicator(Bucket, SrcNode, DstNode) of
            undefined ->
                [VBucket];
            #new_child_id{vbuckets=Vs} = Child ->
                kill_child(DstNode, Bucket, Child),
                [VBucket|Vs]
        end,
    {ok, _} = start_child(SrcNode, Bucket, VBuckets, DstNode).


%% @doc Kill any replication for a given destination node and vbucket.
kill_replica(Bucket, SrcNode, DstNode, VBucket) ->
    case get_replicator(Bucket, SrcNode, DstNode) of
        undefined ->
            ok;
        #new_child_id{vbuckets=VBuckets} = Child ->
            %% Kill the child and start it again without this vbucket.
            kill_child(DstNode, Bucket, Child),
            case VBuckets of
                [VBucket] ->
                    %% just kill when it was last vbucket
                    ?log_info("~p: killed last vbucket (~p) for destination ~p", [SrcNode, VBucket, DstNode]),
                    ok;
                _ ->
                    {ok, _} = start_child(SrcNode, Bucket, VBuckets -- [VBucket],
                                          DstNode)
            end
    end.

apply_changes(Bucket, ChangeTuples) ->
    ?log_info("Applying changes:~n~p~n", [ChangeTuples]),
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    RelevantNodes = proplists:get_value(servers, BucketConfig),
    true = is_list(RelevantNodes),
    ReplicatorsList =
        lists:flatmap(
          fun (Dst) ->
                  Children = try children(Dst, Bucket) catch _:_ -> [] end,
                  [{{Src, Dst}, lists:sort(VBuckets)}
                   || #new_child_id{vbuckets=VBuckets, src_node=Src} <- Children]
          end, RelevantNodes),
    Replicators = dict:from_list(ReplicatorsList),
    NewReplicators =
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
                            dict:store(Key, NewVBuckets, CurrentReplicators)
                    end, Replicators, ChangeTuples),
    NewReplicasPre =
        dict:fold(fun ({SrcNode, DstNode}, VBuckets, Dict) ->
                          PrevValue = case dict:find(DstNode, Dict) of
                                          error -> [];
                                          {ok, X} -> X
                                      end,
                          NewValue = [[{V, SrcNode} || V <- VBuckets] | PrevValue],
                          dict:store(DstNode, NewValue, Dict)
                  end, dict:new(), NewReplicators),
    NewReplicas = dict:map(fun (_K, V) -> lists:append(V) end, NewReplicasPre),
    ActualChangesCount =
        dict:fold(fun (K, V, Count) ->
                          case dict:find(K, Replicators) of
                              {ok, V} ->        % NOTE: V is bound
                                  Count;
                              _ -> Count+1
                          end
                  end, 0, NewReplicators)
        + dict:fold(fun (K, _V, Count) ->
                            case dict:find(K, NewReplicators) of
                                {ok, _} ->
                                    Count;
                                _ -> Count+1
                            end
                    end, 0, Replicators),
    NewReplicasList = dict:to_list(NewReplicas),
    set_replicas_dst(Bucket, NewReplicasList),
    ActualChangesCount.


-spec replicators([Node::node()], Bucket::bucket_name()) ->
                         [{Src::node(), Dst::node(), VBucket::vbucket_id()}].
replicators(Nodes, Bucket) ->
    lists:flatmap(
      fun (Dst) ->
              try children(Dst, Bucket) of
                  Children ->
                      [{Src, Dst, VBucket} ||
                          #new_child_id{vbuckets=VBuckets, src_node=Src}
                              <- Children,
                          VBucket <- VBuckets]
              catch
                  _:_ -> []
              end
      end, Nodes).

-spec set_replicas_dst(Bucket::bucket_name(),
                       [{Dst::node(), [{VBucketID::vbucket_id(), Src::node()}]}]) -> ok.
set_replicas_dst(Bucket, NodesReplicas) ->
    %% Replace with the empty list if replication is disabled
    NR = case ns_config:search_node_prop(node(), ns_config:get(), replication,
                                    enabled, true) of
             true ->
                 NodesReplicas;
             false -> []
         end,
    LiveNodes = ns_node_disco:nodes_actual_proper(),
    %% Kill all replicators on nodes not in NR
    NodesWithoutReplicas = LiveNodes -- [N || {N, _} <- NR],
    lists:foreach(fun (Node) -> kill_all_children(Node, Bucket) end,
                  NodesWithoutReplicas),
    lists:foreach(
      fun ({Dst, R}) ->
              case lists:member(Dst, LiveNodes) of
                  true ->
                      try set_nodes_replicas(Dst, Bucket, R)
                      catch
                          E:R ->
                              ?log_error("Unable to start replicators on ~p for bucket ~p: ~p",
                                         [Dst, Bucket, {E, R}])
                      end;
                  false ->
                      ok
              end
      end, NR).


spawn_mover(Bucket, VBucket, SrcNode, DstNode) ->
    Args0 = args(SrcNode, Bucket, [VBucket], DstNode, true),
    %% start ebucketmigrator on source node
    Args = [SrcNode | Args0],
    case apply(ebucketmigrator_srv, start_link, Args) of
        {ok, Pid} = RV ->
            ?log_info("Spawned mover ~p ~p ~p -> ~p: ~p",
                      [Bucket, VBucket, SrcNode, DstNode, Pid]),
            RV;
        X -> X
    end.

-spec kill_all_children(node(), bucket_name()) -> ok.
kill_all_children(Node, Bucket) ->
    try children(Node, Bucket) of
        Children ->
            lists:foreach(fun (Child) -> kill_child(Node, Bucket, Child) end,
                          Children)
    catch exit:{noproc, _} ->
            %% If the supervisor isn't running, obviously there's no
            %% replication.
            ok
    end.



-spec kill_child(node(), bucket_name(), #new_child_id{}) ->
                        ok.
kill_child(Node, Bucket, Child) ->
    ok = supervisor:terminate_child({server(Bucket), Node}, Child),
    ok = supervisor:delete_child({server(Bucket), Node}, Child).


-spec stop_incoming_replications(Node::node(),
                                 Bucket::bucket_name(),
                                 VBuckets::[vbucket_id()]) ->
                               [#new_child_id{}].
stop_incoming_replications(Node, Bucket, VBuckets) ->
    %% Kill any existing children for these VBuckets
    Children = [Id || Id = #new_child_id{vbuckets=Vs} <-
                          children(Node, Bucket),
                      Vs -- VBuckets /= Vs],
    lists:foreach(fun (Child) ->
                          kill_child(Node, Bucket, Child)
                  end, Children),
    Children.

%% supervisor callbacks
init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.

%%
%% Internal functions
%%

-spec args(SrcNode::node(),
           Bucket::bucket_name(),
           VBuckets::[vbucket_id(),...],
           DstNode::node(),
           TakeOver::boolean()) ->
                  [any(), ...].
args(SrcNode, Bucket, VBuckets, DstNode, TakeOver) ->
    {User, Pass} = ns_bucket:credentials(Bucket),
    Suffix = case TakeOver of
                 true ->
                     [VBucket] = VBuckets,
                     integer_to_list(VBucket);
                 false ->
                     %% We want to reuse names for replication.
                     atom_to_list(DstNode)
             end,
    [ns_memcached:host_port(SrcNode), ns_memcached:host_port(DstNode),
     [{username, User},
      {password, Pass},
      {vbuckets, VBuckets},
      {takeover, TakeOver},
      {suffix, Suffix}]].

-spec children(node(), bucket_name()) -> [#new_child_id{}].
children(Node, Bucket) ->
    [Id || {Id, _, _, _} <- supervisor:which_children({server(Bucket), Node})].


%% @private
%% @doc Get the replicator for a given source and destination node.
-spec get_replicator(bucket_name(), node(), node()) ->
                            #new_child_id{} | undefined.
get_replicator(Bucket, SrcNode, DstNode) ->
    case [Id || {#new_child_id{src_node=N} = Id, _, _, _}
                    <- supervisor:which_children({server(Bucket), DstNode}),
                N == SrcNode] of
        [Child] ->
            Child;
        [] ->
            undefined
    end.



-spec server(bucket_name()) ->
                    atom().
server(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).


%% @doc Set up replication to the given dst node from a list of
%% {VBucket, SrcNode} pairs. NOTE: it kills any replications on that
%% dst node that are not in given list. So it makes replicators on
%% that node be equal to given list.
-spec set_nodes_replicas(DstNode::node(),
                         Bucket::bucket_name(),
                         [{VBucketID::vbucket_id(), SrcNode::node()}]) -> ok.
set_nodes_replicas(DstNode, Bucket, Replicas) ->
    %% A dictionary mapping source node to a sorted list of
    %% vbuckets to replicate from there to DstNode.
    DesiredReplicaDict =
        dict:map(
          fun (_, V) -> lists:usort(V) end,
          lists:foldl(
            fun ({VBucket, SrcNode}, D) ->
                    dict:append(SrcNode, VBucket, D)
            end, dict:new(), Replicas)),
    %% Remove any source nodes from the dictionary that the
    %% replication is already correct for.
    NeededReplicas =
        dict:to_list(
          lists:foldl(
            fun (#new_child_id{src_node=SrcNode, vbuckets=VBuckets} = Id, D) ->
                    case dict:find(SrcNode, DesiredReplicaDict) of
                        {ok, VBuckets} ->
                            %% Already running
                            dict:erase(SrcNode, D);
                        _ ->
                            %% Either wrong vbuckets or not wanted at all
                            ?log_info("kill_child(~p,~p,~p)", [DstNode, Bucket, Id]),
                            kill_child(DstNode, Bucket, Id),
                            D
                    end
            end, DesiredReplicaDict, children(DstNode, Bucket))),
    lists:foreach(
      fun ({SrcNode, VBuckets}) ->
              ?log_info("start_child(~p,~p,~p,~p)", [SrcNode, Bucket, VBuckets, DstNode]),
              start_child(SrcNode, Bucket, VBuckets, DstNode)
      end, NeededReplicas).


-spec start_child(node(), bucket_name(), [vbucket_id(),...], node()) ->
                         {ok, pid()}.
start_child(SrcNode, Bucket, VBuckets, DstNode) ->
    Args = args(SrcNode, Bucket, VBuckets, DstNode, false),
    ?log_info("Starting replicator with args =~n~p",
              [Args]),
    ChildSpec = {#new_child_id{vbuckets=VBuckets, src_node=SrcNode},
                 {ebucketmigrator_srv, start_link, Args},
                 permanent, 60000, worker, [ebucketmigrator_srv]},
    supervisor:start_child({server(Bucket), DstNode}, ChildSpec).
