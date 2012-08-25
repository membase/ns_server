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

-module(replication_changes).

-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([get_incoming_replication_map/1,
         set_incoming_replication_map/2,
         set_incoming_replication_map/3]).

-spec get_incoming_replication_map(Bucket::bucket_name()) ->
                                          not_running |
                                          [{Node::node(), [non_neg_integer()]}].
get_incoming_replication_map(Bucket) ->
    case get_children(Bucket) of
        not_running -> not_running;
        Kids ->
            lists:sort([{_Node, _VBuckets} = childs_node_and_vbuckets(Child) || Child <- Kids])
    end.

set_incoming_replication_map(Bucket, DesiredReps) ->
    case get_incoming_replication_map(Bucket) of
        %% TODO: not_running handling
        CurrentReps when is_list(CurrentReps) ->
            set_incoming_replication_map(Bucket, DesiredReps, CurrentReps)
    end.

replications_difference(RepsA, RepsB) ->
    L = [{N, VBs, []} || {N, VBs} <- RepsA],
    R = [{N, [], VBs} || {N, VBs} <- RepsB],
    MergeFn = fun ({N, VBsL, []}, {N, [], VBsR}) ->
                      {N, VBsL, VBsR}
              end,
    misc:ukeymergewith(MergeFn, 1, L, R).

set_incoming_replication_map(Bucket, DesiredReps, CurrentReps) ->
    Diff = replications_difference(DesiredReps, CurrentReps),
    NodesToKill = [{N, VBs} || {N, [], VBs} <- Diff],
    NodesToStart = [{N, VBs} || {N, VBs, []} <- Diff],
    NodesToChange = [T
                     || {_N, NewVBs, OldVBs} = T <- Diff,
                        NewVBs =/= OldVBs],
    [kill_child(Bucket, SrcNode, VBuckets)
     || {SrcNode, VBuckets} <- NodesToKill],
    [start_child(Bucket, SrcNode, VBuckets)
     || {SrcNode, VBuckets} <- NodesToStart],
    [change_vbucket_filter(Bucket, SrcNode, OldVBs, NewVBs)
     || {SrcNode, NewVBs, OldVBs} <- NodesToChange],
    ok.


start_child(Bucket, SrcNode, VBuckets) ->
    ?log_info("Starting replication from ~p for~n~p", [SrcNode, VBuckets]),
    [] = _MaybeSameSrcNode = [Child || Child <- get_children(Bucket),
                                       {SrcNodeC, _} <- [childs_node_and_vbuckets(Child)],
                                       SrcNodeC =:= SrcNode],
    Sup = ns_vbm_new_sup:server_name(Bucket),
    Child = ns_vbm_new_sup:make_replicator(SrcNode, SrcNode, VBuckets),
    ChildSpec = child_to_supervisor_spec(Bucket, Child),
    supervisor:start_child(Sup, ChildSpec).

kill_child(Bucket, SrcNode, VBuckets) ->
    ?log_info("Going to stop replication from ~p", [SrcNode]),
    Sup = ns_vbm_new_sup:server_name(Bucket),
    Child = ns_vbm_new_sup:make_replicator(SrcNode, SrcNode, VBuckets),
    ok = supervisor:terminate_child(Sup, Child).

change_vbucket_filter(Bucket, SrcNode, OldVBuckets, NewVBuckets) ->
    ?log_info("Going to change replication from ~p to have~n~p (~p, ~p)", [SrcNode, NewVBuckets, NewVBuckets--OldVBuckets, OldVBuckets--NewVBuckets]),
    OldChild = ns_vbm_new_sup:make_replicator(SrcNode, SrcNode, OldVBuckets),
    {ok, _} = ns_vbm_new_sup:local_change_vbucket_filter(Bucket, node(), OldChild, NewVBuckets).

childs_node_and_vbuckets(Child) ->
    {Node, _} = ns_vbm_new_sup:replicator_nodes(node(), Child),
    VBs = ns_vbm_new_sup:replicator_vbuckets(Child),
    {Node, VBs}.

child_to_supervisor_spec(Bucket, Child) ->
    {SrcNode, VBuckets} = childs_node_and_vbuckets(Child),
    Args = ebucketmigrator_srv:build_args(Bucket,
                                          SrcNode, node(), VBuckets, false),
    ns_vbm_new_sup:build_child_spec(Child, Args).


-spec get_children(bucket_name()) -> list() | not_running.
get_children(Bucket) ->
    try supervisor:which_children(ns_vbm_new_sup:server_name(Bucket)) of
        RawKids ->
            [Id || {Id, _Child, _Type, _Mods} <- RawKids]
    catch exit:{noproc, _} ->
            not_running
    end.
