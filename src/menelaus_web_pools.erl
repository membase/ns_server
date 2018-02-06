%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-2018 Couchbase, Inc.
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

%% @doc implementation of pools REST API's

-module(menelaus_web_pools).

-include("ns_common.hrl").
-include("ns_heart.hrl").

-export([handle_pools/1,
         check_and_handle_pool_info/2,
         handle_pool_info_streaming/2,
         handle_pool_settings_post/1]).

%% for hibernate
-export([handle_pool_info_wait_wake/4]).

-import(menelaus_util,
        [reply_json/2,
         reply_json/3,
         local_addr/1,
         encode_json/1,
         reply_ok/4,
         bin_concat_path/1,
         bin_concat_path/2,
         format_server_time/1,
         handle_streaming/2,
         validate_has_params/1,
         validate_any_value/2,
         validate_unsupported_params/1,
         validate_integer/2,
         get_values/1,
         return_value/3,
         return_error/3,
         execute_if_validated/3,
         reply/2]).

handle_pools(Req) ->
    %% TODO RBAC for the time being let's tell the UI that the user is admin
    %% later there will be an API to test the permissions

    RV1 = [{isAdminCreds, true},
           {isROAdminCreds, false},
           {isEnterprise, cluster_compat_mode:is_enterprise()},
           {isIPv6, misc:is_ipv6()}
           | get_content_for_provisioned_system()],
    RV = RV1 ++ menelaus_web_cache:versions_response(),
    reply_json(Req, {struct, RV}).

get_content_for_provisioned_system() ->
    {Pools, Settings, UUID} =
        case ns_config_auth:is_system_provisioned() of
            true ->
                UUID1 = menelaus_web:get_uuid(),
                Pools1 = [{struct,
                           [{name, <<"default">>},
                            {uri, <<"/pools/default?uuid=", UUID1/binary>>},
                            {streamingUri, <<"/poolsStreaming/default?uuid=", UUID1/binary>>}]}],
                Settings1 = {struct,
                             [{<<"maxParallelIndexers">>,
                               <<"/settings/maxParallelIndexers?uuid=", UUID1/binary>>},
                              {<<"viewUpdateDaemon">>,
                               <<"/settings/viewUpdateDaemon?uuid=", UUID1/binary>>}]},
                {Pools1, Settings1, UUID1};
            false ->
                {[], [], []}
        end,
    [{pools, Pools}, {settings, Settings}, {uuid, UUID}].

check_and_handle_pool_info(Id, Req) ->
    case ns_config_auth:is_system_provisioned() of
        true ->
            handle_pool_info(Id, Req);
        _ ->
            reply_json(Req, <<"unknown pool">>, 404)
    end.

handle_pool_info(Id, Req) ->
    LocalAddr = local_addr(Req),
    Query = Req:parse_qs(),
    WaitChangeS = proplists:get_value("waitChange", Query),
    PassedETag = proplists:get_value("etag", Query),
    case WaitChangeS of
        undefined ->
            reply_json(Req, build_pool_info(Id, Req, normal, unstable, LocalAddr));
        _ ->
            WaitChange = list_to_integer(WaitChangeS),
            menelaus_event:register_watcher(self()),
            erlang:send_after(WaitChange, self(), wait_expired),
            handle_pool_info_wait(Req, Id, LocalAddr, PassedETag)
    end.

handle_pool_info_wait(Req, Id, LocalAddr, PassedETag) ->
    Info = build_pool_info(Id, Req, for_ui, stable, LocalAddr),
    ETag = integer_to_list(erlang:phash2(Info)),
    if
        ETag =:= PassedETag ->
            erlang:hibernate(?MODULE, handle_pool_info_wait_wake,
                             [Req, Id, LocalAddr, PassedETag]);
        true ->
            handle_pool_info_wait_tail(Req, Id, LocalAddr, ETag)
    end.

handle_pool_info_wait_wake(Req, Id, LocalAddr, PassedETag) ->
    receive
        wait_expired ->
            handle_pool_info_wait_tail(Req, Id, LocalAddr, PassedETag);
        notify_watcher ->
            timer:sleep(200), %% delay a bit to catch more notifications
            consume_notifications(),
            handle_pool_info_wait(Req, Id, LocalAddr, PassedETag);
        _ ->
            exit(normal)
    end.

consume_notifications() ->
    receive
        notify_watcher -> consume_notifications()
    after 0 ->
            done
    end.

handle_pool_info_wait_tail(Req, Id, LocalAddr, ETag) ->
    menelaus_event:unregister_watcher(self()),
    %% consume all notifications
    consume_notifications(),
    %% and reply
    {struct, PList} = build_pool_info(Id, Req, for_ui, unstable, LocalAddr),
    Info = {struct, [{etag, list_to_binary(ETag)} | PList]},
    reply_ok(Req, "application/json", encode_json(Info),
             menelaus_auth:maybe_refresh_token(Req)),
    %% this will cause some extra latency on ui perhaps,
    %% because browsers commonly assume we'll keepalive, but
    %% keeping memory usage low is imho more important
    exit(normal).


build_pool_info(Id, Req, normal, Stability, LocalAddr) ->
    CanIncludeOtpCookie = menelaus_auth:has_permission({[admin, internal], all}, Req),

    %% NOTE: we limit our caching here for "normal" info
    %% level. Explicitly excluding UI (which InfoLevel = for_ui). This
    %% is because caching doesn't take into account "buckets version"
    %% which is important to deliver asap to UI (i.e. without any
    %% caching "staleness"). Same situation is with tasks version
    menelaus_web_cache:lookup_or_compute_with_expiration(
      {pool_details, CanIncludeOtpCookie, Stability, LocalAddr},
      fun () ->
              %% NOTE: token needs to be taken before building pool info
              Token = ns_config:config_version_token(),
              {do_build_pool_info(Id, CanIncludeOtpCookie,
                                  normal, Stability, LocalAddr), 1000, Token}
      end,
      fun (_Key, _Value, ConfigVersionToken) ->
              ConfigVersionToken =/= ns_config:config_version_token()
      end);
build_pool_info(Id, _Req, InfoLevel, Stability, LocalAddr) ->
    do_build_pool_info(Id, false, InfoLevel, Stability, LocalAddr).

do_build_pool_info(Id, CanIncludeOtpCookie, InfoLevel, Stability, LocalAddr) ->
    UUID = menelaus_web:get_uuid(),

    Nodes = menelaus_web_node:build_nodes_info(CanIncludeOtpCookie, InfoLevel, Stability, LocalAddr),
    Config = ns_config:get(),
    BucketsVer = erlang:phash2(ns_bucket:get_bucket_names(ns_bucket:get_buckets(Config)))
        bxor erlang:phash2([{proplists:get_value(hostname, KV),
                             proplists:get_value(status, KV)} || {struct, KV} <- Nodes]),
    BucketsInfo = {struct, [{uri, bin_concat_path(["pools", Id, "buckets"],
                                                  [{"v", BucketsVer},
                                                   {"uuid", UUID}])},
                            {terseBucketsBase, <<"/pools/default/b/">>},
                            {terseStreamingBucketsBase, <<"/pools/default/bs/">>}]},
    RebalanceStatus = case ns_orchestrator:is_rebalance_running() of
                          true -> <<"running">>;
                          _ -> <<"none">>
                      end,

    {Alerts0, AlertsSilenceToken} = menelaus_web_alerts_srv:fetch_alerts(),
    Alerts = build_alerts(Alerts0),

    Controllers = {struct, [
      {addNode, {struct, [{uri, <<"/controller/addNodeV2?uuid=", UUID/binary>>}]}},
      {rebalance, {struct, [{uri, <<"/controller/rebalance?uuid=", UUID/binary>>}]}},
      {failOver, {struct, [{uri, <<"/controller/failOver?uuid=", UUID/binary>>}]}},
      {startGracefulFailover, {struct, [{uri, <<"/controller/startGracefulFailover?uuid=", UUID/binary>>}]}},
      {reAddNode, {struct, [{uri, <<"/controller/reAddNode?uuid=", UUID/binary>>}]}},
      {reFailOver, {struct, [{uri, <<"/controller/reFailOver?uuid=", UUID/binary>>}]}},
      {ejectNode, {struct, [{uri, <<"/controller/ejectNode?uuid=", UUID/binary>>}]}},
      {setRecoveryType, {struct, [{uri, <<"/controller/setRecoveryType?uuid=", UUID/binary>>}]}},
      {setAutoCompaction, {struct, [
        {uri, <<"/controller/setAutoCompaction?uuid=", UUID/binary>>},
        {validateURI, <<"/controller/setAutoCompaction?just_validate=1">>}
      ]}},
      {clusterLogsCollection, {struct, [
        {startURI, <<"/controller/startLogsCollection?uuid=", UUID/binary>>},
        {cancelURI, <<"/controller/cancelLogsCollection?uuid=", UUID/binary>>}]}},
      {replication, {struct, [
        {createURI, <<"/controller/createReplication?uuid=", UUID/binary>>},
        {validateURI, <<"/controller/createReplication?just_validate=1">>}
      ]}}
    ]},

    TasksURI = bin_concat_path(["pools", Id, "tasks"],
                               [{"v", ns_doctor:get_tasks_version()}]),

    {ok, IndexesVersion0} = service_index:get_indexes_version(),
    IndexesVersion = list_to_binary(integer_to_list(IndexesVersion0)),

    GroupsV = erlang:phash2(ns_config:search(Config, server_groups)),

    Cca = ns_ssl_services_setup:client_cert_auth(),
    CcaState = list_to_binary(proplists:get_value(state, Cca)),
    PropList0 = [{name, list_to_binary(Id)},
                 {alerts, Alerts},
                 {alertsSilenceURL,
                  iolist_to_binary([<<"/controller/resetAlerts?token=">>,
                                    AlertsSilenceToken,
                                    $&, <<"uuid=">>, UUID])},
                 {nodes, Nodes},
                 {buckets, BucketsInfo},
                 {remoteClusters,
                  {struct, [{uri, <<"/pools/default/remoteClusters?uuid=", UUID/binary>>},
                            {validateURI, <<"/pools/default/remoteClusters?just_validate=1">>}]}},
                 {controllers, Controllers},
                 {rebalanceStatus, RebalanceStatus},
                 {rebalanceProgressUri, bin_concat_path(["pools", Id, "rebalanceProgress"])},
                 {stopRebalanceUri, <<"/controller/stopRebalance?uuid=", UUID/binary>>},
                 {nodeStatusesUri, <<"/nodeStatuses">>},
                 {maxBucketCount, ns_config:read_key_fast(max_bucket_count, 10)},
                 {autoCompactionSettings, menelaus_web_autocompaction:build_global_settings(Config)},
                 {tasks, {struct, [{uri, TasksURI}]}},
                 {counters, {struct, ns_cluster:counters()}},
                 {indexStatusURI, <<"/indexStatus?v=", IndexesVersion/binary>>},
                 {checkPermissionsURI,
                  bin_concat_path(["pools", Id, "checkPermissions"],
                                  [{"v", menelaus_web_rbac:check_permissions_url_version(Config)}])},
                 {serverGroupsUri, <<"/pools/default/serverGroups?v=",
                                     (list_to_binary(integer_to_list(GroupsV)))/binary>>},
                 {clusterName, list_to_binary(get_cluster_name())},
                 {balanced, ns_cluster_membership:is_balanced()},
                 {clientCertAuth, CcaState}],

    PropList1 = menelaus_web_node:build_memory_quota_info(Config) ++ PropList0,
    PropList2 =
        case InfoLevel of
            for_ui ->
                [{failoverWarnings, ns_bucket:failover_warnings()},
                 {goxdcrEnabled, cluster_compat_mode:is_goxdcr_enabled(Config)},
                 {ldapEnabled, cluster_compat_mode:is_ldap_enabled()},
                 {uiSessionTimeout, ns_config:read_key_fast(ui_session_timeout, undefined)}
                 | PropList1];
            _ ->
                PropList1
        end,

    PropList3 =
        case ns_audit_cfg:get_uid() of
            undefined ->
                PropList2;
            AuditUID ->
                [{audit_uid, list_to_binary(AuditUID)} | PropList2]
        end,

    PropList =
        case Stability of
            stable ->
                PropList3;
            unstable ->
                StorageTotals = [{Key, {struct, StoragePList}}
                                 || {Key, StoragePList} <-
                                        ns_storage_conf:cluster_storage_info()],
                [{storageTotals, {struct, StorageTotals}} | PropList3]
        end,

    {struct, PropList}.

build_alerts(Alerts) ->
    [build_one_alert(Alert) || Alert <- Alerts].

build_one_alert({_Key, Msg, Time}) ->
    LocalTime = calendar:now_to_local_time(misc:time_to_timestamp(Time)),
    StrTime = format_server_time(LocalTime),

    {struct, [{msg, Msg},
              {serverTime, StrTime}]}.

handle_pool_info_streaming(Id, Req) ->
    LocalAddr = local_addr(Req),
    F = fun(InfoLevel, Stability) ->
                build_pool_info(Id, Req, InfoLevel, Stability, LocalAddr)
        end,
    handle_streaming(F, Req).

get_cluster_name() ->
    get_cluster_name(ns_config:latest()).

get_cluster_name(Config) ->
    ns_config:search(Config, cluster_name, "").

validate_pool_settings_post(Config, CompatVersion, Args) ->
    R0 = validate_has_params({Args, [], []}),
    R1 = validate_any_value(clusterName, R0),
    R2 = validate_memory_quota(Config, CompatVersion, R1),
    validate_unsupported_params(R2).

validate_memory_quota(Config, CompatVersion, R0) ->
    QuotaFields =
        [{memory_quota:service_to_json_name(Service), Service} ||
            Service <- memory_quota:aware_services(CompatVersion)],
    ValidationResult =
        lists:foldl(
          fun ({Key, _}, Acc) ->
                  validate_integer(Key, Acc)
          end, R0, QuotaFields),
    Values = get_values(ValidationResult),

    Quotas = lists:filtermap(
               fun ({Key, Service}) ->
                       case lists:keyfind(Key, 1, Values) of
                           false ->
                               false;
                           {_, ServiceQuota} ->
                               {true, {Service, ServiceQuota}}
                       end
               end, QuotaFields),

    case Quotas of
        [] ->
            ValidationResult;
        _ ->
            do_validate_memory_quota(Config, Quotas, ValidationResult)
    end.

do_validate_memory_quota(Config, Quotas, R0) ->
    Nodes = ns_node_disco:nodes_wanted(Config),
    {ok, NodeStatuses} = ns_doctor:wait_statuses(Nodes, 3 * ?HEART_BEAT_PERIOD),
    NodeInfos =
        lists:map(
          fun (Node) ->
                  NodeStatus = dict:fetch(Node, NodeStatuses),
                  {_, MemoryData} = lists:keyfind(memory_data, 1, NodeStatus),
                  NodeServices = ns_cluster_membership:node_services(Config, Node),
                  {Node, NodeServices, MemoryData}
          end, Nodes),

    case memory_quota:check_quotas(NodeInfos, Config, Quotas) of
        ok ->
            return_value(quotas, Quotas, R0);
        {error, Error} ->
            {Key, Msg} = quota_error_msg(Error),
            return_error(Key, Msg, R0)
    end.

quota_error_msg({total_quota_too_high, Node, TotalQuota, MaxAllowed}) ->
    Msg = io_lib:format("Total quota (~bMB) exceeds the maximum allowed quota (~bMB) on node ~p",
                        [TotalQuota, MaxAllowed, Node]),
    {'_', Msg};
quota_error_msg({service_quota_too_low, Service, Quota, MinAllowed}) ->
    Details = case Service of
                  kv ->
                      " (current total buckets quota, or at least 256MB)";
                  _ ->
                      ""
              end,

    Msg = io_lib:format("The ~p service quota (~bMB) cannot be less than ~bMB~s.",
                        [Service, Quota, MinAllowed, Details]),
    {memory_quota:service_to_json_name(Service), Msg}.

handle_pool_settings_post(Req) ->
    do_handle_pool_settings_post_loop(Req, 10).

do_handle_pool_settings_post_loop(_, 0) ->
    erlang:error(exceeded_retries);
do_handle_pool_settings_post_loop(Req, RetriesLeft) ->
    try
        do_handle_pool_settings_post(Req)
    catch
        throw:retry_needed ->
            do_handle_pool_settings_post_loop(Req, RetriesLeft - 1)
    end.

do_handle_pool_settings_post(Req) ->
    Config = ns_config:get(),
    CompatVersion = cluster_compat_mode:get_compat_version(Config),

    execute_if_validated(
      fun (Values) ->
              do_handle_pool_settings_post_body(Req, Config, CompatVersion, Values)
      end, Req, validate_pool_settings_post(Config, CompatVersion, Req:parse_post())).

do_handle_pool_settings_post_body(Req, Config, CompatVersion, Values) ->
    case lists:keyfind(quotas, 1, Values) of
        {_, Quotas} ->
            case memory_quota:set_quotas(Config, Quotas) of
                ok ->
                    ok;
                retry_needed ->
                    throw(retry_needed)
            end;
        false ->
            ok
    end,

    case lists:keyfind(clusterName, 1, Values) of
        {_, ClusterName} ->
            ok = ns_config:set(cluster_name, ClusterName);
        false ->
            ok
    end,

    case cluster_compat_mode:is_version_40(CompatVersion) of
        true ->
            do_audit_cluster_settings(Req);
        false ->
            ok
    end,

    reply(Req, 200).

do_audit_cluster_settings(Req) ->
    %% this is obviously raceful, but since it's just audit...
    Quotas = lists:map(
               fun (Service) ->
                       {ok, Quota} = memory_quota:get_quota(Service),
                       {Service, Quota}
               end, memory_quota:aware_services(cluster_compat_mode:get_compat_version())),
    ClusterName = get_cluster_name(),
    ns_audit:cluster_settings(Req, Quotas, ClusterName).
