%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
%% @doc commands for audit logging
%%
-module(ns_audit).

-include("ns_common.hrl").

-export([login_success/1,
         login_failure/1,
         delete_user/3,
         password_change/3,
         add_node/7,
         remove_node/2,
         failover_node/3,
         enter_node_recovery/3,
         rebalance_initiated/4,
         create_bucket/4,
         modify_bucket/4,
         delete_bucket/2,
         flush_bucket/2,
         start_loading_sample/2,
         disk_storage_conf/4,
         rename_node/3,
         setup_node_services/3,
         change_memory_quota/2,
         add_group/2,
         delete_group/2,
         update_group/2,
         xdcr_create_cluster_ref/2,
         xdcr_update_cluster_ref/2,
         xdcr_delete_cluster_ref/2,
         xdcr_create_replication/3,
         xdcr_update_replication/3,
         xdcr_cancel_replication/2,
         xdcr_update_global_settings/2,
         enable_auto_failover/3,
         disable_auto_failover/1,
         reset_auto_failover_count/1,
         alerts/2,
         modify_compaction_settings/2,
         regenerate_certificate/1
        ]).

code(login_success) ->
    8192;
code(login_failure) ->
    8193;
code(delete_user) ->
    8194;
code(password_change) ->
    8195;
code(add_node) ->
    8196;
code(remove_node) ->
    8197;
code(failover_node) ->
    8198;
code(enter_node_recovery) ->
    8199;
code(rebalance_initiated) ->
    8200;
code(create_bucket) ->
    8201;
code(modify_bucket) ->
    8202;
code(delete_bucket) ->
    8203;
code(flush_bucket) ->
    8204;
code(start_loading_sample) ->
    8205;
code(disk_storage_conf) ->
    8206;
code(rename_node) ->
    8207;
code(setup_node_services) ->
    8208;
code(change_memory_quota) ->
    8209;
code(add_group) ->
    8210;
code(delete_group) ->
    8211;
code(update_group) ->
    8212;
code(xdcr_create_cluster_ref) ->
    8213;
code(xdcr_update_cluster_ref) ->
    8214;
code(xdcr_delete_cluster_ref) ->
    8215;
code(xdcr_create_replication) ->
    8216;
code(xdcr_update_replication) ->
    8217;
code(xdcr_cancel_replication) ->
    8218;
code(xdcr_update_global_settings) ->
    8219;
code(enable_auto_failover) ->
    8220;
code(disable_auto_failover) ->
    8221;
code(reset_auto_failover_count) ->
    8222;
code(enable_cluster_alerts) ->
    8223;
code(disable_cluster_alerts) ->
    8224;
code(modify_compaction_settings) ->
    8225;
code(regenerate_certificate) ->
    8226.

to_binary({list, List}) ->
    [to_binary(A) || A <- List];
to_binary(A) when is_list(A) ->
    iolist_to_binary(A);
to_binary(A) ->
    A.

now_to_iso8601(Now = {_, _, Microsecs}) ->
    {{YYYY, MM, DD}, {Hour, Min, Sec}} = LocalNow = calendar:now_to_local_time(Now),

    UTCSec = calendar:datetime_to_gregorian_seconds(calendar:now_to_universal_time(Now)),
    LocSec = calendar:datetime_to_gregorian_seconds(LocalNow),
    Offset =
        case (LocSec - UTCSec) div 60 of
            0 ->
                "Z";
            OffsetTotalMins ->
                OffsetHrs = OffsetTotalMins div 60,
                OffsetMin = abs(OffsetTotalMins rem 60),
                OffsetSign = case OffsetHrs < 0 of
                                 true ->
                                     "-";
                                 false ->
                                     "+"
                             end,
                io_lib:format("~s~2.2.0w:~2.2.0w", [OffsetSign, abs(OffsetHrs), OffsetMin])
        end,
    io_lib:format("~4.4.0w-~2.2.0w-~2.2.0wT~2.2.0w:~2.2.0w:~2.2.0w.~3.3.0w",
                  [YYYY, MM, DD, Hour, Min, Sec, Microsecs div 1000]) ++ Offset.

get_user_id(anonymous) ->
    anonymous;
get_user_id(undefined) ->
    anonymous;
get_user_id(User) ->
    {[{source, ns_server}, {user, to_binary(User)}]}.

get_remote(Req) ->
    Socket = Req:get(socket),
    {ok, {Host, Port}} = mochiweb_socket:peername(Socket),
    {[{ip, to_binary(inet_parse:ntoa(Host))},
      {port, Port}]}.

prepare_list(List) ->
    lists:foldl(
      fun ({_Key, undefined}, Acc) ->
              Acc;
          ({_Key, "undefined"}, Acc) ->
              Acc;
          ({Key, Value}, Acc) ->
              [{Key, to_binary(Value)} | Acc]
      end, [], List).

prepare(Req, Params) ->
    {User, Token, Remote} =
        case Req of
            undefined ->
                {anonymous, undefined, undefined};
            _ ->
                {get_user_id(menelaus_auth:get_user(Req)),
                 menelaus_auth:get_token(Req),
                 get_remote(Req)}
        end,
    Body = [{timestamp, now_to_iso8601(now())},
            {remote, Remote},
            {sessionid, Token},
            {real_userid, User}] ++ Params,

    prepare_list(Body).

put(Code, Req, Params) ->
    Body = prepare(Req, Params),

    ?log_debug("Audit ~p: ~p", [Code, Body]),
    EncodedBody = ejson:encode({Body}),

    ns_memcached_sockets_pool:executing_on_socket(
      fun (Sock) ->
              ok = mc_client_binary:audit_put(Sock, code(Code), EncodedBody)
      end).

login_success(Req) ->
    put(login_success, Req, [{role, menelaus_auth:get_role(Req)}]).

login_failure(Req) ->
    put(login_failure, Req, []).

delete_user(Req, User, Role) ->
    put(delete_user, Req, [{role, Role},
                           {userid, get_user_id(User)}]).

password_change(Req, User, Role) ->
    put(password_change, Req, [{role, Role},
                               {userid, get_user_id(User)}]).

add_node(Req, Hostname, Port, User, GroupUUID, Services, Node) ->
    put(add_node, Req, [{node, Node},
                        {groupUUID, GroupUUID},
                        {hostname, Hostname},
                        {port, Port},
                        {services, {list, Services}},
                        {user, get_user_id(User)}]).

remove_node(Req, Node) ->
    put(remove_node, Req, [{node, Node}]).

failover_node(Req, Node, Type) ->
    put(failover_node, Req, [{node, Node}, {type, Type}]).

enter_node_recovery(Req, Node, Type) ->
    put(enter_node_recovery, Req, [{node, Node}, {type, Type}]).

rebalance_initiated(Req, KnownNodes, EjectedNodes, DeltaRecoveryBuckets) ->
    Buckets = case DeltaRecoveryBuckets of
                  all ->
                      all;
                  _ ->
                      {list, DeltaRecoveryBuckets}
              end,
    put(rebalance_initiated, Req,
        [{known_nodes, {list, KnownNodes}},
         {ejected_nodes, {list, EjectedNodes}},
         {delta_recovery_buckets, Buckets}]).

build_bucket_props(Props) ->
    lists:foldl(
      fun({sasl_password, _}, Acc) ->
              Acc;
         ({autocompaction, false}, Acc) ->
              Acc;
         ({autocompaction, CProps}, Acc) ->
              [{autocompaction, {build_compaction_settings(CProps)}} | Acc];
         ({K, V}, Acc) ->
              [{K, to_binary(V)} | Acc]
      end, [], Props).

create_bucket(Req, Name, Type, Props) ->
    put(create_bucket, Req,
        [{name, Name},
         {type, Type},
         {props, {build_bucket_props(Props)}}]).

modify_bucket(Req, Name, Type, Props) ->
    put(modify_bucket, Req,
        [{name, Name},
         {type, Type},
         {props, {build_bucket_props(Props)}}]).

delete_bucket(Req, Name) ->
    put(delete_bucket, Req, [{name, Name}]).

flush_bucket(Req, Name) ->
    put(flush_bucket, Req, [{name, Name}]).

start_loading_sample(Req, Name) ->
    put(start_loading_sample, Req, [{name, Name}]).

disk_storage_conf(Req, Node, DbPath, IxPath) ->
    put(disk_storage_conf, Req, [{node, Node},
                                 {db_path, DbPath},
                                 {index_path, IxPath}]).

rename_node(Req, Node, Hostname) ->
    put(rename_node, Req, [{node, Node},
                           {hostname, Hostname}]).

setup_node_services(Req, Node, Services) ->
    put(setup_node_services, Req, [{node, Node},
                                   {services, {list, Services}}]).

change_memory_quota(Req, Quota) ->
    put(change_memory_quota, Req, [{quota, Quota}]).

add_group(Req, Group) ->
    put(add_group, Req, [{name, proplists:get_value(name, Group)},
                         {uuid, proplists:get_value(uuid, Group)}]).

delete_group(Req, Group) ->
    put(delete_group, Req, [{name, proplists:get_value(name, Group)},
                             {uuid, proplists:get_value(uuid, Group)}]).

update_group(Req, Group) ->
    put(update_group, Req, [{name, proplists:get_value(name, Group)},
                            {uuid, proplists:get_value(uuid, Group)},
                            {nodes, {list, proplists:get_value(nodes, Group, [])}}]).

build_xdcr_cluster_props(KV) ->
    [{name, misc:expect_prop_value(name, KV)},
     {demand_encryption, proplists:get_value(cert, KV) =/= undefined},
     {hostname, misc:expect_prop_value(hostname, KV)},
     {username, misc:expect_prop_value(username, KV)},
     {uuid, misc:expect_prop_value(uuid, KV)}].

xdcr_create_cluster_ref(Req, Props) ->
    put(xdcr_create_cluster_ref, Req, build_xdcr_cluster_props(Props)).

xdcr_update_cluster_ref(Req, Props) ->
    put(xdcr_update_cluster_ref, Req, build_xdcr_cluster_props(Props)).

xdcr_delete_cluster_ref(Req, Props) ->
    put(xdcr_delete_cluster_ref, Req, build_xdcr_cluster_props(Props)).

xdcr_create_replication(Req, Id, Props) ->
    {Params, Settings} =
        lists:splitwith(fun ({from_bucket, _}) ->
                                true;
                            ({to_bucket, _}) ->
                                true;
                            ({to_cluster, _}) ->
                                true;
                            (_) ->
                                false
                        end, Props),

    put(xdcr_create_replication, Req, [{id, Id},
                                       {settings, {prepare_list(Settings)}}] ++ Params).

xdcr_update_replication(Req, Id, Props) ->
    put(xdcr_update_replication, Req, [{id, Id},
                                       {settings, {prepare_list(Props)}}]).

xdcr_cancel_replication(Req, Id) ->
    put(xdcr_cancel_replication, Req, [{id, Id}]).

xdcr_update_global_settings(Req, Settings) ->
    put(xdcr_update_global_settings, Req, [{settings, {prepare_list(Settings)}}]).

enable_auto_failover(Req, Timeout, MaxNodes) ->
    put(enable_auto_failover, Req, [{timeout, Timeout},
                                    {max_nodes, MaxNodes}]).

disable_auto_failover(Req) ->
    put(disable_auto_failover, Req, []).

reset_auto_failover_count(Req) ->
    put(reset_auto_failover_count, Req, []).

alerts(Req, Settings) ->
    case misc:expect_prop_value(enabled, Settings) of
        false ->
            put(disable_cluster_alerts, Req, []);
        true ->
            EmailServer = misc:expect_prop_value(email_server, Settings),
            EmailServer1 = proplists:delete(pass, EmailServer),
            put(enable_cluster_alerts, Req,
                [{sender, misc:expect_prop_value(sender, Settings)},
                 {recipients, {list, misc:expect_prop_value(recipients, Settings)}},
                 {alerts, {list, misc:expect_prop_value(alerts, Settings)}},
                 {email_server, {prepare_list(EmailServer1)}}])
    end.

build_threshold({Percentage, Size}) ->
    {prepare_list([{percentage, Percentage}, {size, Size}])}.

build_compaction_settings(Settings) ->
    lists:foldl(
      fun ({allowed_time_period, V}, Acc) ->
              [{allowed_time_period, {prepare_list(V)}} | Acc];
          ({database_fragmentation_threshold, V}, Acc) ->
              [{database_fragmentation_threshold, build_threshold(V)} | Acc];
          ({view_fragmentation_threshold, V}, Acc) ->
              [{view_fragmentation_threshold, build_threshold(V)} | Acc];
          ({purge_interval, _} = T, Acc) ->
              [T | Acc];
          ({parallel_db_and_view_compaction, _} = T, Acc) ->
              [T | Acc];
          (_, Acc) ->
              Acc
      end, [], Settings).

modify_compaction_settings(Req, Settings) ->
    Data = build_compaction_settings(Settings),
    put(modify_compaction_settings, Req, Data).

regenerate_certificate(Req) ->
    put(regenerate_certificate, Req, []).
