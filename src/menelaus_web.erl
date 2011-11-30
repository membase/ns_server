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
-include("ns_stats.hrl").

-ifdef(EUNIT).
-export([test/0]).
-endif.

-export([start_link/0,
         start_link/1,
         stop/0,
         loop/3,
         webconfig/0,
         webconfig/1,
         restart/0,
         build_node_hostname/3,
         build_nodes_info/0,
         build_nodes_info_fun/3,
         build_full_node_info/2,
         handle_streaming/3,
         is_system_provisioned/0,
         checking_bucket_hostname_access/5,
         build_auto_compaction_settings/1,
         parse_validate_auto_compaction_settings/1,
         parse_validate_bucket_auto_compaction_settings/1]).

-export([ns_log_cat/1, ns_log_code_string/1, alert_key/1]).

-import(menelaus_util,
        [server_header/0,
         redirect_permanently/2,
         concat_url_path/1,
         reply_json/2,
         reply_json/3,
         get_option/2,
         parse_validate_number/3]).

-define(AUTO_FAILLOVER_MIN_TIMEOUT, 30).

%% External API

start_link() ->
    start_link(webconfig()).

start_link(Options) ->
    {AppRoot, Options1} = get_option(approot, Options),
    {DocRoot, Options2} = get_option(docroot, Options1),
    Loop = fun (Req) ->
                   ?MODULE:loop(Req, AppRoot, DocRoot)
           end,
    case mochiweb_http:start([{name, ?MODULE}, {loop, Loop} | Options2]) of
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
             false -> "0.0.0.0";
             Any -> Any
         end,
    Port = case os:getenv("MOCHIWEB_PORT") of
               false ->
                   misc:node_rest_port(Config, node());
               P -> list_to_integer(P)
           end,
    WebConfig = [{ip, Ip},
                 {port, Port},
                 {approot, menelaus_deps:local_path(["priv","public"],
                                                    ?MODULE)}],
    WebConfig.

webconfig() ->
    webconfig(ns_config:get()).

loop(Req, AppRoot, DocRoot) ->
    try
        % Using raw_path so encoded slash characters like %2F are handed correctly,
        % in that we delay converting %2F's to slash characters until after we split by slashes.
        "/" ++ RawPath = Req:get(raw_path),
        {Path, _, _} = mochiweb_util:urlsplit_path(RawPath),
        PathTokens = lists:map(fun mochiweb_util:unquote/1, string:tokens(Path, "/")),
        Action = case Req:get(method) of
                     Method when Method =:= 'GET'; Method =:= 'HEAD' ->
                         case PathTokens of
                             [] ->
                                 {done, redirect_permanently("/index.html", Req)};
                             ["versions"] ->
                                 {done, handle_versions(Req)};
                             ["pools"] ->
                                 {auth_any_bucket, fun handle_pools/1};
                             ["pools", Id] ->
                                 {auth_any_bucket, fun check_and_handle_pool_info/2, [Id]};
                             ["pools", Id, "stats"] ->
                                 {auth_any_bucket, fun menelaus_stats:handle_bucket_stats/3,
                                  [Id, all]};
                             ["pools", Id, "overviewStats"] ->
                                 {auth, fun menelaus_stats:handle_overview_stats/2, [Id]};
                             ["poolsStreaming", Id] ->
                                 {auth_any_bucket, fun handle_pool_info_streaming/2, [Id]};
                             ["pools", PoolId, "buckets"] ->
                                 {auth_any_bucket, fun menelaus_web_buckets:handle_bucket_list/2, [PoolId]};
                             ["pools", PoolId, "saslBucketsStreaming"] ->
                                 {auth, fun menelaus_web_buckets:handle_sasl_buckets_streaming/2, [PoolId]};
                             ["pools", PoolId, "buckets", Id] ->
                                 {auth_bucket_with_info, fun menelaus_web_buckets:handle_bucket_info/5,
                                  [PoolId, Id]};
                             ["pools", PoolId, "bucketsStreaming", Id] ->
                                 {auth_bucket, fun menelaus_web_buckets:handle_bucket_info_streaming/3,
                                  [PoolId, Id]};
                             ["pools", PoolId, "buckets", Id, "stats"] ->
                                 {auth_bucket, fun menelaus_stats:handle_bucket_stats/3,
                                  [PoolId, Id]};
                             ["pools", PoolId, "buckets", Id, "statsDirectory"] ->
                                 {auth_bucket, fun menelaus_stats:serve_stats_directory/3,
                                  [PoolId, Id]};
                             %% GET /pools/{PoolId}/buckets/{Id}/nodes
                             ["pools", PoolId, "buckets", Id, "nodes"] ->
                                 {auth_bucket, fun handle_bucket_node_list/3,
                                  [PoolId, Id]};
                             %% GET /pools/{PoolId}/buckets/{Id}/nodes/{NodeId}
                             ["pools", PoolId, "buckets", Id, "nodes", NodeId] ->
                                 {auth_bucket, fun handle_bucket_node_info/4,
                                  [PoolId, Id, NodeId]};
                             %% GET /pools/{PoolId}/buckets/{Id}/nodes/{NodeId}/stats
                             ["pools", PoolId, "buckets", Id, "nodes", NodeId, "stats"] ->
                                  {auth_bucket, fun menelaus_stats:handle_bucket_node_stats/4,
                                   [PoolId, Id, NodeId]};
                             %% GET /pools/{PoolId}/buckets/{Id}/stats/{StatName}
                             ["pools", PoolId, "buckets", Id, "stats", StatName] ->
                                  {auth_bucket, fun menelaus_stats:handle_specific_stat_for_buckets/4,
                                   [PoolId, Id, StatName]};
                             ["pools", "default", "remoteClusters"] ->
                                 {auth, fun menelaus_web_remote_clusters:handle_remote_clusters/1};
                             ["nodeStatuses"] ->
                                 {auth, fun handle_node_statuses/1};
                             ["logs"] ->
                                 {auth, fun menelaus_alert:handle_logs/1};
                             ["alerts"] ->
                                 {auth, fun menelaus_alert:handle_alerts/1};
                             ["settings", "web"] ->
                                 {auth, fun handle_settings_web/1};
                             ["settings", "alerts"] ->
                                 {auth, fun handle_settings_alerts/1};
                             ["settings", "stats"] ->
                                 {auth, fun handle_settings_stats/1};
                             ["settings", "autoFailover"] ->
                                 {auth, fun handle_settings_auto_failover/1};
                             ["nodes", NodeId] ->
                                 {auth, fun handle_node/2, [NodeId]};
                             ["diag"] ->
                                 {auth_cookie, fun diag_handler:handle_diag/1};
                             ["diag", "vbuckets"] -> {auth, fun handle_diag_vbuckets/1};
                             ["pools", PoolId, "rebalanceProgress"] ->
                                 {auth, fun handle_rebalance_progress/2, [PoolId]};
                             ["index.html"] ->
                                 {done, serve_static_file(Req, {AppRoot, Path},
                                                         "text/html; charset=utf8",
                                                          [{"Pragma", "no-cache"},
                                                           {"Cache-Control", "must-revalidate"}])};
                             ["docs" | _PRem ] ->
                                 DocFile = string:sub_string(Path, 6),
                                 {done, Req:serve_file(DocFile, DocRoot)};
                             ["dot", Bucket] ->
                                 {auth_cookie, fun handle_dot/2, [Bucket]};
                             ["dotsvg", Bucket] ->
                                 {auth_cookie, fun handle_dotsvg/2, [Bucket]};
                             ["sasl_logs"] ->
                                 {auth_cookie, fun diag_handler:handle_sasl_logs/1};
                             ["sasl_logs", LogName] ->
                                 {auth_cookie, fun diag_handler:handle_sasl_logs/2, [LogName]};
                             ["erlwsh" | _] ->
                                 {auth_cookie, fun (R) -> erlwsh_web:loop(R, erlwsh_deps:local_path(["priv", "www"])) end};
                             ["images" | _] ->
                                 {done, Req:serve_file(Path, AppRoot,
                                                       [{"Cache-Control", "max-age=30000000"}])};
                             ["couchBase" | _] -> {done, capi_http_proxy:handle_proxy_req(Req)};
                             _ ->
                                 {done, Req:serve_file(Path, AppRoot,
                                  [{"Cache-Control", "max-age=10"}])}
                        end;
                     'POST' ->
                         case PathTokens of
                             ["engageCluster2"] ->
                                 {auth, fun handle_engage_cluster2/1};
                             ["completeJoin"] ->
                                 {auth, fun handle_complete_join/1};
                             ["node", "controller", "doJoinCluster"] ->
                                 {auth, fun handle_join/1};
                             ["nodes", NodeId, "controller", "settings"] ->
                                 {auth, fun handle_node_settings_post/2,
                                  [NodeId]};
                             ["nodes", NodeId, "controller", "resources"] ->
                                 {auth, fun handle_node_resources_post/2,
                                  [NodeId]};
                             ["settings", "web"] ->
                                 {auth, fun handle_settings_web_post/1};
                             ["settings", "alerts"] ->
                                 {auth, fun handle_settings_alerts_post/1};
                             ["settings", "alerts", "testEmail"] ->
                                 {auth, fun handle_settings_alerts_send_test_email/1};
                             ["settings", "stats"] ->
                                 {auth, fun handle_settings_stats_post/1};
                             ["settings", "autoFailover"] ->
                                 {auth, fun handle_settings_auto_failover_post/1};
                             ["settings", "autoFailover", "resetCount"] ->
                                 {auth, fun handle_settings_auto_failover_reset_count/1};
                             ["pools", PoolId] ->
                                 {auth, fun handle_pool_settings/2,
                                  [PoolId]};
                             ["controller", "setupDefaultBucket"] ->
                                 {auth, fun menelaus_web_buckets:handle_setup_default_bucket_post/1};
                             ["controller", "ejectNode"] ->
                                 {auth, fun handle_eject_post/1};
                             ["controller", "addNode"] ->
                                 {auth, fun handle_add_node/1};
                             ["controller", "failOver"] ->
                                 {auth, fun handle_failover/1};
                             ["controller", "rebalance"] ->
                                 {auth, fun handle_rebalance/1};
                             ["controller", "reAddNode"] ->
                                 {auth, fun handle_re_add_node/1};
                             ["controller", "stopRebalance"] ->
                                 {auth, fun handle_stop_rebalance/1};
                             ["controller", "setAutoCompaction"] ->
                                 {auth, fun handle_set_autocompaction/1};
                             ["controller", "createReplication"] ->
                                 {auth, fun menelaus_web_create_replication:handle_create_replication/1};
                             ["pools", PoolId, "buckets", Id] ->
                                 {auth_bucket, fun menelaus_web_buckets:handle_bucket_update/3,
                                  [PoolId, Id]};
                             ["pools", PoolId, "buckets"] ->
                                 {auth, fun menelaus_web_buckets:handle_bucket_create/2,
                                  [PoolId]};
                             ["pools", PoolId, "buckets", Id, "controller", "doFlush"] ->
                                 {auth_bucket, fun menelaus_web_buckets:handle_bucket_flush/3,
                                [PoolId, Id]};
                             ["pools", "default", "remoteClusters"] ->
                                 {auth, fun menelaus_web_remote_clusters:handle_remote_clusters_post/1};
                             ["pools", "default", "remoteClusters", Id] ->
                                 {auth, fun menelaus_web_remote_clusters:handle_remote_cluster_update/2, [Id]};
                             ["logClientError"] -> {auth_any_bucket,
                                                    fun (R) ->
                                                            User = menelaus_auth:extract_auth(username, R),
                                                            ?MENELAUS_WEB_LOG(?UI_SIDE_ERROR_REPORT,
                                                                              "Client-side error-report for user ~p on node ~p:~nUser-Agent:~s~n~s~n",
                                                                              [User, node(),
                                                                               Req:get_header_value("user-agent"), binary_to_list(R:recv_body())]),
                                                            R:ok({"text/plain", add_header(), <<"">>})
                                                    end};
                             ["diag", "eval"] -> {auth, fun handle_diag_eval/1};
                             ["erlwsh" | _] ->
                                 {done, erlwsh_web:loop(Req, erlwsh_deps:local_path(["priv", "www"]))};
                             ["couchBase" | _] -> {done, capi_http_proxy:handle_proxy_req(Req)};
                             _ ->
                                 ?MENELAUS_WEB_LOG(0001, "Invalid post received: ~p", [Req]),
                                 {done, Req:not_found()}
                      end;
                     'DELETE' ->
                         case PathTokens of
                             ["pools", PoolId, "buckets", Id] ->
                                 {auth, fun menelaus_web_buckets:handle_bucket_delete/3, [PoolId, Id]};
                             ["pools", "default", "remoteClusters", Id] ->
                                 {auth, fun menelaus_web_remote_clusters:handle_remote_cluster_delete/2, [Id]};
                             ["nodes", Node, "resources", LocationPath] ->
                                 {auth, fun handle_resource_delete/3, [Node, LocationPath]};
                             ["couchBase" | _] -> {done, capi_http_proxy:handle_proxy_req(Req)};
                             _ ->
                                 ?MENELAUS_WEB_LOG(0002, "Invalid delete received: ~p as ~p", [Req, PathTokens]),
                                  {done, Req:respond({405, add_header(), "Method Not Allowed"})}
                         end;
                     Method when Method =:= 'PUT'; Method =:= "COPY" ->
                         case PathTokens of
                             ["couchBase" | _] -> {done, capi_http_proxy:handle_proxy_req(Req)};
                             _ ->
                                 ?MENELAUS_WEB_LOG(0003, "Invalid ~p received: ~p", [Method, Req]),
                                 {done, Req:respond({405, add_header(), "Method Not Allowed"})}
                         end;

                     _ ->
                         ?MENELAUS_WEB_LOG(0004, "Invalid request received: ~p", [Req]),
                         {done, Req:respond({405, add_header(), "Method Not Allowed"})}
                 end,
        case Action of
            {done, RV} -> RV;
            {auth_cookie, F} -> menelaus_auth:apply_auth_cookie(Req, F, []);
            {auth, F} -> menelaus_auth:apply_auth(Req, F, []);
            {auth_cookie, F, Args} -> menelaus_auth:apply_auth_cookie(Req, F, Args);
            {auth, F, Args} -> menelaus_auth:apply_auth(Req, F, Args);
            {auth_bucket_with_info, F, [ArgPoolId, ArgBucketId | RestArgs]} ->
                menelaus_web_buckets:checking_bucket_access(ArgPoolId, ArgBucketId, Req,
                                                            fun (Pool, Bucket) ->
                                                                    apply(F, [ArgPoolId, ArgBucketId] ++ RestArgs ++ [Req, Pool, Bucket])
                                                            end);
            {auth_bucket, F, [ArgPoolId, ArgBucketId | RestArgs]} ->
                menelaus_web_buckets:checking_bucket_access(ArgPoolId, ArgBucketId, Req,
                                                            fun (_, _) ->
                                                                    apply(F, [ArgPoolId, ArgBucketId] ++ RestArgs ++ [Req])
                                                            end);
            {auth_any_bucket, F} -> menelaus_auth:apply_auth_bucket(Req, F, []);
            {auth_any_bucket, F, Args} -> menelaus_auth:apply_auth_bucket(Req, F, Args)
        end
    catch
        exit:normal ->
            %% this happens when the client closed the connection
            exit(normal);
        Type:What ->
            Report = ["web request failed",
                      {path, Req:get(path)},
                      {type, Type}, {what, What},
                      {trace, erlang:get_stacktrace()}], % todo: find a way to enable this for field info gathering
            ?MENELAUS_WEB_LOG(0019, "Server error during processing: ~p", [Report]),
            reply_json(Req, [list_to_binary("Unexpected server error, request logged.")], 500)
    end.


%% Internal API

implementation_version() ->
    list_to_binary(proplists:get_value(ns_server, ns_info:version(), "unknown")).

handle_pools(Req) ->
    Pools = [{struct,
              [{name, <<"default">>},
               {uri, list_to_binary(concat_url_path(["pools", "default"]))},
               {streamingUri, list_to_binary(concat_url_path(["poolsStreaming", "default"]))}]}],
    EffectivePools =
        case is_system_provisioned() of
            true -> Pools;
            _ -> []
        end,
    reply_json(Req,{struct, [{pools, EffectivePools},
                             {isAdminCreds, menelaus_auth:is_under_admin(Req)},
                             {uuid, get_uuid()}
                             | build_versions()]}).
handle_engage_cluster2(Req) ->
    Body = Req:recv_body(),
    {struct, NodeKVList} = mochijson2:decode(Body),
    %% a bit kludgy, but 100% correct way to protect ourselves when
    %% everything will restart.
    process_flag(trap_exit, true),
    case ns_cluster:engage_cluster(NodeKVList) of
        {ok, _} ->
            handle_node("self", Req);
        {error, _What, Message, _Nested} ->
            reply_json(Req, [Message], 400)
    end,
    exit(normal).

handle_complete_join(Req) ->
    {struct, NodeKVList} = mochijson2:decode(Req:recv_body()),
    erlang:process_flag(trap_exit, true),
    case ns_cluster:complete_join(NodeKVList) of
        {ok, _} ->
            reply_json(Req, [], 200);
        {error, _What, Message, _Nested} ->
            reply_json(Req, [Message], 400)
    end,
    exit(normal).

% Returns an UUID if it is already in the ns_config and generates
% a new one otherwise.
get_uuid() ->
    case ns_config:search(uuid) of
        false ->
            Uuid = couch_uuids:random(),
            ns_config:set(uuid, Uuid),
            Uuid;
        {value, Uuid2} ->
            Uuid2
    end.

build_versions() ->
    [{implementationVersion, implementation_version()},
     {componentsVersion, {struct,
                          lists:map(fun ({K,V}) ->
                                            {K, list_to_binary(V)}
                                    end,
                                    ns_info:version())}}].

handle_versions(Req) ->
    reply_json(Req, {struct, build_versions()}).

% {"default", [
%   {port, 11211},
%   {buckets, [
%     {"default", [
%       {auth_plain, undefined},
%       {size_per_node, 64}, % In MB.
%       {cache_expiration_range, {0,600}}
%     ]}
%   ]}
% ]}

check_and_handle_pool_info(Id, Req) ->
    case is_system_provisioned() of
        true ->
            Timeout = diag_handler:arm_timeout(23000),
            try
                handle_pool_info(Id, Req)
            after
                diag_handler:disarm_timeout(Timeout)
            end;
        _ ->
            reply_json(Req, <<"unknown pool">>, 404)
    end.

handle_pool_info(Id, Req) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    LocalAddr = menelaus_util:local_addr(Req),
    Query = Req:parse_qs(),
    {WaitChangeS, PassedETag} = {proplists:get_value("waitChange", Query),
                                  proplists:get_value("etag", Query)},
    case WaitChangeS of
        undefined -> reply_json(Req, build_pool_info(Id, UserPassword, normal, LocalAddr));
        _ ->
            WaitChange = list_to_integer(WaitChangeS),
            menelaus_event:register_watcher(self()),
            handle_pool_info_wait(Req, Id, UserPassword, LocalAddr, WaitChange, PassedETag)
    end.

handle_pool_info_wait(Req, Id, UserPassword, LocalAddr, WaitChange, PassedETag) ->
    Info = mochijson2:encode(build_pool_info(Id, UserPassword, stable, LocalAddr)),
    %% ETag = base64:encode_to_string(crypto:sha(Info)),
    ETag = integer_to_list(erlang:phash2(Info)),
    if
        ETag =:= PassedETag ->
            receive
                {notify_watcher, _} ->
                    timer:sleep(200), %% delay a bit to catch more notifications
                    handle_pool_info_wait(Req, Id, UserPassword, LocalAddr, 0, PassedETag);
                _ ->
                    exit(normal)
            after WaitChange ->
                    handle_pool_info_wait_tail(Req, Id, UserPassword, LocalAddr, ETag)
            end;
        true ->
            handle_pool_info_wait_tail(Req, Id, UserPassword, LocalAddr, ETag)
    end.

consume_notifications() ->
    receive
        {notify_watcher, _} -> consume_notifications()
    after 0 ->
            done
    end.

handle_pool_info_wait_tail(Req, Id, UserPassword, LocalAddr, ETag) ->
    menelaus_event:unregister_watcher(self()),
    %% consume all notifications
    consume_notifications(),
    %% and reply
    {struct, PList} = build_pool_info(Id, UserPassword, normal, LocalAddr),
    Info = {struct, [{etag, list_to_binary(ETag)} | PList]},
    reply_json(Req, Info).

build_pool_info(Id, UserPassword, InfoLevel, LocalAddr) ->
    F = build_nodes_info_fun(menelaus_auth:check_auth(UserPassword), InfoLevel, LocalAddr),
    Nodes = [F(N, undefined) || N <- ns_node_disco:nodes_wanted()],
    Config = ns_config:get(),
    BucketsVer = erlang:phash2(ns_bucket:get_bucket_names(Config))
        bxor erlang:phash2([{proplists:get_value(hostname, KV),
                             proplists:get_value(status, KV)} || {struct, KV} <- Nodes]),
    BucketsInfo = {struct, [{uri,
                             list_to_binary(concat_url_path(["pools", Id, "buckets"])
                                            ++ "?v=" ++ integer_to_list(BucketsVer))}]},
    RebalanceStatus = case ns_cluster_membership:get_rebalance_status() of
                          {running, _ProgressList} -> <<"running">>;
                          _ -> <<"none">>
                      end,
    Alerts = menelaus_web_alerts_srv:fetch_alerts(),

    Controllers = {struct, [
                            {addNode, {struct, [{uri, <<"/controller/addNode">>}]}},
                            {rebalance, {struct, [{uri, <<"/controller/rebalance">>}]}},
                            {failOver, {struct, [{uri, <<"/controller/failOver">>}]}},
                            {reAddNode, {struct, [{uri, <<"/controller/reAddNode">>}]}},
                            {ejectNode, {struct, [{uri, <<"/controller/ejectNode">>}]}},
                            {setAutoCompaction, {struct, [{uri, <<"/controller/setAutoCompaction">>},
                                                          {validateURI, <<"/controller/setAutoCompaction?just_validate=1">>}]}},
                            {replication, {struct, [{createURI, <<"/controller/createReplication">>},
                                                    {replicatorDBURI, <<"/couchBase/_replicator">>},
                                                    {infosURI, <<"/couchBase/_replicator/_design/_replicator_info/_view/infos?group_level=1">>}]}}
                           ]},

    PropList0 = [{name, list_to_binary(Id)},
                 {alerts, Alerts},
                 {nodes, case InfoLevel of
                             stable -> Nodes;
                             _ ->
                                 misc:randomize(),
                                 misc:shuffle(Nodes)
                         end},
                 {buckets, BucketsInfo},
                 {remoteClusters, {struct, [{uri, <<"/pools/default/remoteClusters">>},
                                            {validateURI, <<"/pools/default/remoteClusters?just_validate=1">>}]}},
                 {controllers, Controllers},
                 {balanced, ns_cluster_membership:is_balanced()},
                 {failoverWarnings, ns_bucket:failover_warnings()},
                 {rebalanceStatus, RebalanceStatus},
                 {rebalanceProgressUri, bin_concat_path(["pools", Id, "rebalanceProgress"])},
                 {stopRebalanceUri, <<"/controller/stopRebalance">>},
                 {nodeStatusesUri, <<"/nodeStatuses">>},
                 {autoCompactionSettings, case ns_config:search(Config, autocompaction) of
                                              false ->
                                                  build_auto_compaction_settings([]);
                                              {value, ACSettings} ->
                                                  build_auto_compaction_settings(ACSettings)
                                          end},
                 {stats, {struct,
                          [{uri, bin_concat_path(["pools", Id, "stats"])}]}}],
    PropList =
        case InfoLevel of
            normal ->
                StorageTotals = [ {Key, {struct, StoragePList}}
                  || {Key, StoragePList} <- ns_storage_conf:cluster_storage_info()],
                [{storageTotals, {struct, StorageTotals}} | PropList0];
            _ -> PropList0
        end,

    {struct, PropList}.

build_auto_compaction_settings(Settings) ->
    PropFun = fun ({JSONName, CfgName}) ->
                      case proplists:get_value(CfgName, Settings) of
                          undefined -> [];
                          V -> [{JSONName, V}]
                      end
              end,
    DBAndView = lists:flatmap(PropFun,
                              [{databaseFragmentationThreshold, database_fragmentation_threshold},
                               {viewFragmentationThreshold, view_fragmentation_threshold}]),
    {struct, [{parallelDBAndViewCompaction, proplists:get_bool(parallel_db_and_view_compaction, Settings)}
              | case proplists:get_value(allowed_time_period, Settings) of
                    undefined -> [];
                    V -> [{allowedTimePeriod, build_auto_compaction_allowed_time_period(V)}]
                end] ++ DBAndView}.

build_auto_compaction_allowed_time_period(AllowedTimePeriod) ->
    [{JSONName, proplists:get_value(CfgName, AllowedTimePeriod)}
     || {JSONName, CfgName} <- [{fromHour, from_hour},
                                {toHour, to_hour},
                                {fromMinute, from_minute},
                                {toMinute, to_minute},
                                {abortOutside, abort_outside}]].

build_nodes_info() ->
    F = build_nodes_info_fun(true, normal, "127.0.0.1"),
    [F(N, undefined) || N <- ns_node_disco:nodes_wanted()].

%% builds health/warmup status of given node (w.r.t. given Bucket if
%% not undefined)
build_node_status(Node, Bucket, InfoNode, BucketsAll) ->
    case proplists:get_bool(down, InfoNode) of
        false ->
            ReadyBuckets = proplists:get_value(ready_buckets, InfoNode),
            NodeBucketNames = ns_bucket:node_bucket_names(Node, BucketsAll),
            case Bucket of
                undefined ->
                    case ordsets:is_subset(lists:sort(NodeBucketNames),
                                           lists:sort(ReadyBuckets)) of
                        true ->
                            <<"healthy">>;
                        false ->
                            <<"warmup">>
                    end;
                _ ->
                    case lists:member(Bucket, ReadyBuckets) of
                        true ->
                            <<"healthy">>;
                        false ->
                            case lists:member(Bucket, NodeBucketNames) of
                                true ->
                                    <<"warmup">>;
                                false ->
                                    <<"unhealthy">>
                            end
                    end
            end;
        true ->
            <<"unhealthy">>
    end.

build_nodes_info_fun(IncludeOtp, InfoLevel, LocalAddr) ->
    OtpCookie = list_to_binary(atom_to_list(ns_cookie_manager:cookie_get())),
    NodeStatuses = ns_doctor:get_nodes(),
    Config = ns_config:get(),
    BucketsAll = ns_bucket:get_buckets(Config),
    fun(WantENode, Bucket) ->
            InfoNode = case dict:find(WantENode, NodeStatuses) of
                           {ok, Info} -> Info;
                           error -> [down]
                       end,
            KV = build_node_info(Config, WantENode, InfoNode, LocalAddr),

            Status = build_node_status(WantENode, Bucket, InfoNode, BucketsAll),
            KV1 = [{clusterMembership,
                    atom_to_binary(
                      ns_cluster_membership:get_cluster_membership(
                        WantENode, Config),
                      latin1)},
                   {status, Status}] ++ KV,
            KV2 = case IncludeOtp of
                      true ->
                          [{otpNode,
                            list_to_binary(
                              atom_to_list(WantENode))},
                           {otpCookie, OtpCookie}|KV1];
                      false -> KV1
                  end,
            KV3 = case Bucket of
                      undefined ->
                          case capi_utils:capi_url(WantENode, "/", LocalAddr, Config) of
                              undefined -> KV2;
                              CapiURL ->
                                  [{couchApiBase, list_to_binary(CapiURL)}
                                   | KV2]
                          end;
                      _ ->
                          Replication = proplists:get_value(replication,
                                                            InfoNode, []),
                          KVRep = [{replication, proplists:get_value(Bucket,
                                                                     Replication)}
                                   | KV2],
                          case capi_utils:capi_bucket_url(WantENode, Bucket, LocalAddr, Config) of
                              undefined -> KVRep;
                              CapiBucketUrl ->
                                  [{couchApiBase, list_to_binary(CapiBucketUrl)}
                                   | KVRep]
                          end
                  end,
            KV4 = case InfoLevel of
                      stable -> KV3;
                      normal -> build_extra_node_info(Config, WantENode,
                                                      InfoNode, BucketsAll,
                                                      KV3)
                  end,
            {struct, KV4}
    end.


build_extra_node_info(Config, Node, InfoNode, _BucketsAll, Append) ->

    {UpSecs, {MemoryTotal, MemoryAlloced, _}} =
        {proplists:get_value(wall_clock, InfoNode, 0),
         proplists:get_value(memory_data, InfoNode,
                             {0, 0, undefined})},
    NodesBucketMemoryTotal = case ns_config:search_node_prop(Node,
                                                             Config,
                                                             memcached,
                                                             max_size) of
                                 X when is_integer(X) -> X;
                                 undefined -> (MemoryTotal * 4) div (5 * 1048576)
                             end,
    NodesBucketMemoryAllocated = NodesBucketMemoryTotal,
    [{systemStats, {struct, proplists:get_value(system_stats, InfoNode, [])}},
     {interestingStats, {struct, proplists:get_value(interesting_stats, InfoNode, [])}},
     %% TODO: deprecate this in API (we need 'stable' "startupTStamp"
     %% first)
     {uptime, list_to_binary(integer_to_list(UpSecs))},
     %% TODO: deprecate this in API
     {memoryTotal, erlang:trunc(MemoryTotal)},
     %% TODO: deprecate this in API
     {memoryFree, erlang:trunc(MemoryTotal - MemoryAlloced)},
     %% TODO: deprecate this in API
     {mcdMemoryReserved, erlang:trunc(NodesBucketMemoryTotal)},
     %% TODO: deprecate this in API
     {mcdMemoryAllocated, erlang:trunc(NodesBucketMemoryAllocated)}
     | Append].

build_node_hostname(Config, Node, LocalAddr) ->
    Host = case misc:node_name_host(Node) of
               {_, "127.0.0.1"} -> LocalAddr;
               {_Name, H} -> H
           end,
    Host ++ ":" ++ integer_to_list(misc:node_rest_port(Config, Node)).

build_node_info(Config, WantENode, InfoNode, LocalAddr) ->

    DirectPort = ns_config:search_node_prop(WantENode, Config, memcached, port),
    ProxyPort = ns_config:search_node_prop(WantENode, Config, moxi, port),
    Versions = proplists:get_value(version, InfoNode, []),
    Version = proplists:get_value(ns_server, Versions, "unknown"),
    OS = proplists:get_value(system_arch, InfoNode, "unknown"),
    HostName = build_node_hostname(Config, WantENode, LocalAddr),

    RV = [{hostname, list_to_binary(HostName)},
          {clusterCompatibility, proplists:get_value(cluster_compatibility_version, InfoNode, 0)},
          {version, list_to_binary(Version)},
          {os, list_to_binary(OS)},
          {ports, {struct, [{proxy, ProxyPort},
                            {direct, DirectPort}]}}
         ],
    case WantENode =:= node() of
        true ->
            [{thisNode, true} | RV];
        _ -> RV
    end.

handle_pool_info_streaming(Id, Req) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    LocalAddr = menelaus_util:local_addr(Req),
    F = fun(InfoLevel) -> build_pool_info(Id, UserPassword, InfoLevel, LocalAddr) end,
    handle_streaming(F, Req, undefined).

handle_streaming(F, Req, LastRes) ->
    HTTPRes = Req:ok({"application/json; charset=utf-8",
                      server_header(),
                      chunked}),
    %% Register to get config state change messages.
    menelaus_event:register_watcher(self()),
    Sock = Req:get(socket),
    inet:setopts(Sock, [{active, true}]),
    handle_streaming(F, Req, HTTPRes, LastRes).

streaming_inner(F, HTTPRes, LastRes) ->
    Res = F(stable),
    case Res =:= LastRes of
        true ->
            ok;
        false ->
            ResNormal = F(normal),
            HTTPRes:write_chunk(mochijson2:encode(ResNormal)),
            HTTPRes:write_chunk("\n\n\n\n")
    end,
    Res.

handle_streaming(F, Req, HTTPRes, LastRes) ->
    Res =
        try streaming_inner(F, HTTPRes, LastRes)
        catch exit:normal ->
                ?log_info("closing streaming socket~n", []),
                HTTPRes:write_chunk(""),
                exit(normal)
        end,
    receive
        {notify_watcher, _} -> ok;
        _ ->
            ?log_info("menelaus_web streaming socket closed by client"),
            exit(normal)
    after 25000 ->
        ok
    end,
    handle_streaming(F, Req, HTTPRes, Res).

handle_join(Req) ->
    %% paths:
    %%  cluster secured, admin logged in:
    %%           after creds work and node join happens,
    %%           200 returned with Location header pointing
    %%           to new /pool/default
    %%  cluster not secured, after node join happens,
    %%           a 200 returned with Location header to new /pool/default,
    %%           401 if request had
    %%  cluster either secured or not:
    %%           a 400 with json error message when join fails for whatever reason
    %%
    %% parameter example: clusterMemberHostIp=192%2E168%2E0%2E1&
    %%                    clusterMemberPort=8091&
    %%                    user=admin&password=admin123
    %%
    Params = Req:parse_post(),
    ParsedOtherPort = (catch list_to_integer(proplists:get_value("clusterMemberPort", Params))),
    % the erlang http client crashes if the port number is invalid, so we validate for ourselves here
    NzV = if
              is_integer(ParsedOtherPort) ->
                  if
                      ParsedOtherPort =< 0 -> <<"The port number must be greater than zero.">>;
                      ParsedOtherPort >65535 -> <<"The port number cannot be larger than 65535.">>;
                      true -> undefined
                  end;
              true -> <<"The port number must be a number.">>
          end,
    OtherPort = if
                     NzV =:= undefined -> ParsedOtherPort;
                     true -> 0
                 end,
    OtherHost = proplists:get_value("clusterMemberHostIp", Params),
    OtherUser = proplists:get_value("user", Params),
    OtherPswd = proplists:get_value("password", Params),
    case lists:member(undefined,
                      [OtherHost, OtherPort, OtherUser, OtherPswd]) of
        true  -> ?MENELAUS_WEB_LOG(0013, "Received request to join cluster missing a parameter.", []),
                 Req:respond({400, add_header(), "Attempt to join node to cluster received with missing parameters.\n"});
        false ->
            PossMsg = [NzV],
            Msgs = lists:filter(fun (X) -> X =/= undefined end,
                   PossMsg),
            case Msgs of
                [] ->
                    handle_join_tail(Req, OtherHost, OtherPort, OtherUser, OtherPswd);
                _ -> reply_json(Req, Msgs, 400)
            end
    end.

handle_join_tail(Req, OtherHost, OtherPort, OtherUser, OtherPswd) ->
    process_flag(trap_exit, true),
    {Username, Password} = case ns_config:search_prop(ns_config:get(), rest_creds, creds, []) of
                               [] -> {[], []};
                               [{U, PList} | _] ->
                                   {U, proplists:get_value(password, PList)}
                           end,
    RV = case ns_cluster:check_host_connectivity(OtherHost) of
             {ok, MyIP} ->
                 {struct, MyPList} = build_full_node_info(node(), MyIP),
                 Hostname = misc:expect_prop_value(hostname, MyPList),

                 menelaus_rest:json_request_hilevel(post,
                                                    {OtherHost, OtherPort, "/controller/addNode",
                                                     "application/x-www-form-urlencoded",
                                                     mochiweb_util:urlencode([{<<"hostname">>, Hostname},
                                                                              {<<"user">>, Username},
                                                                              {<<"password">>, Password}])},
                                                    {OtherUser, OtherPswd});
             X -> X
         end,

    case RV of
        {ok, _} -> Req:respond({200, add_header(), []});
        {client_error, JSON} ->
            reply_json(Req, JSON, 400);
        {error, _What, Message, _Nested} ->
            reply_json(Req, [Message], 400)
    end,
    exit(normal).

%% waits till only one node is left in cluster
do_eject_myself_rec(0, _) ->
    exit(self_eject_failed);
do_eject_myself_rec(IterationsLeft, Period) ->
    MySelf = node(),
    case ns_node_disco:nodes_actual_proper() of
        [MySelf] -> ok;
        _ ->
            timer:sleep(Period),
            do_eject_myself_rec(IterationsLeft-1, Period)
    end.

do_eject_myself() ->
    ns_cluster:leave(),
    do_eject_myself_rec(10, 250).

handle_eject_post(Req) ->
    PostArgs = Req:parse_post(),
    %
    % either Eject a running node, or eject a node which is down.
    %
    % request is a urlencoded form with otpNode
    %
    % responses are 200 when complete
    %               401 if creds were not supplied and are required
    %               403 if creds were supplied and are incorrect
    %               400 if the node to be ejected doesn't exist
    %
    OtpNodeStr = case proplists:get_value("otpNode", PostArgs) of
                     undefined -> undefined;
                     "Self" -> atom_to_list(node());
                     X -> X
                 end,
    case OtpNodeStr of
        undefined -> Req:respond({400, add_header(), "Bad Request\n"});
        _ ->
            OtpNode = list_to_atom(OtpNodeStr),
            case ns_cluster_membership:get_cluster_membership(OtpNode) of
                active ->
                    Req:respond({400, add_header(), "Cannot remove active server.\n"});
                _ ->
                    do_handle_eject_post(Req, OtpNode)
            end
    end.

do_handle_eject_post(Req, OtpNode) ->
    case OtpNode =:= node() of
        true ->
            do_eject_myself(),
            Req:respond({200, [], []});
        false ->
            case lists:member(OtpNode, ns_node_disco:nodes_wanted()) of
                true ->
                    ns_cluster:leave(OtpNode),
                    ?MENELAUS_WEB_LOG(?NODE_EJECTED, "Node ejected: ~p from node: ~p",
                                      [OtpNode, erlang:node()]),
                    Req:respond({200, add_header(), []});
                false ->
                                                % Node doesn't exist.
                    ?MENELAUS_WEB_LOG(0018, "Request to eject nonexistant server failed.  Requested node: ~p",
                                      [OtpNode]),
                    Req:respond({400, add_header(), "Server does not exist.\n"})
            end
    end.

handle_pool_settings(_PoolId, Req) ->
    Params = Req:parse_post(),
    Node = node(),
    Results = [case proplists:get_value("memoryQuota", Params) of
                   undefined -> ok;
                   X ->
                       {MinMemoryMB, MaxMemoryMB, QuotaErrorDetailsFun} =
                           ns_storage_conf:allowed_node_quota_range(),
                       case parse_validate_number(X, MinMemoryMB, MaxMemoryMB) of
                           {ok, Number} ->
                               {ok, fun () ->
                                            ok = ns_storage_conf:change_memory_quota(Node, Number)
                                            %% TODO: that should
                                            %% really be a cluster setting
                                    end};
                           invalid -> <<"The RAM Quota value must be a number.">>;
                           too_small ->
                               list_to_binary("The RAM Quota value is too small." ++ QuotaErrorDetailsFun());
                           too_large ->
                               list_to_binary("The RAM Quota value is too large." ++ QuotaErrorDetailsFun())
                       end
               end],
    case lists:filter(fun(ok) -> false;
                         ({ok, _}) -> false;
                         (_) -> true
                      end, Results) of
        [] ->
            lists:foreach(fun ({ok, CommitF}) ->
                                  CommitF();
                              (_) -> ok
                          end, Results),
            Req:respond({200, add_header(), []});
        Errs -> reply_json(Req, Errs, 400)
    end.


handle_settings_web(Req) ->
    reply_json(Req, build_settings_web()).

build_settings_web() ->
    Config = ns_config:get(),
    {U, P} = case ns_config:search_node_prop(Config, rest_creds, creds) of
                 [{User, Auth} | _] ->
                     {User, proplists:get_value(password, Auth, "")};
                 _NoneFound ->
                     {"", ""}
             end,
    Port = proplists:get_value(port, webconfig()),
    build_settings_web(Port, U, P).

build_settings_web(Port, U, P) ->
    {struct, [{port, Port},
              {username, list_to_binary(U)},
              {password, list_to_binary(P)}]}.

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
            Req:respond({400, add_header(),
                         "The value of \"sendStats\" must be true or false."});
        SendStats2 ->
            ns_config:set(settings, [{stats, [{send_stats, SendStats2}]}]),
            Req:respond({200, add_header(), []})
    end.

validate_settings_stats(SendStats) ->
    case SendStats of
        "true" -> true;
        "false" -> false;
        _ -> error
    end.

%% @doc Settings to en-/disable auto-failover
handle_settings_auto_failover(Req) ->
    Config = build_settings_auto_failover(),
    Enabled = proplists:get_value(enabled, Config),
    Timeout = proplists:get_value(timeout, Config),
    Count = proplists:get_value(count, Config),
    reply_json(Req, {struct, [{enabled, Enabled},
                              {timeout, Timeout},
                              {count, Count}]}).

build_settings_auto_failover() ->
    {value, Config} = ns_config:search(ns_config:get(), auto_failover_cfg),
    Config.

handle_settings_auto_failover_post(Req) ->
    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    Enabled = proplists:get_value("enabled", PostArgs),
    Timeout = proplists:get_value("timeout", PostArgs),
    % MaxNodes is hard-coded to 1 for now.
    MaxNodes = "1",
    case {ValidateOnly,
          validate_settings_auto_failover(Enabled, Timeout, MaxNodes)} of
        {false, [true, Timeout2, MaxNodes2]} ->
            auto_failover:enable(Timeout2, MaxNodes2),
            Req:respond({200, add_header(), []});
        {false, false} ->
            auto_failover:disable(),
            Req:respond({200, add_header(), []});
        {false, {error, Errors}} ->
            Errors2 = [<<Msg/binary, "\n">> || {_, Msg} <- Errors],
            Req:respond({400, add_header(), Errors2});
        {true, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 200);
        % Validation only and no errors
        {true, _}->
            reply_json(Req, {struct, [{errors, null}]}, 200)
    end.

validate_settings_auto_failover(Enabled, Timeout, MaxNodes) ->
    Enabled2 = case Enabled of
        "true" -> true;
        "false" -> false;
        _ -> {enabled, <<"The value of \"enabled\" must be true or false">>}
    end,
    case Enabled2 of
        true ->
            Errors = [is_valid_positive_integer_bigger_or_equal(Timeout, ?AUTO_FAILLOVER_MIN_TIMEOUT) orelse
                      {timeout, <<"The value of \"timeout\" must be a positive integer bigger or equal to 30">>},
                      is_valid_positive_integer(MaxNodes) orelse
                      {maxNodes, <<"The value of \"maxNodes\" must be a positive integer">>}],
            case lists:filter(fun (E) -> E =/= true end, Errors) of
                [] ->
                    [Enabled2, list_to_integer(Timeout),
                     list_to_integer(MaxNodes)];
                Errors2 ->
                    {error, Errors2}
             end;
        false ->
            Enabled2;
        Error ->
            {error, [Error]}
    end.

is_valid_positive_integer(String) ->
    Int = (catch list_to_integer(String)),
    (is_integer(Int) andalso (Int > 0)).

is_valid_positive_integer_bigger_or_equal(String, Min) ->
    Int = (catch list_to_integer(String)),
    (is_integer(Int) andalso (Int >= Min)).

%% @doc Resets the number of nodes that were automatically failovered to zero
handle_settings_auto_failover_reset_count(Req) ->
    auto_failover:reset_count(),
    Req:respond({200, add_header(), []}).

%% true iff system is correctly provisioned
is_system_provisioned() ->
    {struct, PList} = build_settings_web(),
    Username = proplists:get_value(username, PList),
    Password = proplists:get_value(password, PList),
    case {binary_to_list(Username), binary_to_list(Password)} of
        {[_|_], [_|_]} -> true;
        _ -> false
    end.

is_valid_port_number("SAME") -> true;
is_valid_port_number(String) ->
    PortNumber = (catch list_to_integer(String)),
    (is_integer(PortNumber) andalso (PortNumber > 0) andalso (PortNumber =< 65535)).

validate_settings(Port, U, P) ->
    case lists:all(fun erlang:is_list/1, [Port, U, P]) of
        false -> [<<"All parameters must be given">>];
        _ -> Candidates = [is_valid_port_number(Port)
                           orelse <<"Port must be a positive integer less than 65536">>,
                           case {U, P} of
                               {[], _} -> <<"Username and password are required.">>;
                               {[_Head | _], P} ->
                                   case length(P) =< 5 of
                                       true -> <<"The password must be at least six characters.">>;
                                       _ -> true
                                   end
                           end],
             lists:filter(fun (E) -> E =/= true end,
                          Candidates)
    end.

%% These represent settings for a cluster.  Node settings should go
%% through the /node URIs
handle_settings_web_post(Req) ->
    PostArgs = Req:parse_post(),
    Port = proplists:get_value("port", PostArgs),
    U = proplists:get_value("username", PostArgs),
    P = proplists:get_value("password", PostArgs),
    case validate_settings(Port, U, P) of
        [_Head | _] = Errors ->
            reply_json(Req, Errors, 400);
        [] ->
            PortInt = case Port of
                         "SAME" -> proplists:get_value(port, webconfig());
                         _      -> list_to_integer(Port)
                      end,
            case build_settings_web() =:= build_settings_web(PortInt, U, P) of
                true -> ok; % No change.
                false ->
                    ns_config:set(rest, [{port, PortInt}]),

                    if
                        {[], []} == {U, P} ->
                            ns_config:set(rest_creds, [{creds, []}]);
                        true ->
                            ns_config:set(rest_creds,
                                          [{creds,
                                            [{U, [{password, P}]}]}])
                    end
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
            reply_json(Req, {struct, [{newBaseUri, list_to_binary("http://" ++ NewHost ++ "/")}]})
    end.

handle_settings_alerts(Req) ->
    {value, Config} = ns_config:search(email_alerts),
    reply_json(Req, {struct, menelaus_alert:build_alerts_json(Config)}).

handle_settings_alerts_post(Req) ->
    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    case {ValidateOnly, menelaus_alert:parse_settings_alerts_post(PostArgs)} of
        {false, {ok, Config}} ->
            ns_config:set(email_alerts, Config),
            Req:respond({200, add_header(), []});
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
    {ok, Config} = menelaus_alert:parse_settings_alerts_post(PostArgs),

    case ns_mail_log:send_email_with_config(Subject, Body, Config) of
        {error, _, {_, _, {error, Reason}}} ->
            reply_json(Req, {struct, [{error, Reason}]}, 400);
        {error, Reason} ->
            reply_json(Req, {struct, [{error, Reason}]}, 400);
        _ ->
            Req:respond({200, add_header(), []})
    end.

-ifdef(EUNIT).

test() ->
    eunit:test({module, ?MODULE},
               [verbose]).

-endif.

-include_lib("kernel/include/file.hrl").

%% Originally from mochiweb_request.erl maybe_serve_file/2
%% and modified to handle user-defined content-type
serve_static_file(Req, {DocRoot, Path}, ContentType, ExtraHeaders) ->
    serve_static_file(Req, filename:join(DocRoot, Path), ContentType, ExtraHeaders);
serve_static_file(Req, File, ContentType, ExtraHeaders) ->
    case file:read_file_info(File) of
        {ok, FileInfo} ->
            LastModified = httpd_util:rfc1123_date(FileInfo#file_info.mtime),
            case Req:get_header_value("if-modified-since") of
                LastModified ->
                    Req:respond({304, ExtraHeaders, ""});
                _ ->
                    case file:open(File, [raw, binary]) of
                        {ok, IoDevice} ->
                            Res = Req:ok({ContentType,
                                          [{"last-modified", LastModified}
                                           | ExtraHeaders],
                                          {file, IoDevice}}),
                            file:close(IoDevice),
                            Res;
                        _ ->
                            Req:not_found(ExtraHeaders)
                    end
            end;
        {error, _} ->
            Req:not_found(ExtraHeaders)
    end.

% too much typing to add this, and I'd rather not hide the response too much
add_header() ->
    menelaus_util:server_header().

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
    Dot = ns_janitor:graphviz(Bucket),
    Req:ok({"text/plain; charset=utf-8",
            server_header(),
            iolist_to_binary(Dot)}).

handle_dotsvg(Bucket, Req) ->
    Dot = ns_janitor:graphviz(Bucket),
    Req:ok({"image/svg+xml", server_header(),
           iolist_to_binary(menelaus_util:insecure_pipe_through_command("dot -Tsvg", Dot))}).

handle_node("self", Req)            -> handle_node("default", node(), Req);
handle_node(S, Req) when is_list(S) -> handle_node("default", list_to_atom(S), Req).

handle_node(_PoolId, Node, Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    case lists:member(Node, ns_node_disco:nodes_wanted()) of
        true ->
            Result = build_full_node_info(Node, LocalAddr),
            reply_json(Req, Result);
        false ->
            reply_json(Req, <<"Node is unknown to this cluster.">>, 404)
    end.

build_full_node_info(Node, LocalAddr) ->
    {struct, KV} = (build_nodes_info_fun(true, normal, LocalAddr))(Node, undefined),
    MemQuota = case ns_storage_conf:memory_quota(Node) of
                   undefined -> <<"">>;
                   Y    -> Y
               end,
    NodeStatus = ns_doctor:get_node(Node),
    StorageConf = ns_storage_conf:storage_conf_from_node_status(NodeStatus),
    R = {struct, storage_conf_to_json(StorageConf)},
    DiskData = proplists:get_value(disk_data, NodeStatus, []),
    Fields = [{availableStorage, {struct, [{hdd, [{struct, [{path, list_to_binary(Path)},
                                                            {sizeKBytes, SizeKBytes},
                                                            {usagePercent, UsagePercent}]}
                                                  || {Path, SizeKBytes, UsagePercent} <- DiskData]}]}},
              {memoryQuota, MemQuota},
              {storageTotals, {struct, [{Type, {struct, PropList}}
                                        || {Type, PropList} <- ns_storage_conf:nodes_storage_info([Node])]}},
              {storage, R}] ++ KV,
    {struct, lists:filter(fun (X) -> X =/= undefined end,
                                   Fields)}.

% S = [{ssd, []},
%      {hdd, [[{path, /some/nice/disk/path}, {quotaMb, 1234}, {state, ok}],
%            [{path, /another/good/disk/path}, {quotaMb, 5678}, {state, ok}]]}].
%
storage_conf_to_json(S) ->
    lists:map(fun ({StorageType, Locations}) -> % StorageType is ssd or hdd.
                  {StorageType, lists:map(fun (LocationPropList) ->
                                              {struct, lists:map(fun location_prop_to_json/1, LocationPropList)}
                                          end,
                                          Locations)}
              end,
              S).

location_prop_to_json({path, L}) -> {path, list_to_binary(L)};
location_prop_to_json({index_path, L}) -> {index_path, list_to_binary(L)};
location_prop_to_json({quotaMb, none}) -> {quotaMb, none};
location_prop_to_json({state, ok}) -> {state, ok};
location_prop_to_json(KV) -> KV.

handle_node_resources_post("self", Req)            -> handle_node_resources_post(node(), Req);
handle_node_resources_post(S, Req) when is_list(S) -> handle_node_resources_post(list_to_atom(S), Req);

handle_node_resources_post(Node, Req) ->
    Params = Req:parse_post(),
    Path = proplists:get_value("path", Params),
    Quota = case proplists:get_value("quota", Params) of
              undefined -> none;
              "none" -> none;
              X      -> list_to_integer(X)
            end,
    Kind = case proplists:get_value("kind", Params) of
              "ssd" -> ssd;
              "hdd" -> hdd;
              _     -> hdd
           end,
    case lists:member(undefined, [Path, Quota, Kind]) of
        true -> Req:respond({400, add_header(), "Insufficient parameters to add storage resources to server."});
        false ->
            case ns_storage_conf:add_storage(Node, Path, Kind, Quota) of
                ok -> Req:respond({200, add_header(), "Added storage location to server."});
                {error, _} -> Req:respond({400, add_header(), "Error while adding storage resource to server."})
            end
    end.

handle_resource_delete("self", Path, Req)            -> handle_resource_delete(node(), Path, Req);
handle_resource_delete(S, Path, Req) when is_list(S) -> handle_resource_delete(list_to_atom(S), Path, Req);

handle_resource_delete(Node, Path, Req) ->
    case ns_storage_conf:remove_storage(Node, Path) of
%%        ok -> Req:respond({204, add_header(), []}); % Commented out to avoid dialyzer warning
        {error, _} -> Req:respond({404, add_header(), "The storage location could not be removed.\r\n"})
    end.

-spec handle_node_settings_post(string() | atom(), any()) -> no_return().
handle_node_settings_post("self", Req)            -> handle_node_settings_post(node(), Req);
handle_node_settings_post(S, Req) when is_list(S) -> handle_node_settings_post(list_to_atom(S), Req);

handle_node_settings_post(Node, Req) ->
    Params = Req:parse_post(),

    DbPath = proplists:get_value("path", Params, []),
    IxPath = proplists:get_value("index_path", Params, DbPath),

    case Node =/= node() of
        true -> exit('Setting the disk storage path for other servers is not yet supported.');
        _ -> ok
    end,

    ValidatePath =
        fun (Path) ->
                case Path of
                    [] -> <<"The database or index path cannot be empty.">>;
                    Path ->
                        case misc:is_absolute_path(Path) of
                           false -> <<"An absolute path is required.">>;
                           _ -> ok
                        end
                end
        end,

    Results0 = lists:usort(lists:map(ValidatePath, [DbPath, IxPath])),
    Results1 =
        case Results0 of
            [ok] ->
                %% NOTE: due to required restart we need to protect
                %% ourselves from 'death signal' of parent
                erlang:process_flag(trap_exit, true),
                case ns_storage_conf:setup_disk_storage_conf(DbPath, IxPath) of
                    ok ->
                        %% performing required restart from
                        %% successfull path change
                        ns_server:restart(),
                        Req:respond({200, add_header(), []}),
                        erlang:exit(normal);
                    {errors, Msgs} -> Msgs
                end;
            _ -> Results0
        end,


    case lists:filter(fun(ok) -> false;
                         (_) -> true
                      end, Results1) of
        [] -> exit(cannot_happen);
        Errs -> reply_json(Req, Errs, 400)
    end.

validate_add_node_params(Hostname, Port, User, Password) ->
    Candidates = case lists:member(undefined, [Hostname, Port, User, Password]) of
                     true -> [<<"Missing required parameter.">>];
                     _ -> [is_valid_port_number(Port) orelse <<"Invalid rest port specified.">>,
                           case Hostname of
                               [] -> <<"Hostname is required.">>;
                               _ -> true
                           end,
                           case {User, Password} of
                               {[], []} -> true;
                               {[_Head | _], [_PasswordHead | _]} -> true;
                               {[], [_PasswordHead | _]} -> <<"If a username is specified, a password must be supplied.">>;
                               _ -> <<"A password must be supplied.">>
                           end]
                 end,
    lists:filter(fun (E) -> E =/= true end, Candidates).

handle_add_node(Req) ->
    %% parameter example: hostname=epsilon.local, user=Administrator, password=asd!23
    Params = Req:parse_post(),
    {Hostname, StringPort} = case proplists:get_value("hostname", Params, "") of
                                 [_ | _] = V ->
                                     case string:tokens(string:strip(V), ":") of
                                         [N] -> {N, "8091"};
                                         [N, P] -> {N, P}
                                     end;
                                 _ -> {"", ""}
                             end,
    User = proplists:get_value("user", Params, ""),
    Password = proplists:get_value("password", Params, ""),
    case validate_add_node_params(Hostname, StringPort, User, Password) of
        [] ->
            Port = list_to_integer(StringPort),
            case ns_cluster:add_node(Hostname, Port, {User, Password}) of
                {ok, OtpNode} ->
                    reply_json(Req, {struct, [{otpNode, OtpNode}]}, 200);
                {error, _What, Message, _Nested} ->
                    reply_json(Req, [Message], 400)
            end;
        ErrorList -> reply_json(Req, ErrorList, 400)
    end.

handle_failover(Req) ->
    Params = Req:parse_post(),
    Node = list_to_atom(proplists:get_value("otpNode", Params, "undefined")),
    case Node of
        undefined ->
            Req:respond({400, add_header(), "No server specified."});
        _ ->
            ns_cluster_membership:failover(Node),
            Req:respond({200, [], []})
    end.

handle_rebalance(Req) ->
    Params = Req:parse_post(),
    case string:tokens(proplists:get_value("knownNodes", Params, ""),",") of
        [] ->
            reply_json(Req, {struct, [{empty_known_nodes, 1}]}, 400);
        KnownNodesS ->
            EjectedNodesS = string:tokens(proplists:get_value("ejectedNodes",
                                                              Params, ""), ","),
            UnknownNodes = [S || S <- EjectedNodesS ++ KnownNodesS,
                                try list_to_existing_atom(S), false
                                catch error:badarg -> true end],
            case UnknownNodes of
                [] ->
                    do_handle_rebalance(Req, KnownNodesS, EjectedNodesS);
                _ ->
                    reply_json(Req,
                               {struct, [{unknownNodes, lists:map(fun list_to_binary/1,
                                                                  UnknownNodes)}]},
                               400)
            end
    end.

-spec do_handle_rebalance(any(), [string()], [string()]) -> any().
do_handle_rebalance(Req, KnownNodesS, EjectedNodesS) ->
    EjectedNodes = [list_to_existing_atom(N) || N <- EjectedNodesS],
    KnownNodes = [list_to_existing_atom(N) || N <- KnownNodesS],
    case ns_cluster_membership:start_rebalance(KnownNodes,
                                               EjectedNodes) of
        already_balanced ->
            Req:respond({200, [], []});
        in_progress ->
            Req:respond({200, [], []});
        nodes_mismatch ->
            reply_json(Req, {struct, [{mismatch, 1}]}, 400);
        no_active_nodes_left ->
            Req:respond({400, [], []});
        ok ->
            Req:respond({200, [], []})
    end.

handle_rebalance_progress(_PoolId, Req) ->
    Status = case ns_cluster_membership:get_rebalance_status() of
                 {running, PerNode} ->
                     [{status, <<"running">>}
                      | [{atom_to_binary(Node, latin1),
                          {struct, [{progress, Progress}]}} || {Node, Progress} <- PerNode]];
                 _ ->
                     case ns_config:search(rebalance_status) of
                         {value, {none, ErrorMessage}} ->
                             [{status, <<"none">>},
                              {errorMessage, iolist_to_binary(ErrorMessage)}];
                         _ -> [{status, <<"none">>}]
                     end
             end,
    reply_json(Req, {struct, Status}, 200).

handle_stop_rebalance(Req) ->
    ns_cluster_membership:stop_rebalance(),
    Req:respond({200, [], []}).

handle_re_add_node(Req) ->
    Params = Req:parse_post(),
    Node = list_to_atom(proplists:get_value("otpNode", Params, "undefined")),
    ok = ns_cluster_membership:re_add_node(Node),
    Req:respond({200, [], []}).

calculate_replication(Node, BucketsAll, BucketsReplications) ->
    ReplicationList = lists:foldl(fun ({BucketName, BucketConfig}, A) ->
                                      case lists:member(Node, ns_bucket:bucket_nodes(BucketConfig)) of
                                          true ->
                                              case proplists:get_value(BucketName, BucketsReplications) of
                                                  undefined -> A;
                                                  Value -> [Value | A]
                                              end;
                                          _ -> A
                                      end
                              end, [], BucketsAll),
    case ReplicationList of
        [] -> 1.0;
        _ -> lists:sum(ReplicationList) / length(ReplicationList)
    end.

%% Node list
%% GET /pools/{PoolID}/buckets/{Id}/nodes
%%
%% Provides a list of nodes for a specific bucket (generally all nodes) with
%% links to stats for that bucket
handle_bucket_node_list(PoolId, BucketName, Req) ->
    menelaus_web_buckets:checking_bucket_access(
      PoolId, BucketName, Req,
      fun (_Pool, BucketPList) ->
              Nodes = menelaus_web_buckets:build_bucket_node_infos(BucketName, BucketPList,
                                                                   stable, menelaus_util:local_addr(Req)),
              Servers =
                  [begin
                       Hostname = proplists:get_value(hostname, N),
                       {struct,
                        [{hostname, Hostname},
                         {uri, bin_concat_path(["pools", "default", "buckets", BucketName, "nodes", Hostname])},
                         {stats, {struct, [{uri,
                                            bin_concat_path(["pools", "default", "buckets", BucketName, "nodes", Hostname, "stats"])}]}}]}
                   end || {struct, N} <- Nodes],
              reply_json(Req, {struct, [{servers, Servers}]})
      end).

checking_bucket_hostname_access(PoolId, BucketName, Hostname, Req, Body) ->
    menelaus_web_buckets:checking_bucket_access(
      PoolId, BucketName, Req,
      fun (_Pool, BucketPList) ->
              Nodes = menelaus_web_buckets:build_bucket_node_infos(BucketName, BucketPList,
                                                                   stable, menelaus_util:local_addr(Req), true),
              BinHostname = list_to_binary(Hostname),
              case lists:filter(fun ({struct, PList}) ->
                                        proplists:get_value(hostname, PList) =:= BinHostname
                                end, Nodes) of
                  [{struct, NodeInfo}] ->
                      Body(Req, BucketPList, NodeInfo);
                  [] ->
                      Req:respond({404, server_header(), "Requested resource not found.\r\n"})
              end
      end).

%% Per-Node Stats URL information
%% GET /pools/{PoolID}/buckets/{Id}/nodes/{NodeId}
%%
%% Provides node hostname and links to the default bucket and node-specific
%% stats for the default bucket
%%
%% TODO: consider what else might be of value here
handle_bucket_node_info(PoolId, BucketName, Hostname, Req) ->
    checking_bucket_hostname_access(
      PoolId, BucketName, Hostname, Req,
      fun (_Req, _BucketPList, _NodeInfo) ->
              BucketURI = bin_concat_path(["pools", "default", "buckets", BucketName]),
              NodeStatsURI = bin_concat_path(["pools", "default", "buckets", BucketName, "nodes", Hostname, "stats"]),
              reply_json(Req,
                         {struct, [{hostname, list_to_binary(Hostname)},
                                   {bucket, {struct, [{uri, BucketURI}]}},
                                   {stats, {struct, [{uri, NodeStatsURI}]}}]})
      end).

%% this serves fresh nodes replication and health status
handle_node_statuses(Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    OldNodeStatuses = ns_doctor:get_nodes(),
    Nodes = ns_node_disco:nodes_actual_proper(),
    Config = ns_config:get(),
    BucketsAll = ns_bucket:get_buckets(Config),
    NodeResp = misc:multicall_result_to_plist(Nodes,
                                              rpc:multicall(Nodes, ns_rebalancer, buckets_replication_statuses, [], 2000)),
    NodeStatuses = lists:map(
                     fun (N) ->
                             InfoNode = case dict:find(N, OldNodeStatuses) of
                                            {ok, Info} -> Info;
                                            _ -> []
                                        end,
                             Hostname = proplists:get_value(hostname,
                                                            build_node_info(Config, N, InfoNode, LocalAddr)),
                             KF = case lists:keyfind(N, 1, NodeResp) of
                                      %% if reply is not list it is error report
                                      {_, Reply} when not is_list(Reply) ->
                                          ?log_info("Got error reply from ~p:~n~p", [N, Reply]),
                                          false;
                                      X -> X
                                  end,
                             V = case KF of
                                     false ->
                                         {struct, [{status, unhealthy},
                                                   {otpNode, N},
                                                   {replication, calculate_replication(N, BucketsAll,
                                                                                       proplists:get_value(replication,
                                                                                                           InfoNode, []))}]};
                                     {_, BucketReplications} ->
                                         {struct, [{status, healthy},
                                                   {otpNode, N},
                                                   {replication, calculate_replication(N, BucketsAll, BucketReplications)}]}
                                 end,
                             {Hostname, V}
                     end, ns_node_disco:nodes_wanted()),
    reply_json(Req, {struct, NodeStatuses}, 200).

bin_concat_path(Path) ->
    list_to_binary(concat_url_path(Path)).

handle_diag_eval(Req) ->
    {value, Value, _} = eshell:eval(binary_to_list(Req:recv_body()), erl_eval:add_binding('Req', Req, erl_eval:new_bindings())),
    case Value of
        done -> ok;
        {json, V} -> reply_json(Req, V, 200);
        _ -> Req:respond({200, [], io_lib:format("~p", [Value])})
    end.

diag_vbucket_accumulate_vbucket_stats(K, V, Dict) ->
    case misc:split_binary_at_char(K, $:) of
        {<<"vb_",VB/binary>>, AttrName} ->
            SubDict = case dict:find(VB, Dict) of
                          error ->
                              dict:new();
                          {ok, X} -> X
                      end,
            dict:store(VB, dict:store(AttrName, V, SubDict), Dict);
        _ ->
            Dict
    end.

diag_vbucket_per_node(BucketName, Node) ->
    {ok, RV1} = ns_memcached:raw_stats(Node, BucketName, <<"hash">>, fun diag_vbucket_accumulate_vbucket_stats/3, dict:new()),
    {ok, RV2} = ns_memcached:raw_stats(Node, BucketName, <<"checkpoint">>, fun diag_vbucket_accumulate_vbucket_stats/3, RV1),
    RV2.

handle_diag_vbuckets(Req) ->
    Params = Req:parse_qs(),
    BucketName = proplists:get_value("bucket", Params),
    {ok, BucketConfig} = ns_bucket:get_bucket(BucketName),
    Nodes = ns_node_disco:nodes_actual_proper(),
    RawPerNode = misc:parallel_map(fun (Node) ->
                                           diag_vbucket_per_node(BucketName, Node)
                                   end, Nodes, 30000),
    PerNodeStates = lists:zip(Nodes,
                              [{struct, [{K, {struct, dict:to_list(V)}} || {K, V} <- dict:to_list(Dict)]}
                               || Dict <- RawPerNode]),
    JSON = {struct, [{name, list_to_binary(BucketName)},
                     {bucketMap, proplists:get_value(map, BucketConfig, [])},
                     %% {ffMap, proplists:get_value(fastForwardMap, BucketConfig, [])},
                     {perNodeStates, {struct, PerNodeStates}}]},
    Hash = integer_to_list(erlang:phash2(JSON)),
    ExtraHeaders = [{"Cache-Control", "must-revalidate"},
                    {"ETag", Hash},
                    {"Server", proplists:get_value("Server", menelaus_util:server_header(), "")}],
    case Req:get_header_value("if-none-match") of
        Hash -> Req:respond({304, ExtraHeaders, []});
        _ ->
            Req:respond({200,
                         [{"Content-Type", "application/json"}
                          | ExtraHeaders],
                         mochijson2:encode(JSON)})
    end.

handle_set_autocompaction(Req) ->
    Params = Req:parse_post(),
    SettingsRV = parse_validate_auto_compaction_settings(Params),
    ValidateOnly = (proplists:get_value("just_validate", Req:parse_qs()) =:= "1"),
    case {ValidateOnly, SettingsRV} of
        {_, {errors, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400);
        {true, {ok, _}} ->
            reply_json(Req, {struct, [{errors, {struct, []}}]}, 200);
        {false, {ok, ACSettings}} ->
            ns_config:set(autocompaction, ACSettings),
            reply_json(Req, [], 200)
    end.

mk_integer_field_validator_error_maker(JSONName, Msg, Args) ->
    [{error, JSONName, iolist_to_binary(io_lib:format(Msg, Args))}].

mk_integer_field_validator(Min, Max, Params) ->
    fun ({JSONName, CfgName, HumanName}) ->
            case proplists:get_value(JSONName, Params) of
                undefined -> [];
                V ->
                    case menelaus_util:parse_validate_number(V, Min, Max) of
                        {ok, IntV} -> [{ok, CfgName, IntV}];
                        invalid ->
                            mk_integer_field_validator_error_maker(JSONName, "~s must be an integer", [HumanName]);
                        too_small ->
                            mk_integer_field_validator_error_maker(JSONName, "~s is too small. Allowed range is ~p - ~p", [HumanName, Min, Max]);
                        too_large ->
                            mk_integer_field_validator_error_maker(JSONName, "~s is too large. Allowed range is ~p - ~p", [HumanName, Min, Max])
                    end
            end
    end.

parse_validate_boolean_field(JSONName, CfgName, Params) ->
    case proplists:get_value(JSONName, Params) of
        undefined -> [];
        "true" -> [{ok, CfgName, true}];
        "false" -> [{ok, CfgName, false}];
        _ -> [{error, JSONName, iolist_to_binary(io_lib:format("~s is invalid", [JSONName]))}]
    end.

parse_validate_auto_compaction_settings(Params) ->
    DBAndViewResults = lists:flatmap(mk_integer_field_validator(30, 100, Params),
                                     [{"databaseFragmentationThreshold", database_fragmentation_threshold, "database fragmentation"},
                                      {"viewFragmentationThreshold", view_fragmentation_threshold, "view fragmentation"}]),
    ParallelResult = case parse_validate_boolean_field("parallelDBAndViewCompaction", parallel_db_and_view_compaction, Params) of
                         [] -> [{error, "parallelDBAndViewCompaction", <<"parallelDBAndViewCompaction is missing">>}];
                         X -> X
                     end,
    PeriodTimeHours = [{"allowedTimePeriod[fromHour]", from_hour, "from hour"},
                       {"allowedTimePeriod[toHour]", to_hour, "to hour"}],
    PeriodTimeMinutes = [{"allowedTimePeriod[fromMinute]", from_minute, "from minute"},
                         {"allowedTimePeriod[toMinute]", to_minute, "to minute"}],
    PeriodTimeFieldsCount = length(PeriodTimeHours) + length(PeriodTimeMinutes) + 1,
    PeriodTimeResults0 = lists:flatmap(mk_integer_field_validator(0, 23, Params), PeriodTimeHours)
        ++ lists:flatmap(mk_integer_field_validator(0, 59, Params), PeriodTimeMinutes)
        ++ parse_validate_boolean_field("allowedTimePeriod[abortOutside]", abort_outside, Params),
    PeriodTimeResults = case length(PeriodTimeResults0) of
                            0 -> PeriodTimeResults0;
                            PeriodTimeFieldsCount -> PeriodTimeResults0;
                            _ -> [{error, <<"allowedTimePeriod">>, <<"allowedTimePeriod is invalid">>}]
                        end,
    Errors = [{iolist_to_binary(Field), Msg} || {error, Field, Msg} <- DBAndViewResults ++ ParallelResult ++ PeriodTimeResults],
    case Errors of
        [] ->
            MainFields = [{F, V} || {ok, F, V} <- ParallelResult ++ DBAndViewResults],
            AllFields =
                case PeriodTimeResults of
                    [] ->
                        MainFields;
                    _ -> [{allowed_time_period, [{F, V} || {ok, F, V} <- PeriodTimeResults]}
                          | MainFields]
                end,
            {ok, AllFields};
        _ -> {errors, Errors}
    end.

parse_validate_bucket_auto_compaction_settings(Params) ->
    case parse_validate_boolean_field("autoCompactionDefined", '_', Params) of
        [] -> nothing;
        [{error, F, V}] -> {errors, [{F, V}]};
        [{ok, _, false}] -> false;
        [{ok, _, true}] ->
            parse_validate_auto_compaction_settings(Params)
    end.
