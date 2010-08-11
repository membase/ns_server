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

-record(child_id, {bucket::nonempty_string(),
                   vbuckets::[non_neg_integer(), ...],
                   dest_node::atom()}).

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
                          #child_id{bucket=B, vbuckets=VBuckets, dest_node=Dst}
                              <- Children,
                          VBucket <- VBuckets,
                          B == Bucket]
              catch
                  _:_ -> []
              end
      end, Nodes).

actions(Children) ->
    [{VBucket, Dst} || #child_id{vbuckets=VBuckets, dest_node=Dst} <- Children,
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
                      {ok, _Pid} = start_child(Node, Bucket, VBuckets, Dst)
              end, Grouped);
        false ->
            {error, nodedown}
    end.

move(Bucket, VBucket, SrcNode, DstNode) ->
    Args = args(SrcNode, Bucket, [VBucket], DstNode, true),
    %% Delete any data from the target node. This has the added
    %% advantage of crashing us if the target node is not ready
    %% to receive data, or at least delaying us until it is.
    kill_vbuckets(DstNode, Bucket, [VBucket]),
    {ok, Pid} = rpc:call(SrcNode, ns_port_server, start_link, Args),
    ok = misc:wait_for_process(Pid, infinity),
    kill_children(SrcNode, Bucket, [VBucket]).

kill_all_children(Node) ->
    lists:foreach(fun (Child) ->
                          kill_child(Node, Child)
                  end, children(Node)).

kill_child(Node, Child) ->
    case supervisor:terminate_child({?MODULE, Node}, Child) of
        ok ->
            supervisor:delete_child({?MODULE, Node}, Child);
        {error, not_found} ->
            ok
    end.

kill_children(Node, Bucket, VBuckets) ->
    %% Kill any existing children for these VBuckets
    Children = [Id || Id = #child_id{bucket=B, vbuckets=Vs} <- children(Node),
                      B == Bucket,
                      Vs -- VBuckets /= Vs],
    lists:foreach(fun (Child) ->
                          kill_child(Node, Child)
                  end, Children),
    Children.

kill_dst_children(Node, Bucket, Dst) ->
    Children = [Id || Id = #child_id{bucket=B, dest_node=D} <- children(Node),
                      B == Bucket,
                      D == Dst],
    lists:foreach(fun (Child) ->
                          kill_child(Node, Child)
                  end, Children).

kill_runaway_children(Node, Bucket, Replicas) ->
    %% Kill any children not in Replicas
    Children = [Child || Child = #child_id{bucket=B} <- children(Node),
                         B == Bucket],
    {GoodChildren, Runaways} =
        lists:partition(
          fun (#child_id{vbuckets=VBuckets, dest_node=DstNode}) ->
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
-spec args(atom(), nonempty_string(), [non_neg_integer(),...], atom(), boolean()) ->
                  [any(), ...].
args(Node, Bucket, VBuckets, DstNode, TakeOver) ->
    "default" = Bucket, % vbucketmigrator doesn't support multi-tenancy yet
    Command = "./bin/port_adaptor/port_adaptor",
    VBucketArgs = lists:append([["-b", integer_to_list(B)] || B <- VBuckets]),
    TakeOverArg = case TakeOver of
                      true -> ["-t",
                               "-T", "10" %% Timeout iff no message in 10s during xfer
                              ];
                      false -> []
                  end,
    {User, Pass} = ns_bucket:credentials(Bucket),
    OtherArgs = ["1", "./bin/vbucketmigrator/vbucketmigrator",
                 "-a", User,
                 "-p", Pass,
                 "-h", ns_memcached:host_port_str(Node),
                 "-d", ns_memcached:host_port_str(DstNode),
                 "-v"],
    Args = lists:append([OtherArgs, TakeOverArg, VBucketArgs]),
    [vbucketmigrator, Command, Args, [use_stdio, stderr_to_stdout]].

-spec children(atom()) -> [#child_id{}].
children(Node) ->
    [Id || {Id, _, _, _} <- supervisor:which_children({?MODULE, Node})].

-spec start_child(atom(), nonempty_string(), [non_neg_integer(),...], atom()) ->
                         {ok, pid()}.
start_child(Node, Bucket, VBuckets, DstNode) ->
    PortServerArgs = args(Node, Bucket, VBuckets, DstNode, false),
    ?log_info("start_child(~p, ~p, ~p, ~p):~nArgs = ~p",
              [Node, Bucket, VBuckets, DstNode, PortServerArgs]),
    ChildSpec = {#child_id{bucket=Bucket, vbuckets=VBuckets, dest_node=DstNode},
                 {ns_port_server, start_link, PortServerArgs},
                 permanent, 10, worker, [ns_port_server]},
    supervisor:start_child({?MODULE, Node}, ChildSpec).
