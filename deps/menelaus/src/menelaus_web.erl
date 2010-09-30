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

-ifdef(EUNIT).
-export([test/0]).
-endif.

-export([start_link/0,
         start_link/1,
         stop/0,
         loop/3,
         webconfig/0,
         restart/0,
         build_nodes_info/4,
         build_nodes_info/5,
         handle_streaming/3,
         is_system_provisioned/0]).

-export([ns_log_cat/1, ns_log_code_string/1, alert_key/1]).

-import(menelaus_util,
        [server_header/0,
         redirect_permanently/2,
         concat_url_path/1,
         reply_json/2,
         reply_json/3,
         get_option/2,
         parse_validate_number/3]).

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
            ns_log:log(?MODULE, ?START_FAIL,
                       "Failed to start web service:  ~p~n", [Other]),
            Other
    end.

stop() ->
    % Note that a supervisor might restart us right away.
    mochiweb_http:stop(?MODULE).

restart() ->
    % Depend on our supervision tree to restart us right away.
    stop().

webconfig() ->
    Ip = case os:getenv("MOCHIWEB_IP") of
             false -> "0.0.0.0";
             Any -> Any
         end,
    Port = case os:getenv("MOCHIWEB_PORT") of
               false -> Config = ns_config:get(),
                        ns_config:search_node_prop(Config, rest, port, 8091);
               P -> list_to_integer(P)
           end,
    WebConfig = [{ip, Ip},
                 {port, Port},
                 {approot, menelaus_deps:local_path(["priv","public"],
                                                    ?MODULE)},
                 {docroot, menelaus_deps:doc_path()}],
    WebConfig.

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
                                 {auth_any_bucket, fun handle_pool_info/2, [Id]};
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
                                 {auth_bucket_with_info, fun menelaus_web_buckets:handle_bucket_info_streaming/5,
                                  [PoolId, Id]};
                             ["pools", PoolId, "buckets", Id, "stats"] ->
                                 {auth_bucket, fun menelaus_stats:handle_bucket_stats/3,
                                  [PoolId, Id]};
                             ["logs"] ->
                                 {auth, fun menelaus_alert:handle_logs/1};
                             ["alerts"] ->
                                 {auth, fun menelaus_alert:handle_alerts/1};
                             ["settings", "web"] ->
                                 {auth, fun handle_settings_web/1};
                             ["settings", "advanced"] ->
                                 {auth, fun handle_settings_advanced/1};
                             ["nodes", NodeId] ->
                                 {auth, fun handle_node/2, [NodeId]};
                             ["diag"] ->
                                 {auth_cookie, fun diag_handler:handle_diag/1};
                             ["pools", PoolId, "rebalanceProgress"] ->
                                 {auth, fun handle_rebalance_progress/2, [PoolId]};
                             ["t", "index.html"] ->
                                 {done, serve_index_html_for_tests(Req, AppRoot)};
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
                             ["erlwsh" | _] ->
                                 {auth_cookie, fun (R) -> erlwsh_web:loop(R, erlwsh_deps:local_path(["priv", "www"])) end};
                             _ ->
                                 {done, Req:serve_file(Path, AppRoot,
                                  [{"Cache-Control", "max-age=30"}])}
                        end;
                     'POST' ->
                         case PathTokens of
                             ["engageCluster"] ->
                                 {auth, fun handle_engage_cluster/1};
                             ["addNodeRequest"] ->
                                 {auth, fun handle_add_node_request/1};
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
                             ["settings", "advanced"] ->
                                 {auth, fun handle_settings_advanced_post/1};
                             ["pools", PoolId] ->
                                 {auth, fun handle_pool_settings/2,
                                  [PoolId]};
                             ["pools", _PoolId, "controller", "testWorkload"] ->
                                 {auth, fun handle_traffic_generator_control_post/1};
                             ["controller", "setupDefaultBucket"] ->
                                 {auth, fun menelaus_web_buckets:handle_setup_default_bucket_post/1};
                             ["controller", "ejectNode"] ->
                                 {auth, fun handle_eject_post/1};
                             ["controller", "addNode"] ->
                                 {auth, fun handle_add_node_if_possible/1};
                             ["controller", "failOver"] ->
                                 {auth, fun handle_failover/1};
                             ["controller", "rebalance"] ->
                                 {auth, fun handle_rebalance/1};
                             ["controller", "reAddNode"] ->
                                 {auth, fun handle_re_add_node/1};
                             ["controller", "stopRebalance"] ->
                                 {auth, fun handle_stop_rebalance/1};
                             ["pools", PoolId, "buckets", Id] ->
                                 {auth_bucket, fun menelaus_web_buckets:handle_bucket_update/3,
                                  [PoolId, Id]};
                             ["pools", PoolId, "buckets"] ->
                                 {auth, fun menelaus_web_buckets:handle_bucket_create/2,
                                  [PoolId]};
                             ["pools", PoolId, "buckets", Id, "controller", "doFlush"] ->
                                 {auth_bucket, fun menelaus_web_buckets:handle_bucket_flush/3,
                                [PoolId, Id]};
                             ["logClientError"] -> {auth_any_bucket,
                                                    fun (R) ->
                                                            User = menelaus_auth:extract_auth(username, R),
                                                            ns_log:log(?MODULE, ?UI_SIDE_ERROR_REPORT,
                                                                       "Client-side error-report for user ~p on node ~p:~nUser-Agent:~s~n~s~n",
                                                                       [User, node(),
                                                                        Req:get_header_value("user-agent"), binary_to_list(R:recv_body())]),
                                                            R:ok({"text/plain", add_header(), <<"">>})
                                                    end};
                             ["erlwsh" | _] ->
                                 {done, erlwsh_web:loop(Req, erlwsh_deps:local_path(["priv", "www"]))};
                             _ ->
                                 ns_log:log(?MODULE, 0001, "Invalid post received: ~p", [Req]),
                                 {done, Req:not_found()}
                      end;
                     'DELETE' ->
                         case PathTokens of
                             ["pools", PoolId, "buckets", Id] ->
                                 {auth, fun menelaus_web_buckets:handle_bucket_delete/3, [PoolId, Id]};
                             ["nodes", Node, "resources", LocationPath] ->
                                 {auth, fun handle_resource_delete/3, [Node, LocationPath]};
                             _ ->
                                 ns_log:log(?MODULE, 0002, "Invalid delete received: ~p as ~p", [Req, PathTokens]),
                                  {done, Req:respond({405, add_header(), "Method Not Allowed"})}
                         end;
                     'PUT' ->
                         case PathTokens of
                             _ ->
                                 ns_log:log(?MODULE, 0003, "Invalid put received: ~p", [Req]),
                                 {done, Req:respond({405, add_header(), "Method Not Allowed"})}
                         end;
                     _ ->
                         ns_log:log(?MODULE, 0004, "Invalid request received: ~p", [Req]),
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
            ns_log:log(?MODULE, 0019, "Server error during processing: ~p", [Report]),
            reply_json(Req, [list_to_binary("Unexpected server error, request logged.")], 500)
    end.


%% Internal API

implementation_version() ->
    list_to_binary(proplists:get_value(menelaus, ns_info:version(), "unknown")).

handle_pools(Req) ->
    reply_json(Req, build_pools()).

handle_engage_cluster(Req) ->
    Params = Req:parse_post(),
    %% a bit kludgy, but 100% correct way to protect ourselves when
    %% everything will restart.
    process_flag(trap_exit, true),
    Ok = case proplists:get_value("MyIP", Params, undefined) of
             undefined ->
                 reply_json(Req, [<<"Missing MyIP parameter">>], 400),
                 failed;
             IP ->
                 case ns_cluster_membership:engage_cluster(IP) of
                     ok -> ok;
                     {error_msg, ErrorMsg} ->
                         reply_json(Req, [list_to_binary(ErrorMsg)] , 400),
                         failed
                 end
         end,
    case Ok of
        ok -> handle_pool_info("default", Req);
        _ -> nothing
    end.

handle_add_node_request(Req) ->
    Params = Req:parse_post(),
    OtpNode = proplists:get_value("otpNode", Params, undefined),
    OtpCookie = proplists:get_value("otpCookie", Params, undefined),
    Reaction = case {OtpNode, OtpCookie} of
                   {undefined, _} ->
                       {errors, [<<"Missing parameter(s)">>]};
                   {_, undefined} ->
                       {errors, [<<"Missing parameter(s)">>]};
                   _ ->
                       erlang:process_flag(trap_exit, true),
                       case ns_cluster_membership:handle_add_node_request(list_to_atom(OtpNode),
                                                                          list_to_atom(OtpCookie)) of
                           ok -> {ok, {struct, [{otpNode, atom_to_binary(node(), latin1)}]}};
                           {error, already_joined} ->
                               {errors, [<<"The server is already part of this cluster.">>]};
                           {error, system_not_addable} ->
                               {errors, [<<"The server is already part of another cluster.  To be added, it cannot be part of an existing cluster.">>]};
                           {error_msg, Msg} -> {errors, [list_to_binary(Msg)]}
                       end
               end,
    case Reaction of
        {ok, Data} ->
            reply_json(Req, Data, 200);
        {errors, Array} ->
            reply_json(Req, Array, 400)
    end.

build_versions() ->
    [{implementationVersion, implementation_version()},
     {componentsVersion, {struct,
                          lists:map(fun ({K,V}) ->
                                            {K, list_to_binary(V)}
                                    end,
                                    ns_info:version())}}].

build_pools() ->
    Pools = [{struct,
             [{name, <<"default">>},
              {uri, list_to_binary(concat_url_path(["pools", "default"]))},
              {streamingUri, list_to_binary(concat_url_path(["poolsStreaming", "default"]))}
             ]}],
    {struct, [{pools, Pools} |
              build_versions()]}.

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

is_healthy(InfoNode) ->
    not proplists:get_bool(down, InfoNode).

build_pool_info(Id, UserPassword, InfoLevel, LocalAddr) ->
    MyPool = fakepool,
    Nodes = build_nodes_info(MyPool, menelaus_auth:check_auth(UserPassword), InfoLevel, LocalAddr),
    BucketsInfo = {struct, [{uri,
                             list_to_binary(concat_url_path(["pools", Id, "buckets"]))}]},
    RebalanceStatus = case ns_cluster_membership:get_rebalance_status() of
                          {running, _ProgressList} -> <<"running">>;
                          _ -> <<"none">>
                      end,
    PropList0 = [{name, list_to_binary(Id)},
                 {nodes, Nodes},
                 {buckets, BucketsInfo},
                 {controllers, {struct,
                                [{addNode, {struct, [{uri, <<"/controller/addNode">>}]}},
                                 {rebalance, {struct, [{uri, <<"/controller/rebalance">>}]}},
                                 {failOver, {struct, [{uri, <<"/controller/failOver">>}]}},
                                 {reAddNode, {struct, [{uri, <<"/controller/reAddNode">>}]}},
                                 {ejectNode, {struct, [{uri, <<"/controller/ejectNode">>}]}},
                                 {testWorkload, {struct,
                                                 [{uri,
                                                   list_to_binary(concat_url_path(["pools", Id, "controller", "testWorkload"]))}]}}]}},
                 {balanced, ns_cluster_membership:is_balanced()},
                 {rebalanceStatus, RebalanceStatus},
                 {rebalanceProgressUri, list_to_binary(concat_url_path(["pools", Id, "rebalanceProgress"]))},
                 {stopRebalanceUri, <<"/controller/stopRebalance">>},
                 {stats, {struct,
                          [{uri,
                            list_to_binary(concat_url_path(["pools", Id, "stats"]))}]}}],
    PropList =
        case InfoLevel of
            normal ->
                [{storageTotals, {struct, [{Key, {struct, StoragePList}}
                                           || {Key, StoragePList} <- ns_storage_conf:cluster_storage_info()]}}
                 | PropList0];
            _ -> PropList0
        end,
    {struct, PropList}.

build_nodes_info(MyPool, IncludeOtp, InfoLevel, LocalAddr) ->
    build_nodes_info(MyPool, IncludeOtp, InfoLevel, LocalAddr,
                     ns_node_disco:nodes_wanted()).

build_nodes_info(MyPool, IncludeOtp, InfoLevel, LocalAddr, WantENodes) ->
    OtpCookie = list_to_binary(atom_to_list(ns_node_disco:cookie_get())),
    NodeStatuses = ns_doctor:get_nodes(),
    %% Don't hit the config server unnecessarily
    BucketsAll = case InfoLevel of
                     stable -> undefined;
                     normal -> ns_bucket:get_buckets()
                 end,
    Nodes =
        lists:map(
          fun(WantENode) ->
                  InfoNode = case dict:find(WantENode, NodeStatuses) of
                                 {ok, Info} -> Info;
                                 error -> [down]
                             end,
                  KV = build_node_info(MyPool, WantENode, InfoNode, LocalAddr),
                  Status = case is_healthy(InfoNode) of
                               true -> <<"healthy">>;
                               false -> <<"unhealthy">>
                           end,
                  KV1 = [{clusterMembership, atom_to_binary(ns_cluster_membership:get_cluster_membership(WantENode),
                                                            latin1)},
                         {status, Status}] ++ KV,
                  KV2 = case IncludeOtp of
                               true ->
                                   KV1 ++ [{otpNode,
                                            list_to_binary(
                                              atom_to_list(WantENode))},
                                           {otpCookie, OtpCookie}];
                               false -> KV1
                        end,
                  KV3 = case InfoLevel of
                            stable -> KV2;
                            normal -> build_extra_node_info(WantENode, InfoNode, BucketsAll, KV2)
                        end,
                  {struct, KV3}
          end,
          WantENodes),
    Nodes.

build_extra_node_info(Node, InfoNode, _BucketsAll, Append) ->
    {UpSecs, {MemoryTotal, MemoryAlloced, _}} =
        {proplists:get_value(wall_clock, InfoNode, 0),
         proplists:get_value(memory_data, InfoNode,
                             {0, 0, undefined})},
    %% TODO: right now size_per_node is not being set/used, so we're
    %% using memory quota instead

    %% NodesBucketMemoryTotal =
    %%     lists:foldl(fun({_BucketName, BucketConfig}, Acc) ->
    %%                         Acc + proplists:get_value(size_per_node,
    %%                                                   BucketConfig, 0)
    %%                 end,
    %%                 0,
    %%                 BucketsAll),
    NodesBucketMemoryTotal = case ns_config:search_node_prop(Node,
                                                             ns_config:get(),
                                                             memcached,
                                                             max_size) of
                                 X when is_integer(X) -> X;
                                 undefined -> (MemoryTotal * 4) div (5 * 1048576)
                             end,
    NodesBucketMemoryAllocated = NodesBucketMemoryTotal,
    [{uptime, list_to_binary(integer_to_list(UpSecs))},
     {memoryTotal, erlang:trunc(MemoryTotal)},
     {memoryFree, erlang:trunc(MemoryTotal - MemoryAlloced)},
     {mcdMemoryReserved, erlang:trunc(NodesBucketMemoryTotal)},
     {mcdMemoryAllocated, erlang:trunc(NodesBucketMemoryAllocated)}
     | Append].

get_node_info(WantENode) ->
    NodeStatuses = ns_doctor:get_nodes(),
    case dict:find(WantENode, NodeStatuses) of
        {ok, Info} -> Info;
        error -> [stale]
    end.

build_node_info(_MyPool, WantENode, InfoNode, LocalAddr) ->
    Host = case misc:node_name_host(WantENode) of
               {_, "127.0.0.1"} -> LocalAddr;
               {_Name, H} -> H
           end,
    Config = ns_config:get(),
    DirectPort = ns_config:search_node_prop(WantENode, Config, memcached, port),
    ProxyPort = ns_config:search_node_prop(WantENode, Config, moxi, port),
    Versions = proplists:get_value(version, InfoNode, []),
    Version = proplists:get_value(ns_server, Versions, "unknown"),
    OS = proplists:get_value(system_arch, InfoNode, "unknown"),
    HostName = Host ++ ":" ++
               integer_to_list(ns_config:search_node_prop(WantENode, Config,
                                                          rest, port, 8091)),
    V = [{hostname, list_to_binary(HostName)},
         {version, list_to_binary(Version)},
         {os, list_to_binary(OS)},
         {ports, {struct, [{proxy, ProxyPort},
                           {direct, DirectPort}]}}],
    V.

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

handle_streaming(F, Req, HTTPRes, LastRes) ->
    Res = F(stable),
    case Res =:= LastRes of
        true ->
            ok;
        false ->
            ResNormal = F(normal),
            HTTPRes:write_chunk(mochijson2:encode(ResNormal)),
            HTTPRes:write_chunk("\n\n\n\n")
    end,
    receive
        {notify_watcher, _} -> ok;
        _ ->
            error_logger:info_msg("menelaus_web streaming socket closed by client~n"),
            exit(normal)
    after 5000 ->
        ok
    end,
    handle_streaming(F, Req, HTTPRes, Res).

handle_join(Req) ->
    %% paths:
    %%  cluster secured, admin logged in:
    %%           after creds work and node join happens,
    %%           200 returned with Location header pointing
    %%           to new /pool/default
    %%  cluster secured, bucket creds and logged in: 403 Forbidden
    %%  cluster not secured, after node join happens,
    %%           a 200 returned with Location header to new /pool/default,
    %%           401 if request had
    %%  cluster either secured or not:
    %%           a 400 if a required parameter is missing
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
        true  -> ns_log:log(?MODULE, 0013, "Received request to join cluster missing a parameter.", []),
                 Req:respond({400, add_header(), "Attempt to join node to cluster received with missing parameters.\n"});
        false ->
            PossMsg = [NzV],
            Msgs = lists:filter(fun (X) -> X =/= undefined end,
                   PossMsg),
            case Msgs of
                [] -> case ns_cluster_membership:join_cluster(OtherHost, OtherPort, OtherUser, OtherPswd) of
                          ok ->
                              Req:respond({200, add_header(), []});
                          {error, Errors} ->
                              reply_json(Req, Errors, 400);
                          {internal_error, Errors} ->
                              reply_json(Req, Errors, 500)
                      end;
                _ -> reply_json(Req, Msgs, 400)
            end
    end.

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
    case proplists:get_value("otpNode", PostArgs) of
        undefined -> Req:respond({400, add_header(), "Bad Request\n"});
        "Self" -> do_eject_myself(),
                  Req:respond({200, [], []});
        OtpNodeStr ->
            OtpNode = list_to_atom(OtpNodeStr),
            case OtpNode =:= node() of
                true ->
                    do_eject_myself(),
                    Req:respond({200, [], []});
                false ->
                    case lists:member(OtpNode, ns_node_disco:nodes_wanted()) of
                        true ->
                            ns_cluster:leave(OtpNode),
                            ns_log:log(?MODULE, ?NODE_EJECTED, "Node ejected: ~p from node: ~p",
                                       [OtpNode, erlang:node()]),
                            Req:respond({200, add_header(), []});
                        false ->
                            % Node doesn't exist.
                            ns_log:log(?MODULE, 0018, "Request to eject nonexistant server failed.  Requested node: ~p",
                                       [OtpNode]),
                            Req:respond({400, add_header(), "Server does not exist.\n"})
                    end
            end
    end.

handle_pool_settings(_PoolId, Req) ->
    Params = Req:parse_post(),
    Node = node(),
    Results = [case proplists:get_value("memoryQuota", Params) of
                   undefined -> ok;
                   X ->
                       case length(ns_node_disco:nodes_wanted()) of
                           1 -> ok;
                           _ -> exit('Changing the memory quota of a cluster is not yet supported.')
                       end,
                       {MaxMemoryBytes0, _, _} = memsup:get_memory_data(),
                       MiB = 1048576,
                       MinMemoryMB = 256,
                       MaxMemoryMBPercent = (MaxMemoryBytes0 * 4) div (5 * MiB),
                       MaxMemoryMB = lists:max([(MaxMemoryBytes0 div MiB) - 512,
                                                MaxMemoryMBPercent]),
                       MemoryMaxString = case MaxMemoryMB of
                                             MaxMemoryMBPercent ->
                                                 " Quota must be between 256 MB and ~w MB (80% of memory size).";
                                             _ ->
                                                 " Quota must be between 256 MB and ~w MB (memory size minus 512 MB)."
                                         end,
                       case parse_validate_number(X, MinMemoryMB, MaxMemoryMB) of
                           {ok, Number} ->
                               {ok, fun () ->
                                            ok = ns_storage_conf:change_memory_quota(Node, Number)
                                            %% TODO: that should
                                            %% really be a cluster setting
                                    end};
                           invalid -> <<"The RAM Quota value must be a number.">>;
                           too_small ->
                               list_to_binary(io_lib:format("The RAM Quota value is too small."
                                                            ++ MemoryMaxString, [MaxMemoryMB]));
                           too_large ->
                               list_to_binary(io_lib:format("The RAM Quota value is too large."
                                                            ++ MemoryMaxString, [MaxMemoryMB]))

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
                    ns_config:set(rest,
                                  [{port, PortInt}]),
                    if
                        {[], []} == {U, P} ->
                            ns_config:set(rest_creds, [{creds, []}]);
                        true ->
                            ns_config:set(rest_creds,
                                          [{creds,
                                            [{U, [{password, P}]}]}])
                    end
                    % No need to restart right here, as our ns_config
                    % event watcher will do it later if necessary.
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

handle_settings_advanced(Req) ->
    reply_json(Req, {struct,
                     [{alerts,
                       {struct, menelaus_alert:build_alerts_settings()}},
                      {ports,
                       {struct, build_port_settings("default")}}
                      ]}).

handle_settings_advanced_post(Req) ->
    PostArgs = Req:parse_post(),
    Results = [menelaus_alert:handle_alerts_settings_post(PostArgs),
               handle_port_settings_post(PostArgs, "default")],
    case proplists:get_all_values(errors, Results) of
        [] -> %% no errors
            CommitFunctions = proplists:get_all_values(ok, Results),
            lists:foreach(fun (F) -> apply(F, []) end,
                          CommitFunctions),
            Req:respond({200, add_header(), []});
        [Head | RestErrors] ->
            Errors = lists:foldl(fun (A, B) -> A ++ B end,
                                 Head,
                                 RestErrors),
            reply_json(Req, Errors, 400)
    end.

build_port_settings(_PoolId) ->
    Config = ns_config:get(),
    [{proxyPort, ns_config:search_node_prop(Config, moxi, port)},
     {directPort, ns_config:search_node_prop(Config, memcached, port)}].

validate_port_settings(ProxyPort, DirectPort) ->
    CS = [is_valid_port_number(ProxyPort) orelse <<"Proxy port must be a positive integer less than 65536">>,
          is_valid_port_number(DirectPort) orelse <<"Direct port must be a positive integer less than 65536">>],
    lists:filter(fun (C) -> C =/= true end,
                 CS).

handle_port_settings_post(PostArgs, _PoolId) ->
    PPort = proplists:get_value("proxyPort", PostArgs),
    DPort = proplists:get_value("directPort", PostArgs),
    case validate_port_settings(PPort, DPort) of
        % TODO: this should change the config
        [] -> {ok, ok};
        Errors -> {errors, Errors}
    end.

handle_traffic_generator_control_post(Req) ->
    % TODO: rip traffic generation the hell out.
    Req:respond({400, add_header(), "Bad Request\n"}).


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

serve_index_html_for_tests(Req, DocRoot) ->
    case file:read_file(DocRoot ++ "/index.html") of
        {ok, Data} ->
            StringData = re:replace(binary_to_list(Data),
                                    "js/all.js\"", "js/t-all.js\""),
            Req:ok({"text/html", list_to_binary(StringData)});
        _ -> {Req:not_found()}
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
    MyPool = fakepool,
    LocalAddr = menelaus_util:local_addr(Req),
    case lists:member(Node, ns_node_disco:nodes_wanted()) of
        true ->
            InfoNode = get_node_info(Node),
            KV = build_extra_node_info(Node, InfoNode, ns_bucket:get_buckets(),
                                       build_node_info(MyPool, Node, InfoNode, LocalAddr)),
            MemQuota = case ns_storage_conf:memory_quota(Node) of
                           undefined -> <<"">>;
                           Y    -> Y
                       end,
            StorageConf = ns_storage_conf:storage_conf(Node),
            R = {struct, storage_conf_to_json(StorageConf)},
            Fields = [{availableStorage, {struct, [{hdd, [{struct, [{path, list_to_binary(Path)},
                                                                    {sizeKBytes, SizeKBytes},
                                                                    {usagePercent, UsagePercent}]}
                                                          || {Path, SizeKBytes, UsagePercent} <- disksup:get_disk_data()]}]}},
                      {memoryQuota, MemQuota},
                      {storageTotals, {struct, [{Type, {struct, PropList}}
                                                || {Type, PropList} <- ns_storage_conf:nodes_storage_info([Node])]}},
                      {storage, R}] ++ KV,
            reply_json(Req,
                       {struct, lists:filter(fun (X) -> X =/= undefined end,
                                             Fields)});
        false ->
            reply_json(Req, <<"Node is unknown to this cluster.">>, 404)
    end.

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
        ok -> Req:respond({204, add_header(), []});
        {error, _} -> Req:respond({404, add_header(), "The storage location could not be removed.\r\n"})
    end.

handle_node_settings_post("self", Req)            -> handle_node_settings_post(node(), Req);
handle_node_settings_post(S, Req) when is_list(S) -> handle_node_settings_post(list_to_atom(S), Req);

handle_node_settings_post(Node, Req) ->
    %% parameter example: license=some_license_string, memoryQuota=NumInMb
    %%
    Params = Req:parse_post(),
    Results = [case proplists:get_value("path", Params) of
                   undefined -> ok;
                   [] -> <<"The database path cannot be empty.">>;
                   Path ->
                       case misc:is_absolute_path(Path) of
                           false -> <<"An absolute path is required.">>;
                           _ ->
                               case Node =/= node() of
                                   true -> exit('Setting the disk storage path for other servers is not yet supported.');
                                   _ -> ok
                               end,
                               case ns_storage_conf:prepare_setup_disk_storage_conf(node(), Path) of
                                   {ok, _} = R -> R;
                                   ok -> ok;
                                   error -> <<"Could not set the storage path. It must be a directory writable by 'membase' user.">>
                               end
                       end
               end
              ],
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

handle_add_node_if_possible(Req) ->
    case is_system_provisioned() of
        false ->
            reply_json(Req, [<<"Cannot add servers to a cluster which has not been fully configured.">>], 400);
        _ ->
            handle_add_node(Req)
    end.

handle_add_node(Req) ->
    %% parameter example: hostname=epsilon.local, user=Administrator, password=asd!23
    Params = Req:parse_post(),
    {Hostname, StringPort} = case proplists:get_value("hostname", Params, "") of
                                 [_ | _] = V ->
                                     case string:tokens(V, ":") of
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
            process_flag(trap_exit, true),
            case ns_cluster_membership:add_node(Hostname, Port, User, Password) of
                {ok, OtpNode} ->
                    case misc:poll_for_condition(fun () ->
                                                         lists:member(OtpNode, [node() | nodes()])
                                                 end,
                                                 2000, 100) of
                        ok ->
                            timer:sleep(2000), %% and wait a bit more for things to settle
                            Req:respond({200, [], []});
                        timeout ->
                            reply_json(Req, [<<"Wait for join completion has timed out">>], 400)
                    end;
                {error, Error} -> reply_json(Req, Error, 400)
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
    KnownNodesS = string:tokens(proplists:get_value("knownNodes", Params, ""),","),
    EjectedNodesS = string:tokens(proplists:get_value("ejectedNodes", Params, ""), ","),
    KnownNodes = [list_to_atom(N) || N <- KnownNodesS],
    EjectedNodes = [list_to_atom(N) || N <- EjectedNodesS],
    case ns_cluster_membership:start_rebalance(KnownNodes, EjectedNodes) of
        already_balanced ->
            Req:respond({200, [], []});
        in_progress ->
            Req:respond({200, [], []});
        nodes_mismatch ->
            reply_json(Req, {struct, [{mismatch, 1}]}, 400);
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
