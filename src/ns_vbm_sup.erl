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

-export([start_link/0,
         kill_children/3,
         kill_all_children/1,
         kill_dst_children/3,
         move/4,
         replicators/2,
         set_replicas/3]).

-export([init/1]).

%% API
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

replicators(Nodes, Bucket) ->
    lists:flatmap(
      fun (Node) ->
              try children(Node) of
                  Children ->
                      [{Node, Dst, VBucket} ||
                          {B, VBuckets, Dst, false} <- Children,
                          VBucket <- VBuckets,
                          B == Bucket]
              catch
                  _:_ -> []
              end
      end, Nodes).

actions(Children) ->
    [{VBucket, Dst} || {_, VBuckets, Dst, false} <- Children,
                       VBucket <- VBuckets].

kill_vbuckets(Node, Bucket, VBuckets) ->
    {ok, States} = ns_memcached:list_vbuckets(Node, Bucket),
    case [X || X = {V, _} <- States, lists:member(V, VBuckets)] of
        [] ->
            ok;
        RemainingVBuckets ->
            lists:foreach(fun ({V, dead}) ->
                                  ns_memcached:delete_vbucket(Node, Bucket, V);
                              ({V, _}) ->
                                  ns_memcached:set_vbucket_state(Node, Bucket,
                                                                 V, dead),
                                  ns_memcached:delete_vbucket(Node, Bucket, V)
                              end, RemainingVBuckets),
            timer:sleep(100),
            kill_vbuckets(Node, Bucket, VBuckets)
    end.

set_replicas(Node, Bucket, Replicas) ->
    case lists:member(Node, ns_node_disco:nodes_actual_proper()) of
        true ->
            GoodChildren = kill_runaway_children(Node, Bucket, Replicas),
            %% Now filter out the replicas that still have children
            Actions = actions(GoodChildren),
            NeededReplicas = Replicas -- Actions,
            Sorted = lists:keysort(2, NeededReplicas),
            Grouped = misc:keygroup(2, Sorted),
            lists:foreach(
              fun ({Dst, R}) ->
                      VBuckets = [V || {V, _} <- R],
                      ?log_info(
                         "Starting replica for vbuckets ~w on node ~p",
                         [VBuckets, Dst]),
                      kill_vbuckets(Dst, Bucket, VBuckets),
                      lists:foreach(
                        fun (V) ->
                                ns_memcached:set_vbucket_state(Dst, Bucket, V, replica)
                        end, VBuckets),
                      {ok, _Pid} = start_child(Node, Bucket, VBuckets, Dst, false)
              end, Grouped);
        false ->
            {error, nodedown}
    end.

move(Bucket, VBucket, SrcNode, DstNode) ->
    kill_children(SrcNode, Bucket, [VBucket]),
    Args = args(SrcNode, Bucket, [VBucket], DstNode, true),
    %% Delete any data from the target node. This has the added
    %% advantage of crashing us if the target node is not ready
    %% to receive data, or at least delaying us until it is.
    kill_vbuckets(DstNode, Bucket, [VBucket]),
    case misc:spawn_and_wait(
           SrcNode,
           fun () ->
                   apply(ns_port_server, start_link, Args)
           end) of
        normal -> ok;
        Reason -> {error, Reason}
    end.

kill_all_children(Node) ->
    lists:foreach(fun (Child) ->
                          kill_child(Node, Child)
                  end, children(Node)).

kill_child(Node, Child) ->
    supervisor:terminate_child({?MODULE, Node}, Child),
    ok = supervisor:delete_child({?MODULE, Node}, Child).

kill_children(Node, Bucket, VBuckets) ->
    %% Kill any existing children for these VBuckets
    Children = [Id || Id = {B, Vs, _, false} <- children(Node),
                      B == Bucket,
                      lists:subtract(Vs, VBuckets) /= Vs],
    lists:foreach(fun (Child) ->
                          kill_child(Node, Child)
                  end, Children),
    Children.

kill_dst_children(Node, Bucket, Dst) ->
    Children = [Id || Id = {B, _, D, _} <- children(Node),
                      B == Bucket,
                      D == Dst],
    lists:foreach(fun (Child) ->
                          kill_child(Node, Child)
                  end, Children).

kill_runaway_children(Node, Bucket, Replicas) ->
    %% Kill any children not in Replicas
    Children = [Child || Child = {B, _, _, _} <- children(Node), B == Bucket],
    {GoodChildren, Runaways} =
        lists:partition(
          fun ({_, VBuckets, DstNode, false}) ->
                  NodeReplicas = [{V, DstNode} || V <- VBuckets],
                  lists:all(fun (NR) -> lists:member(NR, Replicas) end,
                            NodeReplicas)
          end, Children),
    lists:foreach(
      fun (Runaway) ->
              ?log_info(
                "Killing replicator ~p on node ~p",
                 [Runaway, Node]),
              kill_child(Node, Runaway)
      end, Runaways),
    GoodChildren.


%% supervisor callbacks
init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.

%% Internal functions
args(Node, Bucket, VBuckets, DstNode, TakeOver) ->
    "default" = Bucket, % vbucketmigrator doesn't support multi-tenancy yet
    Command = "./bin/port_adaptor/port_adaptor",
    BucketArgs = lists:append([["-b", integer_to_list(B)] || B <- VBuckets]),
    TakeOverArg = case TakeOver of
                      true -> ["-t"];
                      false -> []
                  end,
    OtherArgs = ["1", "./bin/vbucketmigrator/vbucketmigrator",
                 "-h", ns_memcached:host_port_str(Node),
                 "-d", ns_memcached:host_port_str(DstNode),
                 "-v"],
    Args = lists:append([OtherArgs, TakeOverArg, BucketArgs]),
    [vbucketmigrator, Command, Args, [use_stdio, stderr_to_stdout]].

children(Node) ->
    [Id || {Id, _, _, _} <- supervisor:which_children({?MODULE, Node})].

start_child(Node, Bucket, VBuckets, DstNode, TakeOver) ->
    PortServerArgs = args(Node, Bucket, VBuckets, DstNode, TakeOver),
    ?log_info("start_child(~p, ~p, ~p, ~p, ~p):~nArgs = ~p",
              [Node, Bucket, VBuckets, DstNode, TakeOver, PortServerArgs]),
    Type = case TakeOver of true -> transient; false -> permanent end,
    ChildSpec = {{Bucket, VBuckets, DstNode, TakeOver},
                 {ns_port_server, start_link, PortServerArgs},
                 Type, 10, worker, [ns_vbm]},
    supervisor:start_child({?MODULE, Node}, ChildSpec).
