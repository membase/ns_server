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
-module(ns_vbm_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-record(child_id, {vbuckets::[non_neg_integer(), ...],
                   dest_node::atom()}).

-export([start_link/1,
         kill_all_local_children/1,
         replicators/2,
         set_src_dst_vbucket_replicas/2,
         set_vbucket_replications/4,
         have_local_change_vbucket_filter/0,
         local_change_vbucket_filter/4]).

-export([init/1]).

%%
%% API
%%
start_link(Bucket) ->
    supervisor:start_link({local, server(Bucket)}, ?MODULE, []).


-spec set_vbucket_replications(pid(),
                               bucket_name(),
                               vbucket_id(),
                               [{node(), node() | undefined}]) -> ok.
set_vbucket_replications(RebalancerPid, Bucket, VBucket, DstSrcPairs) ->
    RebalancerPid = self(),
    AffectedNodes = ns_node_disco:nodes_wanted(),
    NodeChildrens = misc:parallel_map(
                      fun (Node) ->
                              Children = try children(Node, Bucket) catch _:_ -> [] end,
                              {Node, Children}
                      end, AffectedNodes, infinity),
    ReplicatorsList =
        lists:flatmap(
          fun ({Node, Children}) ->
                  [{Node, Dst, VB}
                   || #child_id{vbuckets=VBuckets, dest_node=Dst} <- Children,
                      VB <- VBuckets]
          end, NodeChildrens),
    AffectedDst = sets:from_list([Dst || {Dst, _} <- DstSrcPairs]),
    ReplicatorsWithoutAffectedTriples = [Triple
                                         || {_Src, Dst, VB} = Triple <- ReplicatorsList,
                                            not (VB =:= VBucket andalso sets:is_element(Dst, AffectedDst))],
    NewReplicators = [{Src, Dst, VBucket}
                      || {Dst, Src} <- DstSrcPairs,
                         Src =/= undefined]
        ++ ReplicatorsWithoutAffectedTriples,
    GroupedReplicators0 = misc:keygroup(1, lists:sort(NewReplicators)),
    GroupedReplicators = [{Node, [{VB, Dst} || {_, Dst, VB} <- Group]}
                          || {Node, Group} <- GroupedReplicators0],
    set_replicas_on_nodes(Bucket, GroupedReplicators, AffectedNodes).

replicators(Nodes, Bucket) ->
    lists:flatmap(
      fun (Node) ->
              try children(Node, Bucket) of
                  Children ->
                      [{Node, Dst, VBucket} ||
                          #child_id{vbuckets=VBuckets, dest_node=Dst}
                              <- Children,
                          VBucket <- VBuckets]
              catch
                  _:_ -> []
              end
      end, Nodes).

set_src_dst_vbucket_replicas(Bucket, SrcDstVBucketTriples) ->
    Replicas = lists:keysort(1, SrcDstVBucketTriples),
    ReplicaGroups = misc:keygroup(1, Replicas),
    NodesReplicas = lists:map(fun ({Src, R}) -> % R is the replicas for this node
                                      {Src, [{V, Dst} || {_, Dst, V} <- R]}
                              end, ReplicaGroups),
    set_replicas_on_nodes(Bucket, NodesReplicas, [node() | nodes()]).

-spec set_replicas_on_nodes(bucket_name(), [{node(), [{node(), vbucket_id()}]}], [node()]) -> ok.
set_replicas_on_nodes(Bucket, NodesReplicas, LiveNodes) ->
    %% Replace with the empty list if replication is disabled
    NR = case ns_config:search_node_prop(node(), ns_config:get(), replication,
                                    enabled, true) of
             true ->
                 NodesReplicas;
             false -> []
         end,
    %% Kill all replicators on nodes not in NR
    NodesWithoutReplicas = LiveNodes -- [N || {N, _} <- NR],
    lists:foreach(fun (Node) -> kill_all_children(Node, Bucket) end,
                  NodesWithoutReplicas),
    lists:foreach(
      fun ({Src, R}) ->
              case lists:member(Src, LiveNodes) of
                  true ->
                      try set_replicas(Src, Bucket, R)
                      catch
                          E:R ->
                              ?log_error("Unable to start replicators on ~p for bucket ~p: ~p",
                                         [Src, Bucket, {E, R}])
                      end;
                  false ->
                      ok
              end
      end, NR).


-spec kill_all_children(node(), bucket_name()) ->
                               ok.
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

kill_all_local_children(Bucket) ->
    kill_all_children(node(), Bucket).

-spec kill_child(node(), nonempty_string(), #child_id{}) ->
                        ok.
kill_child(Node, Bucket, Child) ->
    ?log_debug("Stopping replicator:~p on ~p", [Child, {Node, Bucket}]),
    ok = supervisor:terminate_child({server(Bucket), Node}, Child),
    ok = supervisor:delete_child({server(Bucket), Node}, Child),
    ?log_info("Stopped replicator:~p on ~p", [Child, {Node, Bucket}]),
    ok.

%% supervisor callbacks
init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.

%%
%% Internal functions
%%

-spec args(atom(), nonempty_string(), [non_neg_integer(),...], atom(), boolean(), list()) ->
                  [any(), ...].
args(Node, Bucket, VBuckets, DstNode, false = TakeOver, ExtraOptions) ->
    {User, Pass} = ebucketmigrator_srv:get_bucket_credentials(Node, Bucket),
    %% We want to reuse names for replication.
    Suffix = atom_to_list(DstNode),
    [ns_memcached:host_port(Node), ns_memcached:host_port(DstNode),
     [{username, User},
      {password, Pass},
      {vbuckets, VBuckets},
      {takeover, TakeOver},
      {suffix, Suffix} | ExtraOptions]].

-spec children(node(), nonempty_string()) -> [#child_id{}].
children(Node, Bucket) ->
    [Id || {Id, _, _, _} <- supervisor:which_children({server(Bucket), Node})].


%% @private

-spec server(nonempty_string()) ->
                    atom().
server(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).

have_local_change_vbucket_filter() ->
    true.

local_change_vbucket_filter(Bucket, SrcNode, #child_id{dest_node=DstNode} = ChildId, NewVBuckets) ->
    NewChildId = #child_id{vbuckets=NewVBuckets, dest_node=DstNode},
    Args = ebucketmigrator_srv:build_args(node(), Bucket,
                                          SrcNode, DstNode, NewVBuckets, false),
    MFA = {ebucketmigrator_srv, start_old_vbucket_filter_change, []},

    {ok, ns_vbm_new_sup:perform_vbucket_filter_change(Bucket,
                                                      ChildId,
                                                      NewChildId,
                                                      Args,
                                                      MFA,
                                                      server(Bucket))}.

change_vbucket_filter(Bucket, SrcNode, #child_id{dest_node = DstNode} = ChildId, NewVBuckets) ->
    HaveChangeFilterKey = rpc:async_call(SrcNode, ns_vbm_sup, have_local_change_vbucket_filter, []),
    ChangeFilterRV = rpc:call(SrcNode, ns_vbm_sup, local_change_vbucket_filter,
                              [Bucket, SrcNode, ChildId, NewVBuckets]),
    HaveChangeFilterRV = rpc:yield(HaveChangeFilterKey),
    case ChangeFilterRV of
        {ok, Ref} ->
            true = HaveChangeFilterRV,
            Ref;
        {badrpc, Error} ->
            case HaveChangeFilterRV of
                true ->
                    erlang:error({change_filter_failed, Error});
                {badrpc, {'EXIT', {undef, _}}} ->
                    system_stats_collector:increment_counter(old_style_vbucket_filter_changes, 1),
                    kill_child(SrcNode, Bucket, ChildId),
                    start_child(SrcNode, Bucket, NewVBuckets, DstNode)
            end
    end.

%% @doc Set up replication from the given source node to a list of
%% {VBucket, DstNode} pairs.
set_replicas(SrcNode, Bucket, Replicas) ->
    %% A dictionary mapping destination node to a sorted list of
    %% vbuckets to replicate there from SrcNode.
    DesiredReplicaDict =
        dict:map(
          fun (_, V) -> lists:usort(V) end,
          lists:foldl(
            fun ({VBucket, DstNode}, D) ->
                    dict:append(DstNode, VBucket, D)
            end, dict:new(), Replicas)),
    %% Remove any destination nodes from the dictionary that the
    %% replication is already correct for.
    NeededReplicas =
        dict:to_list(
          lists:foldl(
            fun (#child_id{dest_node=DstNode, vbuckets=VBuckets} = Id, D) ->
                    case dict:find(DstNode, DesiredReplicaDict) of
                        {ok, VBuckets} ->
                            %% Already running
                            dict:erase(DstNode, D);
                        {ok, NewVBuckets} ->
                            change_vbucket_filter(Bucket, SrcNode, Id, NewVBuckets),
                            dict:erase(DstNode, D);
                        _ ->
                            %% Either wrong vbuckets or not wanted at all
                            kill_child(SrcNode, Bucket, Id),
                            D
                    end
            end, DesiredReplicaDict, children(SrcNode, Bucket))),
    lists:foreach(
      fun ({DstNode, VBuckets}) ->
              start_child(SrcNode, Bucket, VBuckets, DstNode)
      end, NeededReplicas).


-spec start_child(atom(), nonempty_string(), [non_neg_integer(),...], atom()) ->
                         {ok, pid()}.
start_child(Node, Bucket, VBuckets, DstNode) ->
    Args = args(Node, Bucket, VBuckets, DstNode, false, []),
    ?log_debug("Starting replicator with args =~n~p", [Args]),
    ChildSpec = {#child_id{vbuckets=VBuckets, dest_node=DstNode},
                 {ebucketmigrator_srv, start_link, Args},
                 permanent, 60000, worker, [ebucketmigrator_srv]},
    supervisor:start_child({server(Bucket), Node}, ChildSpec).
