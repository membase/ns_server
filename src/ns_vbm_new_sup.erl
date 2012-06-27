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
-module(ns_vbm_new_sup).

-include("ns_common.hrl").
-include("ns_version_info.hrl").

%% identifier of ns_vbm_new_sup childs in supervisors. NOTE: vbuckets
%% field is sorted. We could use ordsets::ordset() type, but we also
%% want to underline that vbuckets field is never empty.
-record(new_child_id, {vbuckets::[vbucket_id(), ...],
                       src_node::node()}).

%% API
-export([start_link/1]).

%% Callbacks
-export([server_name/1, supervisor_node/2,
         make_replicator/3, replicator_nodes/2, replicator_vbuckets/1,
         change_vbucket_filter/5]).

-export([local_change_vbucket_filter/4]).

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

local_change_vbucket_filter(Bucket, DstNode, #new_child_id{src_node=SrcNode} = ChildId, NewVBuckets) ->
    NewChildId = #new_child_id{src_node = SrcNode,
                               vbuckets = NewVBuckets},
    Args = ebucketmigrator_srv:build_args(Bucket,
                                          SrcNode, DstNode, NewVBuckets, false),

    MFA =
        case ns_version_info:node_compatible(SrcNode, ?VERSION_200) of
            true ->
                {ebucketmigrator_srv,
                 start_vbucket_filter_change, [NewVBuckets]};
            false ->
                {ebucketmigrator_srv,
                 start_old_vbucket_filter_change, []}
        end,

    {ok, cb_gen_vbm_sup:perform_vbucket_filter_change(Bucket,
                                                      ChildId,
                                                      NewChildId,
                                                      Args,
                                                      MFA,
                                                      server_name(Bucket))}.

-spec change_vbucket_filter(bucket_name(), node(), node(), #new_child_id{}, [vbucket_id(),...]) ->
                                   {ok, pid()}.
change_vbucket_filter(Bucket, _SrcNode, DstNode, Child, NewVBuckets) ->
    {ok, _} = RV = rpc:call(DstNode, ns_vbm_new_sup, local_change_vbucket_filter,
                            [Bucket, DstNode, Child, NewVBuckets]),
    RV.
