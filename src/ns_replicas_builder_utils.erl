%% @author Couchbase, Inc <info@couchbase.com>
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
-module(ns_replicas_builder_utils).

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").

-export([tap_name/3, kill_tap_names/4, spawn_replica_builder/5]).

tap_name(VBucket, _SrcNode, DstNode) ->
    lists:flatten(io_lib:format("building_~p_~p", [VBucket, DstNode])).

kill_a_bunch_of_tap_names(Bucket, Node, TapNames) ->
    Config = ns_config:get(),
    User = ns_config:search_node_prop(Node, Config, memcached, admin_user),
    Pass = ns_config:search_node_prop(Node, Config, memcached, admin_pass),
    McdPair = {Host, Port} = ns_memcached:host_port(Node),
    {ok, Sock} = gen_tcp:connect(Host, Port, [binary,
                                              {packet, 0},
                                              {active, false},
                                              {nodelay, true},
                                              {delay_send, true}]),
    UserBin = mc_binary:bin(User),
    PassBin = mc_binary:bin(Pass),
    SenderPid = spawn_link(fun () ->
                                   ok = mc_binary:send(Sock, req, #mc_header{opcode = ?CMD_SASL_AUTH},
                                                       #mc_entry{key = <<"PLAIN">>,
                                                                 data = <<UserBin/binary, 0:8,
                                                                          UserBin/binary, 0:8,
                                                                          PassBin/binary>>}),
                                   ok = mc_binary:send(Sock, req, #mc_header{opcode = ?CMD_SELECT_BUCKET},
                                                       #mc_entry{key = iolist_to_binary(Bucket)}),
                                   [ok = mc_binary:send(Sock, req, #mc_header{opcode = ?CMD_DEREGISTER_TAP_CLIENT}, #mc_entry{key = TapName})
                                    || TapName <- TapNames]
                           end),
    try
        {ok, #mc_header{status = ?SUCCESS}, _} = mc_binary:recv(Sock, res, 50000), % CMD_SASL_AUTH
        {ok, #mc_header{status = ?SUCCESS}, _} = mc_binary:recv(Sock, res, 50000), % CMD_SELECT_BUCKET
        [{ok, #mc_header{status = ?SUCCESS}, _} = mc_binary:recv(Sock, res, 50000) || _TapName <- TapNames]
    after
        erlang:unlink(SenderPid),
        erlang:exit(SenderPid, kill),
        misc:wait_for_process(SenderPid, infinity)
    end,
    ?log_info("Killed the following tap names on ~p: ~p", [Node, TapNames]),
    ok = gen_tcp:close(Sock),
    [master_activity_events:note_deregister_tap_name(Bucket, McdPair, AName) || AName <- TapNames],
    receive
        {'EXIT', SenderPid, Reason} ->
            normal = Reason
    after 0 ->
            ok
    end,
    ok.

kill_tap_names(Bucket, VBucket, SrcNode, DstNodes) ->
    kill_a_bunch_of_tap_names(Bucket, SrcNode,
                              [iolist_to_binary([<<"replication_">>, tap_name(VBucket, SrcNode, DNode)]) || DNode <- DstNodes]).

spawn_replica_builder(Bucket, VBucket, SrcNode, DstNode, SetPendingState) ->
    Args = ebucketmigrator_srv:build_args(DstNode, Bucket, SrcNode, DstNode, [VBucket],
                                          false, SetPendingState),

    Args1 = ebucketmigrator_srv:add_args_option(Args, suffix, tap_name(VBucket, SrcNode, DstNode)),
    Args2 = ebucketmigrator_srv:add_args_option(Args1, note_tap_stats,
                                                {replica_building, Bucket, VBucket, SrcNode, DstNode}),

    case ebucketmigrator_srv:start_link(DstNode, Args2) of
        {ok, Pid} ->
            ?log_debug("Replica building ebucketmigrator for vbucket ~p into ~p is ~p", [VBucket, DstNode, Pid]),
            Pid;
        Error ->
            ?log_debug("Failed to spawn ebucketmigrator_srv for replica building: ~p",
                       [{VBucket, SrcNode, DstNode}]),
            spawn_link(fun () ->
                               exit({start_link_failed, VBucket, SrcNode, DstNode, Error})
                       end)
    end.
