%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% @doc Web server for menelaus.

-module(menelaus_web).

-author('NorthScale <info@northscale.com>').

% -behavior(ns_log_categorizing).
% the above is commented out because of the way the project is structured

-include_lib("eunit/include/eunit.hrl").

-include("menelaus_web.hrl").
-include("ns_common.hrl").
-include("ns_heart.hrl").
-include("ns_stats.hrl").
-include("rbac.hrl").

-export([start_link/0,
         start_link/1,
         stop/0,
         loop/2,
         webconfig/0,
         webconfig/1,
         restart/0,
         maybe_cleanup_old_buckets/0,
         assert_is_enterprise/0,
         assert_is_40/0,
         assert_is_45/0,
         assert_is_50/0,
         get_uuid/0]).

-export([ns_log_cat/1, ns_log_code_string/1, alert_key/1]).

-import(menelaus_util,
        [redirect_permanently/2,
         bin_concat_path/1,
         bin_concat_path/2,
         reply/2,
         reply/3,
         reply_text/3,
         reply_text/4,
         reply_ok/3,
         reply_ok/4,
         reply_json/2,
         reply_json/3,
         reply_json/4,
         reply_not_found/1,
         get_option/2,
         parse_validate_number/3,
         is_valid_positive_integer/1,
         is_valid_positive_integer_in_range/3,
         validate_boolean/2,
         validate_dir/2,
         validate_integer/2,
         validate_range/4,
         validate_range/5,
         validate_unsupported_params/1,
         validate_has_params/1,
         validate_any_value/2,
         validate_by_fun/3,
         handle_streaming/2,
         execute_if_validated/3]).

-define(PLUGGABLE_UI, "_p").

%% External API

start_link() ->
    start_link(webconfig()).

start_link(Options) ->
    {AppRoot, Options1} = get_option(approot, Options),
    Plugins = menelaus_pluggable_ui:find_plugins(),
    IsSSL = proplists:get_value(ssl, Options1, false),
    Loop = fun (Req) ->
                   ?MODULE:loop(Req, {AppRoot, IsSSL, Plugins})
           end,
    case mochiweb_http:start_link([{loop, Loop} | Options1]) of
        {ok, Pid} -> {ok, Pid};
        Other ->
            ?MENELAUS_WEB_LOG(?START_FAIL,
                              "Failed to start web service:  ~p~n", [Other]),
            Other
    end.

stop() ->
    % Note that a supervisor might restart us right away.
    mochiweb_http:stop(?MODULE).

restart() ->
    % Depend on our supervision tree to restart us right away.
    stop().

webconfig(Config) ->
    Ip = case os:getenv("MOCHIWEB_IP") of
             false -> misc:inaddr_any();
             Any -> Any
         end,
    Port = case os:getenv("MOCHIWEB_PORT") of
               false ->
                   misc:node_rest_port(Config, node());
               P -> list_to_integer(P)
           end,
    WebConfig = [{ip, Ip},
                 {name, ?MODULE},
                 {port, Port},
                 {nodelay, true},
                 {approot, menelaus_deps:local_path(["priv","public"],
                                                    ?MODULE)}],
    WebConfig.

webconfig() ->
    webconfig(ns_config:get()).

loop(Req, Config) ->
    ok = menelaus_sup:barrier_wait(),

    random:seed(os:timestamp()),

    try
        %% Using raw_path so encoded slash characters like %2F are handed correctly,
        %% in that we delay converting %2F's to slash characters until after we split by slashes.
        "/" ++ RawPath = Req:get(raw_path),
        {Path, _, _} = mochiweb_util:urlsplit_path(RawPath),
        PathTokens = lists:map(fun mochiweb_util:unquote/1, string:tokens(Path, "/")),

        case is_throttled_request(PathTokens) of
            false ->
                loop_inner(Req, Config, Path, PathTokens);
            true ->
                request_throttler:request(
                  rest,
                  fun () ->
                          loop_inner(Req, Config, Path, PathTokens)
                  end,
                  fun (_Error, Reason) ->
                          Retry = integer_to_list(random:uniform(10)),
                          reply_text(Req, Reason, 503, [{"Retry-After", Retry}])
                  end)
        end
    catch
        exit:normal ->
            %% this happens when the client closed the connection
            exit(normal);
        throw:{web_exception, StatusCode, Message, ExtraHeaders} ->
            reply_text(Req, Message, StatusCode, ExtraHeaders);
        Type:What ->
            Report = ["web request failed",
                      {path, Req:get(path)},
                      {method, Req:get(method)},
                      {type, Type}, {what, What},
                      {trace, erlang:get_stacktrace()}], % todo: find a way to enable this for field info gathering
            ?log_error("Server error during processing: ~p", [Report]),
            reply_json(Req, [list_to_binary("Unexpected server error, request logged.")], 500)
    end.

is_throttled_request(["internalSettings"]) ->
    false;
is_throttled_request(["diag" | _]) ->
    false;
is_throttled_request(["couchBase" | _]) ->      % this gets throttled as capi request
    false;
%% this gets throttled via capi too
is_throttled_request(["pools", _, "buckets", _BucketId, "docs"]) ->
    false;
is_throttled_request([?PLUGGABLE_UI | _]) ->
    %% Requests for pluggable UI is not throttled here.
    %% If necessary it is done in the service node.
    false;
is_throttled_request(_) ->
    true.

-type action() :: {done, term()} |
                  {local, fun()} |
                  {ui, boolean(), fun()} |
                  {ui, boolean(), fun(), [term()]} |
                  {rbac_permission() | no_check, fun()} |
                  {rbac_permission() | no_check, fun(), [term()]}.

-spec get_action(mochiweb_request(), {term(), boolean(), term()}, string(), [string()]) -> action().
get_action(Req, {AppRoot, IsSSL, Plugins}, Path, PathTokens) ->
    case Req:get(method) of
        Method when Method =:= 'GET'; Method =:= 'HEAD' ->
            case PathTokens of
                [] ->
                    {done, redirect_permanently("/ui/index.html", Req)};
                ["ui"] ->
                    {done, redirect_permanently("/ui/index.html", Req)};
                ["versions"] ->
                    {done, handle_versions(Req)};
                ["whoami"] ->
                    {no_check, fun menelaus_web_rbac:handle_whoami/1};
                ["pools"] ->
                    {{[pools], read}, fun menelaus_web_pools:handle_pools/1};
                ["pools", "default"] ->
                    {{[pools], read}, fun menelaus_web_pools:check_and_handle_pool_info/2, ["default"]};
                %% NOTE: see MB-10859. Our docs used to
                %% recommend doing this which due to old
                %% code's leniency worked just like
                %% /pools/default. So temporarily we allow
                %% /pools/nodes to be alias for
                %% /pools/default
                ["pools", "nodes"] ->
                    {{[pools], read}, fun menelaus_web_pools:check_and_handle_pool_info/2, ["default"]};
                ["pools", "default", "overviewStats"] ->
                    {{[{bucket, any}, stats], read}, fun menelaus_stats:handle_overview_stats/2, ["default"]};
                ["_uistats"] ->
                    {{[stats], read}, fun menelaus_stats:serve_ui_stats/1};
                ["_uiEnv"] ->
                    {done, serve_ui_env(Req)};
                ["poolsStreaming", "default"] ->
                    {{[pools], read}, fun menelaus_web_pools:handle_pool_info_streaming/2, ["default"]};
                ["pools", "default", "buckets"] ->
                    {{[{bucket, any}, settings], read}, fun menelaus_web_buckets:handle_bucket_list/1, []};
                ["pools", "default", "saslBucketsStreaming"] ->
                    {{[admin, buckets], read},
                     fun menelaus_web_buckets:handle_sasl_buckets_streaming/2,
                     ["default"]};
                ["pools", "default", "buckets", Id] ->
                    {{[{bucket, Id}, settings], read},
                     fun menelaus_web_buckets:handle_bucket_info/3,
                     ["default", Id]};
                ["pools", "default", "bucketsStreaming", Id] ->
                    {{[{bucket, Id}, settings], read},
                     fun menelaus_web_buckets:handle_bucket_info_streaming/3,
                     ["default", Id]};
                ["pools", "default", "buckets", Id, "ddocs"] ->
                    {{[{bucket, Id}, views], read},
                     fun menelaus_web_buckets:handle_ddocs_list/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "docs"] ->
                    {{[{bucket, Id}, data, docs], read},
                     fun menelaus_web_crud:handle_list/2, [Id]};
                ["pools", "default", "buckets", Id, "docs", DocId] ->
                    {{[{bucket, Id}, data, docs], read},
                     fun menelaus_web_crud:handle_get/3, [Id, DocId]};
                ["pools", "default", "buckets", "@query", "stats"] ->
                    {{[stats], read},
                     fun menelaus_stats:handle_stats_section/3, ["default", "@query"]};
                ["pools", "default", "buckets", "@xdcr-" ++ _ = Id, "stats"] ->
                    {{[stats], read},
                     fun menelaus_stats:handle_stats_section/3, ["default", Id]};
                ["pools", "default", "buckets", "@index-" ++ _ = Id, "stats"] ->
                    {{[stats], read},
                     fun menelaus_stats:handle_stats_section/3, ["default", Id]};
                ["pools", "default", "buckets", "@fts-" ++ _ = Id, "stats"] ->
                    {{[stats], read},
                     fun menelaus_stats:handle_stats_section/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "stats"] ->
                    {{[{bucket, Id}, stats], read},
                     fun menelaus_stats:handle_bucket_stats/3,
                     ["default", Id]};
                ["pools", "default", "buckets", Id, "localRandomKey"] ->
                    {{[{bucket, Id}, data, docs], read},
                     fun menelaus_web_buckets:handle_local_random_key/3,
                     ["default", Id]};
                ["pools", "default", "buckets", Id, "statsDirectory"] ->
                    {{[{bucket, Id}, stats], read}, fun menelaus_stats:serve_stats_directory/3,
                     ["default", Id]};
                ["pools", "default", "nodeServices"] ->
                    {{[pools], read}, fun menelaus_web_cluster:serve_node_services/1, []};
                ["pools", "default", "nodeServicesStreaming"] ->
                    {{[pools], read}, fun menelaus_web_cluster:serve_node_services_streaming/1, []};
                ["pools", "default", "b", BucketName] ->
                    {{[{bucket, BucketName}, settings], read},
                     fun serve_short_bucket_info/3,
                     ["default", BucketName]};
                ["pools", "default", "bs", BucketName] ->
                    {{[{bucket, BucketName}, settings], read},
                     fun serve_streaming_short_bucket_info/3,
                     ["default", BucketName]};
                ["pools", "default", "buckets", Id, "nodes"] ->
                    {{[{bucket, Id}, settings], read},
                     fun menelaus_web_node:handle_bucket_node_list/2, [Id]};
                ["pools", "default", "buckets", Id, "nodes", NodeId] ->
                    {{[{bucket, Id}, settings], read},
                     fun menelaus_web_node:handle_bucket_node_info/3, [Id, NodeId]};
                ["pools", "default", "buckets", "@query", "nodes", NodeId, "stats"] ->
                    {{[stats], read}, fun menelaus_stats:handle_stats_section_for_node/4,
                     ["default", "@query", NodeId]};
                ["pools", "default", "buckets", "@xdcr-" ++ _ = Id, "nodes", NodeId, "stats"] ->
                    {{[stats], read}, fun menelaus_stats:handle_stats_section_for_node/4,
                     ["default", Id, NodeId]};
                ["pools", "default", "buckets", "@index-" ++ _ = Id, "nodes", NodeId, "stats"] ->
                    {{[stats], read}, fun menelaus_stats:handle_stats_section_for_node/4,
                     ["default", Id, NodeId]};
                ["pools", "default", "buckets", "@fts-" ++ _ = Id, "nodes", NodeId, "stats"] ->
                    {{[stats], read}, fun menelaus_stats:handle_stats_section_for_node/4,
                     ["default", Id, NodeId]};
                ["pools", "default", "buckets", Id, "nodes", NodeId, "stats"] ->
                    {{[{bucket, Id}, stats], read},
                     fun menelaus_stats:handle_bucket_node_stats/4,
                     ["default", Id, NodeId]};
                ["pools", "default", "buckets", Id, "stats", StatName] ->
                    {{[{bucket, Id}, stats], read},
                     fun menelaus_stats:handle_specific_stat_for_buckets/4,
                     ["default", Id, StatName]};
                ["pools", "default", "buckets", Id, "recoveryStatus"] ->
                    {{[{bucket, Id}, recovery], read},
                     fun menelaus_web_recovery:handle_recovery_status/3,
                     ["default", Id]};
                ["pools", "default", "remoteClusters"] ->
                    goxdcr_rest:spec(
                      {[xdcr, remote_clusters], read},
                      fun menelaus_web_remote_clusters:handle_remote_clusters/1);
                ["pools", "default", "serverGroups"] ->
                    {{[server_groups], read},
                     fun menelaus_web_groups:handle_server_groups/1};
                ["pools", "default", "certificate"] ->
                    {done, menelaus_web_cert:handle_cluster_certificate(Req)};
                ["pools", "default", "certificate", "node", Node] ->
                    {{[admin, security], read},
                     fun menelaus_web_cert:handle_get_node_certificate/2, [Node]};
                ["pools", "default", "settings", "memcached", "global"] ->
                    {{[admin, memcached], read}, fun menelaus_web_mcd_settings:handle_global_get/1};
                ["pools", "default", "settings", "memcached", "effective", Node] ->
                    {{[admin, memcached], read}, fun menelaus_web_mcd_settings:handle_effective_get/2, [Node]};
                ["pools", "default", "settings", "memcached", "node", Node] ->
                    {{[admin, memcached], read}, fun menelaus_web_mcd_settings:handle_node_get/2, [Node]};
                ["pools", "default", "settings", "memcached", "node", Node, "setting", Name] ->
                    {{[admin, memcached], read}, fun menelaus_web_mcd_settings:handle_node_setting_get/3, [Node, Name]};
                ["nodeStatuses"] ->
                    {{[nodes], read}, fun menelaus_web_node:handle_node_statuses/1};
                ["logs"] ->
                    {{[logs], read}, fun menelaus_alert:handle_logs/1};
                ["settings", "web"] ->
                    {{[settings], read}, fun handle_settings_web/1};
                ["settings", "alerts"] ->
                    {{[settings], read}, fun handle_settings_alerts/1};
                ["settings", "stats"] ->
                    {{[settings], read}, fun handle_settings_stats/1};
                ["settings", "autoFailover"] ->
                    {{[settings], read}, fun menelaus_web_auto_failover:handle_settings_get/1};
                ["settings", "autoReprovision"] ->
                    {{[settings], read}, fun handle_settings_auto_reprovision/1};
                ["settings", "maxParallelIndexers"] ->
                    {{[indexes], read}, fun handle_settings_max_parallel_indexers/1};
                ["settings", "viewUpdateDaemon"] ->
                    {{[indexes], read}, fun handle_settings_view_update_daemon/1};
                ["settings", "autoCompaction"] ->
                    {{[settings], read},
                     fun menelaus_web_autocompaction:handle_get_global_settings/1};
                ["settings", "readOnlyAdminName"] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_settings_read_only_admin_name/1};
                ["settings", "replications"] ->
                    goxdcr_rest:spec(
                      {[xdcr, settings], read},
                      fun menelaus_web_xdc_replications:handle_global_replication_settings/1);
                ["settings", "replications", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], read},
                      fun menelaus_web_xdc_replications:handle_replication_settings/2, [XID]);
                ["settings", "saslauthdAuth"] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_saslauthd_auth_settings/1};
                ["settings", "clientCertAuth"] ->
                    {{[admin, security], read},
                     fun menelaus_web_cert:handle_client_cert_auth_settings/1};
                ["settings", "audit"] ->
                    {{[admin, security], read},
                     fun handle_settings_audit/1};
                ["settings", "rbac", "roles"] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_get_roles/1};
                ["settings", "rbac", "users"] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_get_users/2, [Path]};
                ["settings", "rbac", "users", Domain] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_get_users/3, [Path, Domain]};
                ["settings", "rbac", "users", Domain, UserId] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_get_user/3, [Domain, UserId]};
                ["settings", "passwordPolicy"] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_get_password_policy/1};
                ["settings", "security"] ->
                    {{[admin, security], read},
                     fun menelaus_web_settings:handle_get/2, [security]};
                ["internalSettings"] ->
                    {{[admin, settings], read},
                     fun menelaus_web_settings:handle_get/2, [internal]};
                ["nodes", NodeId] ->
                    {{[nodes], read}, fun menelaus_web_node:handle_node/2, [NodeId]};
                ["nodes", "self", "xdcrSSLPorts"] ->
                    {done, menelaus_web_node:handle_node_self_xdcr_ssl_ports(Req)};
                ["indexStatus"] ->
                    {{[indexes], read}, fun menelaus_web_indexes:handle_index_status/1};
                ["settings", "indexes"] ->
                    {{[indexes], read}, fun menelaus_web_indexes:handle_settings_get/1};
                ["diag"] ->
                    {{[admin, diag], read}, fun diag_handler:handle_diag/1, []};
                ["diag", "vbuckets"] ->
                    {{[admin, diag], read}, fun diag_handler:handle_diag_vbuckets/1};
                ["diag", "ale"] ->
                    {{[admin, diag], read}, fun diag_handler:handle_diag_ale/1};
                ["diag", "masterEvents"] ->
                    {{[admin, diag], read}, fun diag_handler:handle_diag_master_events/1};
                ["diag", "password"] ->
                    {local, fun diag_handler:handle_diag_get_password/1};
                ["pools", "default", "rebalanceProgress"] ->
                    {{[tasks], read}, fun menelaus_web_cluster:handle_rebalance_progress/2, ["default"]};
                ["pools", "default", "tasks"] ->
                    {{[tasks], read}, fun handle_tasks/2, ["default"]};
                ["index.html"] ->
                    {done, redirect_permanently("/ui/index.html", Req)};
                ["ui", "index.html"] ->
                    {ui, IsSSL, fun handle_ui_root/5, [AppRoot, Path, ?VERSION_50,
                                                       Plugins]};
                ["ui", "classic-index.html"] ->
                    {ui, IsSSL, fun handle_ui_root/5, [AppRoot, Path, ?VERSION_45,
                                                       Plugins]};
                ["dot", Bucket] ->
                    {{[{bucket, Bucket}, settings], read}, fun handle_dot/2, [Bucket]};
                ["dotsvg", Bucket] ->
                    {{[{bucket, Bucket}, settings], read}, fun handle_dotsvg/2, [Bucket]};
                ["sasl_logs"] ->
                    {{[admin, logs], read}, fun diag_handler:handle_sasl_logs/1, []};
                ["sasl_logs", LogName] ->
                    {{[admin, logs], read}, fun diag_handler:handle_sasl_logs/2, [LogName]};
                ["images" | _] ->
                    {ui, IsSSL, fun handle_serve_file/4, [AppRoot, Path, 30000000]};
                ["couchBase" | _] -> {no_check,
                                      fun menelaus_pluggable_ui:proxy_req/4,
                                      ["couchBase",
                                       drop_prefix(Req:get(raw_path)),
                                       Plugins]};
                ["sampleBuckets"] -> {{[samples], read}, fun menelaus_web_samples:handle_get/1};
                ["_metakv" | _] ->
                    {{[admin, internal], all}, fun menelaus_metakv:handle_get/2, [Path]};
                ["_goxdcr", "controller", "bucketSettings", _Bucket] ->
                    XdcrPath = drop_prefix(Req:get(raw_path)),
                    {{[admin, internal], all},
                     fun goxdcr_rest:get_controller_bucket_settings/2, [XdcrPath]};
                ["_cbauth", "checkPermission"] ->
                    {{[admin, internal], all},
                     fun menelaus_web_rbac:handle_check_permission_for_cbauth/1};
                [?PLUGGABLE_UI, "ui", RestPrefix | _] ->
                    {ui, IsSSL, fun menelaus_pluggable_ui:maybe_serve_file/4,
                        [RestPrefix, Plugins, nth_path_tail(Path, 3)]};
                [?PLUGGABLE_UI, RestPrefix | _] ->
                    {no_check,
                     fun (PReq) ->
                             menelaus_pluggable_ui:proxy_req(
                               RestPrefix,
                               drop_rest_prefix(Req:get(raw_path)),
                               Plugins, PReq)
                     end};
                _ ->
                    {ui, IsSSL, fun handle_serve_file/4, [AppRoot, Path, 10]}
            end;
        'POST' ->
            case PathTokens of
                ["uilogin"] ->
                    {ui, IsSSL, fun handle_uilogin/1};
                ["uilogout"] ->
                    {done, handle_uilogout(Req)};
                ["sampleBuckets", "install"] ->
                    {{[buckets], create}, fun menelaus_web_samples:handle_post/1};
                ["engageCluster2"] ->
                    {{[admin, setup], write}, fun menelaus_web_cluster:handle_engage_cluster2/1};
                ["completeJoin"] ->
                    {{[admin, setup], write}, fun menelaus_web_cluster:handle_complete_join/1};
                ["node", "controller", "doJoinCluster"] ->
                    {{[admin, setup], write}, fun menelaus_web_cluster:handle_join/1};
                ["node", "controller", "doJoinClusterV2"] ->
                    {{[admin, setup], write}, fun menelaus_web_cluster:handle_join/1};
                ["node", "controller", "rename"] ->
                    {{[admin, setup], write}, fun menelaus_web_node:handle_node_rename/1};
                ["nodes", NodeId, "controller", "settings"] ->
                    {{[admin, setup], write}, fun menelaus_web_node:handle_node_settings_post/2,
                     [NodeId]};
                ["node", "controller", "setupServices"] ->
                    {{[admin, setup], write}, fun menelaus_web_cluster:handle_setup_services_post/1};
                ["node", "controller", "reloadCertificate"] ->
                    {{[admin, setup], write},
                     fun menelaus_web_cert:handle_reload_node_certificate/1};
                ["node", "controller", "changeMasterPassword"] ->
                    {{[admin, security], write},
                     fun menelaus_web_secrets:handle_change_master_password/1};
                ["node", "controller", "rotateDataKey"] ->
                    {{[admin, security], write},
                     fun menelaus_web_secrets:handle_rotate_data_key/1};
                ["settings", "web"] ->
                    {{[admin, setup], write}, fun handle_settings_web_post/1};
                ["settings", "alerts"] ->
                    {{[settings], write}, fun handle_settings_alerts_post/1};
                ["settings", "alerts", "testEmail"] ->
                    {{[settings], write}, fun handle_settings_alerts_send_test_email/1};
                ["settings", "stats"] ->
                    {{[settings], write}, fun handle_settings_stats_post/1};
                ["settings", "autoFailover"] ->
                    {{[settings], write}, fun menelaus_web_auto_failover:handle_settings_post/1};
                ["settings", "autoFailover", "resetCount"] ->
                    {{[settings], write}, fun menelaus_web_auto_failover:handle_settings_reset_count/1};
                ["settings", "autoReprovision"] ->
                    {{[settings], write}, fun handle_settings_auto_reprovision_post/1};
                ["settings", "autoReprovision", "resetCount"] ->
                    {{[settings], write}, fun handle_settings_auto_reprovision_reset_count/1};
                ["settings", "maxParallelIndexers"] ->
                    {{[indexes], write}, fun handle_settings_max_parallel_indexers_post/1};
                ["settings", "viewUpdateDaemon"] ->
                    {{[indexes], write}, fun handle_settings_view_update_daemon_post/1};
                ["settings", "readOnlyUser"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_settings_read_only_user_post/1};
                ["settings", "replications"] ->
                    goxdcr_rest:spec(
                      {[xdcr, settings], write},
                      fun menelaus_web_xdc_replications:handle_global_replication_settings_post/1);
                ["settings", "replications", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], [write, execute]},
                      fun menelaus_web_xdc_replications:handle_replication_settings_post/2, [XID]);
                ["settings", "saslauthdAuth"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_saslauthd_auth_settings_post/1};
                ["settings", "clientCertAuth"] ->
                    {{[admin, security], write},
                     fun menelaus_web_cert:handle_client_cert_auth_settings_post/1};
                ["settings", "audit"] ->
                    {{[admin, security], write},
                     fun handle_settings_audit_post/1};
                ["settings", "passwordPolicy"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_post_password_policy/1};
                ["settings", "security"] ->
                    {{[admin, security], write},
                     fun menelaus_web_settings:handle_post/2, [security]};
                ["validateCredentials"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_validate_saslauthd_creds_post/1};
                ["internalSettings"] ->
                    {{[admin, settings], write},
                     fun menelaus_web_settings:handle_post/2, [internal]};
                ["pools", "default"] ->
                    {{[pools], write}, fun menelaus_web_pools:handle_pool_settings_post/1};
                ["controller", "ejectNode"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_eject_post/1};
                ["controller", "addNode"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_add_node/1};
                ["controller", "addNodeV2"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_add_node/1};
                ["pools", "default", "serverGroups", UUID, "addNode"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_add_node_to_group/2, [UUID]};
                ["pools", "default", "serverGroups", UUID, "addNodeV2"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_add_node_to_group/2, [UUID]};
                ["controller", "failOver"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_failover/1};
                ["controller", "startGracefulFailover"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_start_graceful_failover/1};
                ["controller", "rebalance"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_rebalance/1};
                ["controller", "reAddNode"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_re_add_node/1};
                ["controller", "reFailOver"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_re_failover/1};
                ["controller", "stopRebalance"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_stop_rebalance/1};
                ["controller", "setRecoveryType"] ->
                    {{[pools], write}, fun menelaus_web_cluster:handle_set_recovery_type/1};
                ["controller", "setAutoCompaction"] ->
                    {{[settings], write},
                     fun menelaus_web_autocompaction:handle_set_global_settings/1};
                ["controller", "createReplication"] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_create_replication/1);
                ["controller", "cancelXDCR", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_cancel_replication/2, [XID]);
                ["controller", "cancelXCDR", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_cancel_replication/2, [XID],
                      menelaus_util:concat_url_path(["controller", "cancelXDCR", XID]));
                ["controller", "resetAlerts"] ->
                    {{[settings], write}, fun handle_reset_alerts/1};
                ["controller", "regenerateCertificate"] ->
                    {{[admin, security], write},
                     fun menelaus_web_cert:handle_regenerate_certificate/1};
                ["controller", "uploadClusterCA"] ->
                    {{[admin, security], write},
                     fun menelaus_web_cert:handle_upload_cluster_ca/1};
                ["controller", "startLogsCollection"] ->
                    {{[admin, logs], read},
                     fun menelaus_web_cluster_logs:handle_start_collect_logs/1};
                ["controller", "cancelLogsCollection"] ->
                    {{[admin, logs], read},
                     fun menelaus_web_cluster_logs:handle_cancel_collect_logs/1};
                ["controller", "resetAdminPassword"] ->
                    {local, fun menelaus_web_rbac:handle_reset_admin_password/1};
                ["controller", "changePassword"] ->
                    {no_check, fun menelaus_web_rbac:handle_change_password/1};
                ["pools", "default", "buckets", Id] ->
                    {{[{bucket, Id}, settings], write},
                     fun menelaus_web_buckets:handle_bucket_update/3,
                     ["default", Id]};
                ["pools", "default", "buckets"] ->
                    {{[buckets], create},
                     fun menelaus_web_buckets:handle_bucket_create/2,
                     ["default"]};
                ["pools", "default", "buckets", Id, "docs", DocId] ->
                    {{[{bucket, Id}, data, docs], upsert},
                     fun menelaus_web_crud:handle_post/3, [Id, DocId]};
                ["pools", "default", "buckets", Id, "controller", "doFlush"] ->
                    {{[{bucket, Id}], flush},
                     fun menelaus_web_buckets:handle_bucket_flush/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "compactBucket"] ->
                    {{[{bucket, Id}], compact},
                     fun menelaus_web_buckets:handle_compact_bucket/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "unsafePurgeBucket"] ->
                    {{[{bucket, Id}], delete},
                     fun menelaus_web_buckets:handle_purge_compact_bucket/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "cancelBucketCompaction"] ->
                    {{[{bucket, Id}], compact},
                     fun menelaus_web_buckets:handle_cancel_bucket_compaction/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "compactDatabases"] ->
                    {{[{bucket, Id}], compact},
                     fun menelaus_web_buckets:handle_compact_databases/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "cancelDatabasesCompaction"] ->
                    {{[{bucket, Id}], compact},
                     fun menelaus_web_buckets:handle_cancel_databases_compaction/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "startRecovery"] ->
                    {{[{bucket, Id}, recovery], write},
                     fun menelaus_web_recovery:handle_start_recovery/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "stopRecovery"] ->
                    {{[{bucket, Id}, recovery], write},
                     fun menelaus_web_recovery:handle_stop_recovery/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "commitVBucket"] ->
                    {{[{bucket, Id}, recovery], write},
                     fun menelaus_web_recovery:handle_commit_vbucket/3, ["default", Id]};
                ["pools", "default", "buckets", Id,
                 "ddocs", DDocId, "controller", "compactView"] ->
                    {{[{bucket, Id}, views], compact},
                     fun menelaus_web_buckets:handle_compact_view/4, ["default", Id, DDocId]};
                ["pools", "default", "buckets", Id,
                 "ddocs", DDocId, "controller", "cancelViewCompaction"] ->
                    {{[{bucket, Id}, views], compact},
                     fun menelaus_web_buckets:handle_cancel_view_compaction/4,
                     ["default", Id, DDocId]};
                ["pools", "default", "buckets", Id,
                 "ddocs", DDocId, "controller", "setUpdateMinChanges"] ->
                    {{[{bucket, Id}, views], compact},
                     fun menelaus_web_buckets:handle_set_ddoc_update_min_changes/4,
                     ["default", Id, DDocId]};
                ["pools", "default", "remoteClusters"] ->
                    goxdcr_rest:spec(
                      {[xdcr, remote_clusters], write},
                      fun menelaus_web_remote_clusters:handle_remote_clusters_post/1);
                ["pools", "default", "remoteClusters", Id] ->
                    goxdcr_rest:spec(
                      {[xdcr, remote_clusters], write},
                      fun menelaus_web_remote_clusters:handle_remote_cluster_update/2, [Id]);
                ["pools", "default", "serverGroups"] ->
                    {{[server_groups], write},
                     fun menelaus_web_groups:handle_server_groups_post/1};
                ["pools", "default", "settings", "memcached", "global"] ->
                    {{[admin, memcached], write},
                     fun menelaus_web_mcd_settings:handle_global_post/1};
                ["pools", "default", "settings", "memcached", "node", Node] ->
                    {{[admin, memcached], write},
                     fun menelaus_web_mcd_settings:handle_node_post/2, [Node]};
                ["pools", "default", "checkPermissions"] ->
                    {no_check,
                     fun menelaus_web_rbac:handle_check_permissions_post/1};
                ["settings", "indexes"] ->
                    {{[indexes], write}, fun menelaus_web_indexes:handle_settings_post/1};
                ["_cbauth"] ->
                    {no_check, fun menelaus_cbauth:handle_cbauth_post/1};
                ["_log"] ->
                    {{[admin, internal], all}, fun handle_log_post/1};
                ["_goxdcr", "regexpValidation"] ->
                    goxdcr_rest:spec(
                      no_check,
                      fun menelaus_util:reply_not_found/1, [],
                      menelaus_util:concat_url_path(["controller", "regexpValidation"]));
                ["_goxdcr", "controller", "bucketSettings", _Bucket] ->
                    XdcrPath = drop_prefix(Req:get(raw_path)),
                    {{[admin, internal], all},
                     fun goxdcr_rest:post_controller_bucket_settings/2, [XdcrPath]};
                ["logClientError"] -> {no_check,
                                       fun (R) ->
                                               User = menelaus_auth:extract_auth_user(R),
                                               ?MENELAUS_WEB_LOG(?UI_SIDE_ERROR_REPORT,
                                                                 "Client-side error-report for user ~p on node ~p:~nUser-Agent:~s~n~s~n",
                                                                 [User, node(),
                                                                  Req:get_header_value("user-agent"), binary_to_list(R:recv_body())]),
                                               reply_ok(R, "text/plain", [])
                                       end};
                ["diag", "eval"] ->
                    {{[admin, diag], write}, fun diag_handler:handle_diag_eval/1};
                ["couchBase" | _] ->
                    {no_check, fun menelaus_pluggable_ui:proxy_req/4,
                     ["couchBase",
                      drop_prefix(Req:get(raw_path)),
                      Plugins]};
                [?PLUGGABLE_UI, RestPrefix | _] ->
                    {no_check,
                     fun (PReq) ->
                             menelaus_pluggable_ui:proxy_req(
                               RestPrefix,
                               drop_rest_prefix(Req:get(raw_path)),
                               Plugins, PReq)
                     end};
                _ ->
                    ?MENELAUS_WEB_LOG(0001, "Invalid post received: ~p", [Req]),
                    {done, reply_not_found(Req)}
            end;
        'DELETE' ->
            case PathTokens of
                ["pools", "default", "buckets", Id] ->
                    {{[{bucket, Id}], delete},
                     fun menelaus_web_buckets:handle_bucket_delete/3, ["default", Id]};
                ["pools", "default", "remoteClusters", Id] ->
                    goxdcr_rest:spec(
                      {[xdcr, remote_clusters], write},
                      fun menelaus_web_remote_clusters:handle_remote_cluster_delete/2, [Id]);
                ["pools", "default", "buckets", Id, "docs", DocId] ->
                    {{[{bucket, Id}, data, docs], delete},
                     fun menelaus_web_crud:handle_delete/3, [Id, DocId]};
                ["controller", "cancelXCDR", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_cancel_replication/2, [XID],
                      menelaus_util:concat_url_path(["controller", "cancelXDCR", XID]));
                ["controller", "cancelXDCR", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_cancel_replication/2, [XID]);
                ["settings", "readOnlyUser"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_read_only_user_delete/1};
                ["pools", "default", "serverGroups", GroupUUID] ->
                    {{[server_groups], write},
                     fun menelaus_web_groups:handle_server_group_delete/2, [GroupUUID]};
                ["pools", "default", "settings", "memcached", "node", Node, "setting", Name] ->
                    {{[admin, memcached], write},
                     fun menelaus_web_mcd_settings:handle_node_setting_delete/3, [Node, Name]};
                ["settings", "rbac", "users", UserId] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_delete_user/3, ["external", UserId]};
                ["settings", "rbac", "users", Domain, UserId] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_delete_user/3, [Domain, UserId]};
                ["couchBase" | _] -> {no_check,
                                      fun menelaus_pluggable_ui:proxy_req/4,
                                      ["couchBase",
                                       drop_prefix(Req:get(raw_path)),
                                       Plugins]};
                ["_metakv" | _] ->
                    {{[admin, internal], all}, fun menelaus_metakv:handle_delete/2, [Path]};
                [?PLUGGABLE_UI, RestPrefix | _] ->
                    {no_check,
                     fun (PReq) ->
                             menelaus_pluggable_ui:proxy_req(
                               RestPrefix,
                               drop_rest_prefix(Req:get(raw_path)),
                               Plugins, PReq)
                     end};
                _ ->
                    ?MENELAUS_WEB_LOG(0002, "Invalid delete received: ~p as ~p",
                                      [Req, PathTokens]),
                    {done, reply_text(Req, "Method Not Allowed", 405)}
            end;
        'PUT' = Method ->
            case PathTokens of
                ["settings", "readOnlyUser"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_read_only_user_reset/1};
                ["pools", "default", "serverGroups"] ->
                    {{[server_groups], write},
                     fun menelaus_web_groups:handle_server_groups_put/1};
                ["pools", "default", "serverGroups", GroupUUID] ->
                    {{[server_groups], write},
                     fun menelaus_web_groups:handle_server_group_update/2, [GroupUUID]};
                ["settings", "rbac", "users", UserId] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_put_user/3, ["external", UserId]};
                ["settings", "rbac", "users", Domain, UserId] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_put_user/3, [Domain, UserId]};
                ["couchBase" | _] ->
                    {no_check, fun menelaus_pluggable_ui:proxy_req/4,
                     ["couchBase",
                      drop_prefix(Req:get(raw_path)),
                      Plugins]};
                ["_metakv" | _] ->
                    {{[admin, internal], all}, fun menelaus_metakv:handle_put/2, [Path]};
                [?PLUGGABLE_UI, RestPrefix | _] ->
                    {no_check,
                     fun (PReq) ->
                             menelaus_pluggable_ui:proxy_req(
                               RestPrefix,
                               drop_rest_prefix(Req:get(raw_path)),
                               Plugins, PReq)
                     end};
                _ ->
                    ?MENELAUS_WEB_LOG(0003, "Invalid ~p received: ~p", [Method, Req]),
                    {done, reply_text(Req, "Method Not Allowed", 405)}
            end;
        "RPCCONNECT" ->
            {{[admin, internal], all}, fun json_rpc_connection_sup:handle_rpc_connect/1};

        _ ->
            ?MENELAUS_WEB_LOG(0004, "Invalid request received: ~p", [Req]),
            {done, reply_text(Req, "Method Not Allowed", 405)}
    end.

serve_ui(Req, IsSSL, F, Args) ->
    IsDisabledKey = case IsSSL of
                        true ->
                            disable_ui_over_https;
                        false ->
                            disable_ui_over_http
                    end,
    case ns_config:read_key_fast(IsDisabledKey, false) of
        true ->
            reply(Req, 404);
        false ->
            apply(F, Args ++ [Req])
    end.

use_minified(Req) ->
    Query = Req:parse_qs(),
    %% explicity specified minified in the query params
    %% overrides the application env value
    Minified = proplists:get_value("minified", Query),
    Minified =:= "true" orelse
        Minified =:= undefined andalso
        misc:get_env_default(use_minified, true).

serve_ui_env(Req) ->
    %% UI env values are expected to be unfolded proplists
    UIEnvDefault = lists:ukeysort(1, misc:get_env_default(ui_env, [])),
    GlobalUIEnv = lists:ukeysort(1, ns_config:read_key_fast(ui_env, [])),
    NodeSpecificUIEnv = lists:ukeysort(1, ns_config:read_key_fast({node, node(), ui_env}, [])),
    menelaus_util:reply_json(Req,
                             {lists:ukeymerge(1, NodeSpecificUIEnv,
                                              lists:ukeymerge(1, GlobalUIEnv, UIEnvDefault))}).

handle_ui_root(AppRoot, Path, UiCompatVersion, Plugins, Req)
  when UiCompatVersion =:= ?VERSION_45;
       UiCompatVersion =:= ?VERSION_50 ->
    Filename = case use_minified(Req) of
                   true ->
                       IndexFileName =
                           case UiCompatVersion =:= ?VERSION_50 of
                               true -> "index.min.html";
                               false -> "classic-index.min.html"
                           end,
                       filename:join([AppRoot, "ui", IndexFileName]);
                   _ ->
                       filename:join(AppRoot, Path)
               end,
    menelaus_util:reply_ok(
      Req,
      "text/html; charset=utf8",
      menelaus_pluggable_ui:inject_head_fragments(Filename, UiCompatVersion, Plugins));
handle_ui_root(AppRoot, Path, ?VERSION_41, [], Req) ->
    menelaus_util:serve_static_file(Req, {AppRoot, Path},
                                    "text/html; charset=utf8", []).

handle_serve_file(AppRoot, Path, MaxAge, Req) ->
    menelaus_util:serve_file(
        Req, Path, AppRoot,
        [{"Cache-Control", lists:concat(["max-age=", MaxAge])}]).

loop_inner(Req, Info, Path, PathTokens) ->
    menelaus_auth:validate_request(Req),
    perform_action(Req, get_action(Req, Info, Path, PathTokens)).

-spec get_bucket_id(rbac_permission() | no_check) -> bucket_name() | false.
get_bucket_id(no_check) ->
    false;
get_bucket_id({Object, _Operations}) ->
    case lists:keyfind(bucket, 1, Object) of
        {bucket, any} ->
            false;
        {bucket, Bucket} ->
            Bucket;
        false ->
            false
    end.

-spec perform_action(mochiweb_request(), action()) -> term().
perform_action(_Req, {done, RV}) ->
    RV;
perform_action(Req, {local, Fun}) ->
    case menelaus_auth:verify_local_token(Req) of
        {allowed, NewReq} ->
            Fun(NewReq);
        auth_failure ->
            menelaus_util:require_auth(Req)
    end;
perform_action(Req, {ui, IsSSL, Fun}) ->
    perform_action(Req, {ui, IsSSL, Fun, []});
perform_action(Req, {ui, IsSSL, Fun, Args}) ->
    serve_ui(Req, IsSSL, Fun, Args);
perform_action(Req, {Permission, Fun}) ->
    perform_action(Req, {Permission, Fun, []});
perform_action(Req, {Permission, Fun, Args}) ->
    case menelaus_auth:verify_rest_auth(Req, Permission) of
        {allowed, NewReq} ->
            case get_bucket_id(Permission) of
                false ->
                    check_uuid(Fun, Args, NewReq);
                Bucket ->
                    check_bucket_uuid(Bucket, fun check_uuid/3, [Fun, Args], NewReq)
            end;
        auth_failure ->
            menelaus_util:require_auth(Req);
        forbidden ->
            menelaus_util:reply_json(Req, menelaus_web_rbac:forbidden_response(Permission), 403)
    end.

handle_uilogin(Req) ->
    Params = Req:parse_post(),
    User = proplists:get_value("user", Params),
    Password = proplists:get_value("password", Params),
    menelaus_auth:uilogin(Req, User, Password).

handle_uilogout(Req) ->
    case menelaus_auth:extract_ui_auth_token(Req) of
        undefined ->
            ok;
        Token ->
            menelaus_ui_auth:logout(Token)
    end,
    menelaus_auth:complete_uilogout(Req).

check_uuid(F, Args, Req) ->
    ReqUUID0 = proplists:get_value("uuid", Req:parse_qs()),
    case ReqUUID0 =/= undefined of
        true ->
            ReqUUID = list_to_binary(ReqUUID0),
            UUID = get_uuid(),
            %%
            %% get_uuid() will return empty UUID if the system is not
            %% provisioned yet. If ReqUUID is also empty then we let
            %% the request go through. But, if ReqUUID is not-empty
            %% and UUID is empty then we will retrun 404 error.
            %%
            case ReqUUID =:= UUID of
                true ->
                    erlang:apply(F, Args ++ [Req]);
                false ->
                    reply_text(Req, "Cluster uuid does not match the requested.\r\n", 404)
            end;
        false ->
            erlang:apply(F, Args ++ [Req])
    end.

check_bucket_uuid(Bucket, F, Args, Req) ->
    case ns_bucket:get_bucket(Bucket) of
        not_present ->
            ?log_debug("Attempt to access non existent bucket ~p", [Bucket]),
            reply_not_found(Req);
        {ok, BucketConfig} ->
            menelaus_web_buckets:checking_bucket_uuid(
              Req, BucketConfig,
              fun () ->
                      erlang:apply(F, Args ++ [Req])
              end)
    end.

%% Returns an UUID from the ns_config
%% cluster UUID is set in ns_config only when the system is provisioned.
get_uuid() ->
    case ns_config:search(uuid) of
        false ->
            <<>>;
        {value, Uuid2} ->
            Uuid2
    end.

handle_versions(Req) ->
    reply_json(Req, {struct, menelaus_web_cache:versions_response()}).

assert_is_enterprise() ->
    case cluster_compat_mode:is_enterprise() of
        true ->
            ok;
        _ ->
            erlang:throw({web_exception,
                          400,
                          "This http API endpoint requires enterprise edition",
                          [{"X-enterprise-edition-needed", 1}]})
    end.

assert_is_40() ->
    assert_cluster_version(fun cluster_compat_mode:is_cluster_40/0).

assert_is_45() ->
    assert_cluster_version(fun cluster_compat_mode:is_cluster_45/0).

assert_is_50() ->
    assert_cluster_version(fun cluster_compat_mode:is_cluster_50/0).

assert_cluster_version(Fun) ->
    case Fun() of
        true ->
            ok;
        false ->
            erlang:throw({web_exception,
                          400,
                          "This http API endpoint isn't supported in mixed version clusters",
                          []})
    end.

handle_settings_max_parallel_indexers(Req) ->
    Config = ns_config:get(),

    GlobalValue =
        case ns_config:search(Config, {couchdb, max_parallel_indexers}) of
            false ->
                null;
            {value, V} ->
                V
        end,
    ThisNodeValue =
        case ns_config:search_node(node(), Config, {couchdb, max_parallel_indexers}) of
            false ->
                null;
            {value, V2} ->
                V2
        end,

    reply_json(Req, {struct, [{globalValue, GlobalValue},
                              {nodes, {struct, [{node(), ThisNodeValue}]}}]}).

handle_settings_max_parallel_indexers_post(Req) ->
    Params = Req:parse_post(),
    V = proplists:get_value("globalValue", Params, ""),
    case parse_validate_number(V, 1, 1024) of
        {ok, Parsed} ->
            ns_config:set({couchdb, max_parallel_indexers}, Parsed),
            handle_settings_max_parallel_indexers(Req);
        Error ->
            reply_json(Req, {struct, [{'_', iolist_to_binary(io_lib:format("Invalid globalValue: ~p", [Error]))}]}, 400)
    end.

handle_settings_view_update_daemon(Req) ->
    {value, Config} = ns_config:search(set_view_update_daemon),

    UpdateInterval = proplists:get_value(update_interval, Config),
    UpdateMinChanges = proplists:get_value(update_min_changes, Config),
    ReplicaUpdateMinChanges = proplists:get_value(replica_update_min_changes, Config),

    true = (UpdateInterval =/= undefined),
    true = (UpdateMinChanges =/= undefined),
    true = (UpdateMinChanges =/= undefined),

    reply_json(Req, {struct, [{updateInterval, UpdateInterval},
                              {updateMinChanges, UpdateMinChanges},
                              {replicaUpdateMinChanges, ReplicaUpdateMinChanges}]}).

handle_settings_view_update_daemon_post(Req) ->
    Params = Req:parse_post(),

    {Props, Errors} =
        lists:foldl(
          fun ({Key, RestKey}, {AccProps, AccErrors} = Acc) ->
                  Raw = proplists:get_value(RestKey, Params),

                  case Raw of
                      undefined ->
                          Acc;
                      _ ->
                          case parse_validate_number(Raw, 0, undefined) of
                              {ok, Value} ->
                                  {[{Key, Value} | AccProps], AccErrors};
                              Error ->
                                  Msg = io_lib:format("Invalid ~s: ~p",
                                                      [RestKey, Error]),
                                  {AccProps, [{RestKey, iolist_to_binary(Msg)}]}
                          end
                  end
          end, {[], []},
          [{update_interval, "updateInterval"},
           {update_min_changes, "updateMinChanges"},
           {replica_update_min_changes, "replicaUpdateMinChanges"}]),

    case Errors of
        [] ->
            {value, CurrentProps} = ns_config:search(set_view_update_daemon),
            MergedProps = misc:update_proplist(CurrentProps, Props),
            ns_config:set(set_view_update_daemon, MergedProps),
            handle_settings_view_update_daemon(Req);
        _ ->
            reply_json(Req, {struct, Errors}, 400)
    end.

handle_settings_web(Req) ->
    reply_json(Req, build_settings_web()).

build_settings_web() ->
    Port = proplists:get_value(port, webconfig()),
    User = case ns_config_auth:get_user(admin) of
               undefined ->
                   "";
               U ->
                   U
           end,
    {struct, [{port, Port},
              {username, list_to_binary(User)}]}.

%% @doc Settings to en-/disable stats sending to some remote server
handle_settings_stats(Req) ->
    reply_json(Req, {struct, build_settings_stats()}).

build_settings_stats() ->
    Defaults = default_settings_stats_config(),
    [{send_stats, SendStats}] = ns_config:search_prop(
                                  ns_config:get(), settings, stats, Defaults),
    [{sendStats, SendStats}].

default_settings_stats_config() ->
    [{send_stats, false}].

handle_settings_stats_post(Req) ->
    PostArgs = Req:parse_post(),
    SendStats = proplists:get_value("sendStats", PostArgs),
    case validate_settings_stats(SendStats) of
        error ->
            reply_text(Req, "The value of \"sendStats\" must be true or false.", 400);
        SendStats2 ->
            ns_config:set(settings, [{stats, [{send_stats, SendStats2}]}]),
            reply(Req, 200)
    end.

validate_settings_stats(SendStats) ->
    case SendStats of
        "true" -> true;
        "false" -> false;
        _ -> error
    end.

%% @doc Settings to en-/disable auto-reprovision
handle_settings_auto_reprovision(Req) ->
    assert_is_50(),

    Config = build_settings_auto_reprovision(),
    Enabled = proplists:get_value(enabled, Config),
    MaxNodes = proplists:get_value(max_nodes, Config),
    Count = proplists:get_value(count, Config),
    reply_json(Req, {struct, [{enabled, Enabled},
                              {max_nodes, MaxNodes},
                              {count, Count}]}).

build_settings_auto_reprovision() ->
    {value, Config} = ns_config:search(ns_config:get(), auto_reprovision_cfg),
    Config.

handle_settings_auto_reprovision_post(Req) ->
    assert_is_50(),

    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    Enabled = proplists:get_value("enabled", PostArgs),
    MaxNodes = proplists:get_value("maxNodes", PostArgs),
    case {ValidateOnly,
          validate_settings_auto_reprovision(Enabled, MaxNodes)} of
        {false, [true, MaxNodes2]} ->
            auto_reprovision:enable(MaxNodes2),
            reply(Req, 200);
        {false, false} ->
            auto_reprovision:disable(),
            reply(Req, 200);
        {false, {error, Errors}} ->
            Errors2 = [<<Msg/binary, "\n">> || {_, Msg} <- Errors],
            reply_text(Req, Errors2, 400);
        {true, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 200);
        %% Validation only and no errors
        {true, _}->
            reply_json(Req, {struct, [{errors, null}]}, 200)
    end.

validate_settings_auto_reprovision(Enabled, MaxNodes) ->
    Enabled2 = case Enabled of
        "true" -> true;
        "false" -> false;
        _ -> {enabled, <<"The value of \"enabled\" must be true or false">>}
    end,
    case Enabled2 of
        true ->
            case is_valid_positive_integer(MaxNodes) of
                true ->
                    [Enabled2, list_to_integer(MaxNodes)];
                false ->
                    {error, [{maxNodes,
                              <<"The value of \"maxNodes\" must be a positive integer">>}]}
            end;
        false ->
            Enabled2;
        Error ->
            {error, [Error]}
    end.

%% @doc Resets the number of nodes that were automatically reprovisioned to zero
handle_settings_auto_reprovision_reset_count(Req) ->
    assert_is_50(),

    auto_reprovision:reset_count(),
    reply(Req, 200).

maybe_cleanup_old_buckets() ->
    case ns_config_auth:is_system_provisioned() of
        true ->
            ok;
        false ->
            true = ns_node_disco:nodes_wanted() =:= [node()],
            ns_storage_conf:delete_unused_buckets_db_files()
    end.

is_valid_port_number_or_error("SAME") -> true;
is_valid_port_number_or_error(StringPort) ->
    case (catch menelaus_util:parse_validate_port_number(StringPort)) of
        {error, [Error]} ->
            Error;
        _ ->
            true
    end.

is_port_free("SAME") ->
    true;
is_port_free(Port) ->
    ns_bucket:is_port_free(list_to_integer(Port)).

validate_settings(Port, U, P) ->
    case lists:all(fun erlang:is_list/1, [Port, U, P]) of
        false -> [<<"All parameters must be given">>];
        _ -> Candidates = [is_valid_port_number_or_error(Port),
                           is_port_free(Port)
                           orelse <<"Port is already in use">>,
                           case {U, P} of
                               {[], _} -> <<"Username and password are required.">>;
                               {[_Head | _], P} ->
                                   case menelaus_web_rbac:validate_cred(U, username) of
                                       true ->
                                           menelaus_web_rbac:validate_cred(P, password);
                                       Msg ->
                                           Msg
                                   end
                           end],
             lists:filter(fun (E) -> E =/= true end,
                          Candidates)
    end.

%% These represent settings for a cluster.  Node settings should go
%% through the /node URIs
handle_settings_web_post(Req) ->
    menelaus_web_rbac:assert_no_users_upgrade(),

    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",

    Port = proplists:get_value("port", PostArgs),
    U = proplists:get_value("username", PostArgs),
    P = proplists:get_value("password", PostArgs),
    case validate_settings(Port, U, P) of
        [_Head | _] = Errors ->
            reply_json(Req, Errors, 400);
        [] ->
            case ValidateOnly of
                true ->
                    reply(Req, 200);
                false ->
                    do_handle_settings_web_post(Port, U, P, Req)
            end
    end.

do_handle_settings_web_post(Port, U, P, Req) ->
    PortInt = case Port of
                  "SAME" -> proplists:get_value(port, webconfig());
                  _      -> list_to_integer(Port)
              end,
    case Port =/= PortInt orelse ns_config_auth:credentials_changed(admin, U, P) of
        false -> ok; % No change.
        true ->
            maybe_cleanup_old_buckets(),
            ns_config:set(rest, [{port, PortInt}]),
            ns_config_auth:set_credentials(admin, U, P),
            case ns_config:search(uuid) of
                false ->
                    Uuid = couch_uuids:random(),
                    ns_config:set(uuid, Uuid);
                _ ->
                    ok
            end,
            ns_audit:password_change(Req, {U, admin}),

            menelaus_ui_auth:reset()

            %% No need to restart right here, as our ns_config
            %% event watcher will do it later if necessary.
    end,
    Host = Req:get_header_value("host"),
    PureHostName = case string:tokens(Host, ":") of
                       [Host] -> Host;
                       [HostName, _] -> HostName
                   end,
    NewHost = PureHostName ++ ":" ++ integer_to_list(PortInt),
    %% TODO: detect and support https when time will come
    reply_json(Req, {struct, [{newBaseUri, list_to_binary("http://" ++ NewHost ++ "/")}]}).

handle_settings_alerts(Req) ->
    {value, Config} = ns_config:search(email_alerts),
    reply_json(Req, {struct, menelaus_alert:build_alerts_json(Config)}).

handle_settings_alerts_post(Req) ->
    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    case {ValidateOnly, menelaus_alert:parse_settings_alerts_post(PostArgs)} of
        {false, {ok, Config}} ->
            ns_config:set(email_alerts, Config),
            ns_audit:alerts(Req, Config),
            reply(Req, 200);
        {false, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400);
        {true, {ok, _}} ->
            reply_json(Req, {struct, [{errors, null}]}, 200);
        {true, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 200)
    end.

%% @doc Sends a test email with the current settings
handle_settings_alerts_send_test_email(Req) ->
    PostArgs = Req:parse_post(),
    Subject = proplists:get_value("subject", PostArgs),
    Body = proplists:get_value("body", PostArgs),
    PostArgs1 = [{K, V} || {K, V} <- PostArgs,
                           not lists:member(K, ["subject", "body"])],
    {ok, Config} = menelaus_alert:parse_settings_alerts_post(PostArgs1),

    case ns_mail:send(Subject, Body, Config) of
        ok ->
            reply(Req, 200);
        {error, Reason} ->
            Msg =
                case Reason of
                    {_, _, {error, R}} ->
                        R;
                    {_, _, R} ->
                        R;
                    R ->
                        R
                end,

            reply_json(Req, {struct, [{error, couch_util:to_binary(Msg)}]}, 400)
    end.

%% log categorizing, every logging line should be unique, and most
%% should be categorized

ns_log_cat(0013) ->
    crit;
ns_log_cat(0019) ->
    warn;
ns_log_cat(?START_FAIL) ->
    crit;
ns_log_cat(?NODE_EJECTED) ->
    info;
ns_log_cat(?UI_SIDE_ERROR_REPORT) ->
    warn.

ns_log_code_string(0013) ->
    "node join failure";
ns_log_code_string(0019) ->
    "server error during request processing";
ns_log_code_string(?START_FAIL) ->
    "failed to start service";
ns_log_code_string(?NODE_EJECTED) ->
    "node was ejected";
ns_log_code_string(?UI_SIDE_ERROR_REPORT) ->
    "client-side error report".

alert_key(?BUCKET_CREATED)  -> bucket_created;
alert_key(?BUCKET_DELETED)  -> bucket_deleted;
alert_key(_) -> all.

handle_dot(Bucket, Req) ->
    reply_ok(Req, "text/plain; charset=utf-8", ns_janitor_vis:graphviz(Bucket)).

handle_dotsvg(Bucket, Req) ->
    Dot = ns_janitor_vis:graphviz(Bucket),
    DoRefresh = case proplists:get_value("refresh", Req:parse_qs(), "") of
                    "ok" -> true;
                    "yes" -> true;
                    "1" -> true;
                    _ -> false
                end,
    MaybeRefresh = if DoRefresh ->
                           [{"refresh", 1}];
                      true -> []
                   end,
    reply_ok(Req, "image/svg+xml",
             menelaus_util:insecure_pipe_through_command("dot -Tsvg", Dot),
             MaybeRefresh).

handle_tasks(PoolId, Req) ->
    RebTimeoutS = proplists:get_value("rebalanceStatusTimeout", Req:parse_qs(), "2000"),
    case menelaus_util:parse_validate_number(RebTimeoutS, 1000, 120000) of
        {ok, RebTimeout} ->
            do_handle_tasks(PoolId, Req, RebTimeout);
        _ ->
            reply_json(Req, {struct, [{rebalanceStatusTimeout, <<"invalid">>}]}, 400)
    end.

do_handle_tasks(PoolId, Req, RebTimeout) ->
    JSON = ns_doctor:build_tasks_list(PoolId, RebTimeout),
    reply_json(Req, JSON, 200).

handle_reset_alerts(Req) ->
    Params = Req:parse_qs(),
    Token = list_to_binary(proplists:get_value("token", Params, "")),
    reply_json(Req, menelaus_web_alerts_srv:consume_alerts(Token)).

build_terse_bucket_info(BucketName) ->
    case bucket_info_cache:terse_bucket_info(BucketName) of
        {ok, V} -> V;
        %% NOTE: {auth_bucket for this route handles 404 for us albeit
        %% harmlessly racefully
        {T, E, Stack} ->
            erlang:raise(T, E, Stack)
    end.

serve_short_bucket_info(_PoolId, BucketName, Req) ->
    V = build_terse_bucket_info(BucketName),
    reply_ok(Req, "application/json", V).

serve_streaming_short_bucket_info(_PoolId, BucketName, Req) ->
    handle_streaming(
      fun (_, _) ->
              V = build_terse_bucket_info(BucketName),
              {just_write, {write, V}}
      end, Req).

handle_log_post(Req) ->
    Params = Req:parse_post(),
    Msg = proplists:get_value("message", Params),
    LogLevel = proplists:get_value("logLevel", Params),
    Component = proplists:get_value("component", Params),

    Errors =
        lists:flatten([case Msg of
                           undefined ->
                               {<<"message">>, <<"missing value">>};
                           _ ->
                               []
                       end,
                       case LogLevel of
                           "info" ->
                               [];
                           "warn" ->
                               [];
                           "error" ->
                               [];
                           _ ->
                               {<<"logLevel">>, <<"invalid or missing value">>}
                       end,
                       case Component of
                           undefined ->
                               {<<"component">>, <<"missing value">>};
                           _ ->
                               []
                       end]),

    case Errors of
        [] ->
            Fun = list_to_existing_atom([$x | LogLevel]),
            ale:Fun(?USER_LOGGER,
                    {list_to_atom(Component), unknown, -1}, undefined, Msg, []),
            reply_json(Req, []);
        _ ->
            reply_json(Req, {struct, Errors}, 400)
    end.

handle_settings_audit(Req) ->
    assert_is_enterprise(),
    assert_is_40(),

    Props = ns_audit_cfg:get_global(),
    Json = lists:map(fun ({K, V}) when is_list(V) ->
                             {K, list_to_binary(V)};
                         (Other) ->
                             Other
                     end, Props),
    reply_json(Req, {Json}).

validate_settings_audit(Args) ->
    R = validate_has_params({Args, [], []}),
    R0 = validate_boolean(auditdEnabled, R),
    R1 = validate_dir(logPath, validate_any_value(logPath, R0)),
    R2 = validate_integer(rotateInterval, R1),
    R3 = validate_range(
           rotateInterval, 15*60, 60*60*24*7,
           fun (Name, _Min, _Max) ->
                   io_lib:format("The value of ~p must be in range from 15 minutes to 7 days",
                                 [Name])
           end, R2),
    R4 = validate_by_fun(fun (Value) ->
                                 case Value rem 60 of
                                     0 ->
                                         ok;
                                     _ ->
                                         {error, "Value must not be a fraction of minute"}
                                 end
                         end, rotateInterval, R3),
    R5 = validate_integer(rotateSize, R4),
    R6 = validate_range(rotateSize, 0, 500*1024*1024, R5),
    validate_unsupported_params(R6).

handle_settings_audit_post(Req) ->
    assert_is_enterprise(),
    assert_is_40(),

    Args = Req:parse_post(),
    execute_if_validated(fun (Values) ->
                                 ns_audit_cfg:set_global(Values),
                                 reply(Req, 200)
                         end, Req, validate_settings_audit(Args)).

nth_path_tail(Path, N) when N > 0 ->
    nth_path_tail(path_tail(Path), N-1);
nth_path_tail(Path, 0) ->
    Path.

path_tail([$/|[$/|_] = Path]) ->
    path_tail(Path);
path_tail([$/|Path]) ->
    Path;
path_tail([_|Rest]) ->
    path_tail(Rest);
path_tail([]) ->
    [].

drop_rest_prefix("/" ++ Path) ->
    [$/ | nth_path_tail(Path, 2)].

drop_prefix("/" ++ Path) ->
    [$/ | nth_path_tail(Path, 1)].
