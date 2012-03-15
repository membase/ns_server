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

-include("ns_common.hrl").

%% identifier of ns_vbm_sup childs in supervisors. NOTE: vbuckets
%% field is sorted. We could use ordsets::ordset() type, but we also
%% want to underline that vbuckets field is never empty.
-record(new_child_id, {vbuckets::[vbucket_id(), ...],
                       src_node::node()}).

%% API
-export([start_link/1,
         add_replica/4,
         kill_replica/4,
         set_replicas/2,
         set_replicas/3,
         apply_changes/2,
         stop_replications/3,
         replicas/2,
         node_replicator_triples/2]).

%% Callbacks
-export([server_name/1, supervisor_node/2,
         make_replicator/3, replicator_nodes/2, replicator_vbuckets/1]).


%%
%% API
%%
start_link(Bucket) ->
    cb_gen_vbm_sup:start_link(?MODULE, Bucket).

add_replica(Bucket, SrcNode, DstNode, VBucket) ->
    cb_gen_vbm_sup:add_replica(?MODULE, Bucket, SrcNode, DstNode, VBucket).

kill_replica(Bucket, SrcNode, DstNode, VBucket) ->
    cb_gen_vbm_sup:kill_replica(?MODULE, Bucket, SrcNode, DstNode, VBucket).

set_replicas(Bucket, Replicas) ->
    cb_gen_vbm_sup:set_replicas(?MODULE, Bucket, Replicas).

set_replicas(Bucket, Replicas, AllNodes) ->
    cb_gen_vbm_sup:set_replicas(?MODULE, Bucket, Replicas, AllNodes).

apply_changes(Bucket, ChangeTuples) ->
    cb_gen_vbm_sup:apply_changes(?MODULE, Bucket, ChangeTuples).

stop_replications(Bucket, Node, VBuckets) ->
    cb_gen_vbm_sup:stop_replications(?MODULE, Bucket, Node, VBuckets).

replicas(Bucket, Nodes) ->
    cb_gen_vbm_sup:replicas(?MODULE, Bucket, Nodes).

node_replicator_triples(Bucket, Node) ->
    cb_gen_vbm_sup:node_replicator_triples(?MODULE, Bucket, Node).

%%
%% Callbacks
%%
-spec server_name(bucket_name()) -> atom().
server_name(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).

-spec supervisor_node(node(), node()) -> node().
supervisor_node(_SrcNode, DstNode) ->
    DstNode.

-spec make_replicator(node(), node(), [vbucket_id(), ...]) -> #new_child_id{}.
make_replicator(SrcNode, _DstNode, VBuckets) ->
    #new_child_id{vbuckets=VBuckets, src_node=SrcNode}.

-spec replicator_nodes(node(), #new_child_id{}) -> {node(), node()}.
replicator_nodes(SupervisorNode, #new_child_id{src_node=Node}) ->
    {Node, SupervisorNode}.

-spec replicator_vbuckets(#new_child_id{}) -> [vbucket_id(), ...].
replicator_vbuckets(#new_child_id{vbuckets=VBuckets}) ->
    VBuckets.
