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

-define(MAX_VBUCKETS, 512). %% Maximum # of vbuckets for a vbucketmigrator

-record(child_id, {vbuckets::[non_neg_integer(), ...],
                   dest_node::atom()}).

-export([start_link/1,
         kill_children/3,
         kill_dst_children/3,
         replicators/2,
         set_replicas/3,
         spawn_mover/4]).

-export([init/1]).

%% API
start_link(Bucket) ->
    supervisor:start_link({local, server(Bucket)}, ?MODULE, []).

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

actions(Children) ->
    [{VBucket, Dst} || #child_id{vbuckets=VBuckets, dest_node=Dst} <- Children,
                       VBucket <- VBuckets].

set_replicas(Node, Bucket, Replicas) ->
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
              lists:foreach(
                fun (V) ->
                        ns_memcached:set_vbucket(Dst, Bucket, V,
                                                 replica)
                end, VBuckets),
              %% Make sure the command line doesn't get too long
              lists:foreach(
                fun (VB) ->
                        {ok, _Pid} = start_child(Node, Bucket, VB, Dst)
                end, split_vbuckets(VBuckets))
      end, Grouped).

spawn_mover(Bucket, VBucket, SrcNode, DstNode) ->
    Args = args(SrcNode, Bucket, [VBucket], DstNode, true),
    apply(ns_port_server, start_link, Args).

split_vbuckets(VBuckets) ->
    split_vbuckets(VBuckets, []).

split_vbuckets(VBuckets, L) ->
    if
        length(VBuckets) =< ?MAX_VBUCKETS ->
            [VBuckets|L];
        true ->
            {H, T} = lists:split(?MAX_VBUCKETS, VBuckets),
            split_vbuckets(T, [H|L])
    end.

-spec kill_child(node(), nonempty_string(), #child_id{}) ->
                        ok.
kill_child(Node, Bucket, Child) ->
    case supervisor:terminate_child({server(Bucket), Node}, Child) of
        ok ->
            supervisor:delete_child({server(Bucket), Node}, Child);
        {error, not_found} ->
            ok
    end.

-spec kill_children(node(), nonempty_string(), [non_neg_integer()]) ->
                           [#child_id{}].
kill_children(Node, Bucket, VBuckets) ->
    %% Kill any existing children for these VBuckets
    Children = [Id || Id = #child_id{vbuckets=Vs} <-
                          children(Node, Bucket),
                      Vs -- VBuckets /= Vs],
    lists:foreach(fun (Child) ->
                          kill_child(Node, Bucket, Child)
                  end, Children),
    Children.

-spec kill_dst_children(node(), nonempty_string(), node()) ->
                               ok.
kill_dst_children(Node, Bucket, Dst) ->
    Children = [Id || Id = #child_id{dest_node=D} <- children(Node, Bucket),
                      D == Dst],
    lists:foreach(fun (Child) ->
                          kill_child(Node, Bucket, Child)
                  end, Children).

-spec kill_runaway_children(node(), nonempty_string(),
                            [{non_neg_integer(), node()}]) ->
                                   [#child_id{}].
kill_runaway_children(Node, Bucket, Replicas) ->
    %% Kill any children not in Replicas
    {GoodChildren, Runaways} =
        lists:partition(
          fun (#child_id{vbuckets=VBuckets, dest_node=DstNode}) ->
                  NodeReplicas = [{V, DstNode} || V <- VBuckets],
                  lists:all(fun (NR) -> lists:member(NR, Replicas) end,
                            NodeReplicas)
          end, children(Node, Bucket)),
    lists:foreach(
      fun (Runaway) ->
              ?log_info(
                "Killing replicator ~p on node ~p",
                 [Runaway, Node]),
              kill_child(Node, Bucket, Runaway)
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
    Command = "./bin/vbucketmigrator/vbucketmigrator",
    VBucketArgs = lists:append([["-b", integer_to_list(B)] || B <- VBuckets]),
    TakeOverArg = case TakeOver of
                      true -> ["-t", % transfer the vbucket
                               "-T", "60", % Timeout in seconds
                               "-V" % Verify that transfer actually happened
                              ];
                      false -> []
                  end,
    {User, Pass} = ns_bucket:credentials(Bucket),
    OtherArgs = ["-e", "-a", User,
                 "-h", ns_memcached:host_port_str(Node),
                 "-d", ns_memcached:host_port_str(DstNode),
                 "-v"],
    Args = lists:append([OtherArgs, TakeOverArg, VBucketArgs]),
    [vbucketmigrator, Command, Args,
     [use_stdio, stderr_to_stdout,
      {write_data, [Pass, "\n"]}]].

-spec children(node(), nonempty_string()) -> [#child_id{}].
children(Node, Bucket) ->
    [Id || {Id, _, _, _} <- supervisor:which_children({server(Bucket), Node})].


-spec server(nonempty_string()) ->
                    atom().
server(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).


-spec start_child(atom(), nonempty_string(), [non_neg_integer(),...], atom()) ->
                         {ok, pid()}.
start_child(Node, Bucket, VBuckets, DstNode) ->
    PortServerArgs = args(Node, Bucket, VBuckets, DstNode, false),
    ?log_info("Args =~n~p",
              [PortServerArgs]),
    ChildSpec = {#child_id{vbuckets=VBuckets, dest_node=DstNode},
                 {ns_port_server, start_link, PortServerArgs},
                 permanent, 10, worker, [ns_port_server]},
    supervisor:start_child({server(Bucket), Node}, ChildSpec).
