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

%% identifier of ns_vbm_new childs in supervisors. NOTE: vbuckets
%% field is sorted. We could use ordsets::ordset() type, but we also
%% want to underline that vbuckets field is never empty.
-record(child_id, {vbuckets::[non_neg_integer(), ...],
                   dest_node::atom()}).

%% API
-export([start_link/1]).

%% Callbacks
-export([server_name/1, supervisor_node/2,
         make_replicator/3, replicator_nodes/2, replicator_vbuckets/1]).

%%
%% API
%%
start_link(Bucket) ->
    cb_gen_vbm_sup:start_link(?MODULE, Bucket).

%%
%% Callbacks
%%
-spec server_name(bucket_name()) -> atom().
server_name(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).

-spec supervisor_node(node(), node()) -> node().
supervisor_node(SrcNode, _DstNode) ->
    SrcNode.

-spec make_replicator(node(), node(), [vbucket_id(), ...]) -> #child_id{}.
make_replicator(_SrcNode, DstNode, VBuckets) ->
    #child_id{vbuckets=VBuckets, dest_node=DstNode}.

-spec replicator_nodes(node(), #child_id{}) -> {node(), node()}.
replicator_nodes(SupervisorNode, #child_id{dest_node=Node}) ->
    {SupervisorNode, Node}.

-spec replicator_vbuckets(#child_id{}) -> [vbucket_id(), ...].
replicator_vbuckets(#child_id{vbuckets=VBuckets}) ->
    VBuckets.
