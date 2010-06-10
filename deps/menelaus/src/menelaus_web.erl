%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_web).
-author('NorthScale <info@northscale.com>').

% -behavior(ns_log_categorizing).
% the above is commented out because of the way the project is structured

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test/0]).
-import(menelaus_util,
        [test_under_debugger/0, debugger_apply/2, concat_url_path/1,
         wrap_tests_with_cache_setup/1]).
-endif.

-export([start_link/0, start_link/1, stop/0, loop/3, webconfig/0, restart/0,
         find_pool_by_id/1, all_accessible_buckets/2,
         find_bucket_by_id/2]).

-export([ns_log_cat/1, ns_log_code_string/1, alert_key/1]).

-export([do_diag_per_node/0]).

-import(menelaus_util,
        [server_header/0,
         redirect_permanently/2,
         reply_json/2,
         reply_json/3,
         parse_json/1,
         expect_config/1,
         expect_prop_value/2,
         get_option/2,
         direct_port/1]).

-import(ns_license, [license/1, change_license/2]).

%% The range used within this file is arbitrary and undefined, so I'm
%% defining an arbitrary value here just to be rebellious.
-define(BUCKET_DELETED, 11).
-define(BUCKET_CREATED, 12).
-define(START_FAIL, 100).
-define(NODE_EJECTED, 101).
-define(UI_SIDE_ERROR_REPORT, 102).
-define(INIT_STATUS_BAD_PARAM, 103).
-define(INIT_STATUS_UPDATED, 104).

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

get_node_rest_port(Config, Node, node_specific) ->
    ns_config:search_prop(Config,
                          {node, Node, rest},
                          port, false).

get_node_rest_port(Node) ->
    Config = ns_config:get(),
    case get_node_rest_port(Config, Node, node_specific) of
        false ->
            ns_config:search_prop(Config, rest, port, 8080);
        P -> P
    end.

webconfig() ->
    Ip = case os:getenv("MOCHIWEB_IP") of
             false -> "0.0.0.0";
             Any -> Any
         end,
    Port = case os:getenv("MOCHIWEB_PORT") of
               false -> get_node_rest_port(node());
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
                             ["poolsStreaming", Id] ->
                                 {auth_any_bucket, fun handle_pool_info_streaming/2, [Id]};
                             ["pools", PoolId, "buckets"] ->
                                 {auth_any_bucket, fun handle_bucket_list/2, [PoolId]};
                             ["pools", PoolId, "buckets", Id] ->
                                 {auth_bucket_with_info, fun handle_bucket_info/5,
                                  [PoolId, Id]};
                             ["pools", PoolId, "bucketsStreaming", Id] ->
                                 {auth_bucket_with_info, fun handle_bucket_info_streaming/5,
                                  [PoolId, Id]};
                             ["pools", PoolId, "bucketsStreamingConfig", Id] ->
                                 {auth_bucket_with_info, fun handle_bucket_info_streaming_config/5,
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
                                 {auth, fun handle_diag/1};
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
                             _ ->
                                 {done, Req:serve_file(Path, AppRoot)}%% , [{"Pragma", "no-cache"},
                                                                      %%  {"Cache-Control", "no-cache must-revalidate"}])}
                        end;
                     'POST' ->
                         case PathTokens of
                             ["engageCluster"] ->
                                 {auth, fun handle_engage_cluster/1};
                             ["addNodeRequest"] ->
                                 {auth, fun handle_add_node_request/1};
                             ["node", "controller", "doJoinCluster"] ->
                                 {auth, fun handle_join/1};
                             ["node", "controller", "initStatus"] ->
                                 {auth, fun handle_init_status_post/1};
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
                             ["pools", _PoolId] ->
                                 {done, Req:respond({405, add_header(), ""})};
                             ["pools", _PoolId, "controller", "testWorkload"] ->
                                 {auth, fun handle_traffic_generator_control_post/1};
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
                             ["pools", PoolId, "buckets", Id] ->
                                 {auth_bucket, fun handle_bucket_update/3,
                                  [PoolId, Id]};
                             ["pools", PoolId, "buckets"] ->
                                 {auth, fun handle_bucket_update/2,
                                  [PoolId]};
                             ["pools", PoolId, "buckets", Id, "controller", "doFlush"] ->
                                 {auth_bucket, fun handle_bucket_flush/3,
                                [PoolId, Id]};
                             ["logClientError"] -> {auth_any_bucket,
                                                    fun (R) ->
                                                            User = menelaus_auth:extract_auth(username, R),
                                                            ns_log:log(?MODULE, ?UI_SIDE_ERROR_REPORT, "Client-side error-report for user ~p on node ~p: ~p~n",
                                                                       [User, node(), binary_to_list(R:recv_body())]),
                                                            R:ok({"text/plain", add_header(), <<"">>})
                                                    end};
                             _ ->
                                 ns_log:log(?MODULE, 0001, "Invalid post received: ~p", [Req]),
                                 {done, Req:not_found()}
                      end;
                     'DELETE' ->
                         case PathTokens of
                             ["pools", PoolId, "buckets", Id] ->
                                 {auth, fun handle_bucket_delete/3, [PoolId, Id]};
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
            {auth, F} -> menelaus_auth:apply_auth(Req, F, []);
            {auth, F, Args} -> menelaus_auth:apply_auth(Req, F, Args);
            {auth_bucket_with_info, F, [ArgPoolId, ArgBucketId | RestArgs]} ->
                checking_bucket_access(ArgPoolId, ArgBucketId, Req,
                                       fun (Pool, Bucket) ->
                                               apply(F, [ArgPoolId, ArgBucketId] ++ RestArgs ++ [Req, Pool, Bucket])
                                       end);
            {auth_bucket, F, [ArgPoolId, ArgBucketId | RestArgs]} ->
                checking_bucket_access(ArgPoolId, ArgBucketId, Req,
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
    Pools = lists:map(fun ({Name, _}) ->
                              {struct,
                               [{name, list_to_binary(Name)},
                                {uri, list_to_binary(concat_url_path(["pools", Name]))},
                                {streamingUri,
                                 list_to_binary(concat_url_path(["poolsStreaming", Name]))}]}
                      end,
                      expect_config(pools)),
    Config = ns_config:get(),
    {struct, [{pools, Pools},
              {initStatus, list_to_binary(ns_config:search_prop(Config, init_status, value, ""))} |
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
    reply_json(Req, build_pool_info(Id, UserPassword)).

is_healthy(InfoNode) ->
    not proplists:get_bool(stale, InfoNode) and
        proplists:get_bool(memcached_running, InfoNode).

build_pool_info(Id, UserPassword) ->
    build_pool_info(Id, UserPassword, normal).

build_pool_info(Id, _UserPassword, InfoLevel) ->
    MyPool = find_pool_by_id(Id),
    Nodes = build_nodes_info(MyPool, true, InfoLevel),
    BucketsInfo = {struct, [{uri,
                             list_to_binary(concat_url_path(["pools", Id, "buckets"]))}]},
    RebalanceStatus = case ns_cluster_membership:get_rebalance_status() of
                          {running, _ProgressList} -> <<"running">>;
                          _ -> <<"none">>
                      end,
    {struct, [{name, list_to_binary(Id)},
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
                         list_to_binary(concat_url_path(["pools", Id, "stats"]))}]}}]}.

find_pool_by_id(Id) -> expect_prop_value(Id, expect_config(pools)).

find_pool_by_id_with_default(Id, Default) -> proplists:get_value(Id, expect_config(pools), Default).

build_nodes_info(MyPool, IncludeOtp) ->
    build_nodes_info(MyPool, IncludeOtp, normal).

build_nodes_info(MyPool, IncludeOtp, InfoLevel) ->
    OtpCookie = list_to_binary(atom_to_list(ns_node_disco:cookie_get())),
    WantENodes = ns_node_disco:nodes_wanted(),
    NodeStatuses = ns_doctor:get_nodes(),
    Nodes =
        lists:map(
          fun(WantENode) ->
                  InfoNode = case dict:find(WantENode, NodeStatuses) of
                                 {ok, Info} -> Info;
                                 error -> [stale]
                             end,
                  KV = build_node_info(MyPool, WantENode, InfoNode),
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
                            normal ->
                                BucketsAll = expect_prop_value(buckets, MyPool),
                                NodesBucketMemoryTotal =
                                    length(WantENodes) *
                                    lists:foldl(fun({_BucketName, BucketConfig}, Acc) ->
                                                        Acc + proplists:get_value(size_per_node,
                                                                                  BucketConfig, 0)
                                                end,
                                                0,
                                                BucketsAll),
                                NodesBucketMemoryAllocated = 0,
                                {UpSecs, {MemoryTotal, MemoryAlloced, _}} =
                                    {proplists:get_value(wall_clock, InfoNode, 0),
                                     proplists:get_value(memory_data, InfoNode,
                                                         {0, 0, undefined})},
                                KV2 ++ [{uptime, list_to_binary(integer_to_list(UpSecs))},
                                        {memoryTotal, erlang:trunc(MemoryTotal)},
                                        {memoryFree, erlang:trunc(MemoryTotal - MemoryAlloced)},
                                        {mcdMemoryReserved, erlang:trunc(NodesBucketMemoryTotal)},
                                        {mcdMemoryAllocated, erlang:trunc(NodesBucketMemoryAllocated)}]
                        end,
                  {struct, KV3}
          end,
          WantENodes),
    Nodes.

build_node_info(MyPool, WantENode) ->
    NodeStatuses = ns_doctor:get_nodes(),
    InfoNode = case dict:find(WantENode, NodeStatuses) of
                   {ok, Info} -> Info;
                   error -> [stale]
               end,
    build_node_info(MyPool, WantENode, InfoNode).

build_node_info(MyPool, WantENode, InfoNode) ->
    {_Name, Host} = misc:node_name_host(WantENode),
    {value, DirectPort} = direct_port(WantENode),
    ProxyPort = pool_proxy_port(MyPool, WantENode),
    Versions = proplists:get_value(version, InfoNode, []),
    Version = proplists:get_value(ns_server, Versions, "unknown"),
    OS = proplists:get_value(system_arch, InfoNode, "unknown"),
    HostName = case get_node_rest_port(ns_config:get(), WantENode, node_specific) of
                   false -> Host;
                   Port -> Host ++ ":" ++ integer_to_list(Port)
               end,
    V = [{hostname, list_to_binary(HostName)},
         {version, list_to_binary(Version)},
         {os, list_to_binary(OS)},
         {ports, {struct, [{proxy, ProxyPort},
                           {direct, DirectPort}]}}],
    V.

pool_proxy_port(PoolConfig, Node) ->
    case proplists:get_value({node, Node, port}, PoolConfig, false) of
        false -> expect_prop_value(port, PoolConfig);
        Port  -> Port
    end.

handle_pool_info_streaming(Id, Req) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    F = fun(InfoLevel) -> build_pool_info(Id, UserPassword, InfoLevel) end,
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
        true -> ok;
        false ->
            ResNormal = F(normal),
            error_logger:info_msg("menelaus_web streaming: ~p~n",
                                  [ResNormal]),
            HTTPRes:write_chunk(mochijson2:encode(ResNormal)),
            %% TODO: resolve why mochiweb doesn't support zero chunk... this
            %%       indicates the end of a response for now
            HTTPRes:write_chunk("\n\n\n\n")
    end,
    receive
        {notify_watcher, _} -> ok;
        _ ->
            error_logger:info_msg("menelaus_web streaming socket closed~n"),
            exit(normal)
    end,
    handle_streaming(F, Req, HTTPRes, Res).

all_accessible_buckets(PoolId, Req) ->
    Pool = find_pool_by_id(PoolId),
    all_accessible_buckets_in_pool(Pool, Req).

all_accessible_buckets_in_pool(Pool, Req) ->
    BucketsAll = expect_prop_value(buckets, Pool),
    menelaus_auth:filter_accessible_buckets(BucketsAll, Req).

checking_bucket_access(PoolId, Id, Req, Body) ->
    E404 = make_ref(),
    try
        {Pool, Bucket} = case find_pool_by_id_with_default(PoolId, undefined) of
                             undefined -> exit(E404);
                             PoolC -> case find_bucket_by_id_with_default(PoolC, Id, undefined) of
                                          undefined -> exit(E404);
                                          BucketC -> {PoolC, BucketC}
                                      end
                         end,
        case menelaus_auth:is_bucket_accessible({Id, Bucket}, Req) of
            true -> apply(Body, [Pool, Bucket]);
            _ -> menelaus_auth:require_auth(Req)
        end
    catch
        exit:E404 ->
            Req:respond({404, add_header(), "Requested resource not found.\r\n"})
    end.

handle_bucket_list(Id, Req) ->
    Pool = find_pool_by_id(Id),
    Buckets = lists:sort(fun (A,B) -> element(1, A) =< element(1, B) end,
                         all_accessible_buckets_in_pool(Pool, Req)),
    BucketsInfo = [build_bucket_info(Id, Name, Pool)
                   || {Name, _} <- Buckets],
    reply_json(Req, BucketsInfo).

find_bucket_by_id(Pool, Id) ->
    Buckets = expect_prop_value(buckets, Pool),
    expect_prop_value(Id, Buckets).

find_bucket_by_id_with_default(Pool, Id, Default) ->
    Buckets = expect_prop_value(buckets, Pool),
    proplists:get_value(Id, Buckets, Default).

handle_bucket_info(PoolId, Id, Req, Pool, _Bucket) ->
    reply_json(Req, build_bucket_info(PoolId, Id, Pool)).

build_bucket_info(PoolId, Id, Pool) ->
    build_bucket_info(PoolId, Id, Pool, normal).

build_bucket_info(PoolId, Id, Pool, InfoLevel) ->
    StatsUri = list_to_binary(concat_url_path(["pools", PoolId, "buckets", Id, "stats"])),
    Nodes = build_nodes_info(Pool, false, InfoLevel),
    List1 = [{name, list_to_binary(Id)},
             {uri, list_to_binary(concat_url_path(["pools", PoolId, "buckets", Id]))},
             {streamingUri, list_to_binary(concat_url_path(["pools", PoolId, "bucketsStreaming", Id]))},
             %% TODO: this should be under a controllers/ kind of namespacing
             {flushCacheUri, list_to_binary(concat_url_path(["pools", PoolId,
                                                             "buckets", Id, "controller", "doFlush"]))},
             {nodes, Nodes},
             {stats, {struct, [{uri, StatsUri}]}},
             %% TODO: placeholder for a real vBucketServerMap.
             {vBucketServerMap, vbucket_map_to_json(vbucket_map(PoolId, Id))}],
    List2 = case InfoLevel of
                stable -> List1;
                normal -> List1 ++ [{basicStats, {struct, menelaus_stats:basic_stats(PoolId, Id)}}]
            end,
    {struct, List2}.

handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket) ->
    handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket, undefined).

handle_bucket_info_streaming_config(PoolId, Id, Req, Pool, _Bucket) ->
    handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket, stable).

handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket, ForceInfoLevel) ->
    F = fun(InfoLevel) ->
                case ForceInfoLevel of
                    undefined -> build_bucket_info(PoolId, Id, Pool, InfoLevel);
                    _         -> build_bucket_info(PoolId, Id, Pool, ForceInfoLevel)
                end
        end,
    handle_streaming(F, Req, undefined).

handle_bucket_delete(_PoolId, _BucketId, Req) ->
    %% We don't currently allow deleting buckets.
    Req:respond({404, add_header(), "The bucket to be deleted was not found.\r\n"}),
    ok.

handle_bucket_update(_PoolId, _BucketId, Req) ->
    Req:respond({404, add_header(), "The bucket to be updated was not found.\r\n"}),
    ok.

handle_bucket_update(PoolId, Req) ->
    PostArgs = Req:parse_post(),
    case proplists:get_value("name", PostArgs) of
        undefined -> Req:respond({400, add_header(), []});
        <<>>      -> Req:respond({400, add_header(), []});
        BucketId  -> handle_bucket_create(PoolId, BucketId, Req)
    end.

handle_bucket_create(_PoolId, [$_ | _], Req) ->
    % Bucket name cannot have a leading underscore character.
    reply_json(Req, [list_to_binary("Bucket name cannot start with an underscore.")], 400);

handle_bucket_create(_PoolId, _BucketId, Req) ->
    case ns_node_disco:nodes_wanted() =:= ns_node_disco:nodes_actual_proper() of
        true ->
            Req:respond({400, add_header(), "Sorry, can't create buckets yet."});
        false ->
            reply_json(Req, [list_to_binary("One or more server nodes appear to be down. " ++
                                            "Please first restore or remove those servers nodes " ++
                                            "so that the entire cluster is healthy.")], 400)
    end.

handle_bucket_flush(PoolId, Id, Req) ->
    ns_log:log(?MODULE, 0005, "Flushing pool ~p bucket ~p from node ~p",
               [PoolId, Id, erlang:node()]),
    Req:respond({400, add_header(), "Flushing is not currently implemented."}).

vbucket_map(_PoolId, _BucketId) ->
    % TODO: Need a real vbucket server map.
    [{hashAlgorithm, crc},
     {numReplicas, 0},
     {serverList, lists:map(fun (ENode) ->
                                {_Name, Host} = misc:node_name_host(ENode),
                                {value, DirectPort} = direct_port(ENode),
                                Host ++ ":" ++ integer_to_list(DirectPort)
                            end,
                            ns_node_disco:nodes_wanted())},
     {vBucketMap, [[0], [0]]}].

vbucket_map_to_json(PropList) ->
    {struct, lists:map(
                 fun ({hashAlgorithm, crc}) -> {hashAlgorithm, <<"CRC">>};
                     ({serverList, SL}) -> {serverList, lists:map(fun list_to_binary/1, SL)};
                     (X) -> X
                 end,
                 PropList)}.

handle_init_status_post(Req) ->
    %% parameter example: value=done, value=welcome, value=someOpaqueValueFromJavaScript
    %%
    Params = Req:parse_post(),
    case change_init_status(proplists:get_value("value", Params)) of
        false -> Req:respond({400, add_header(), "Attempt to initStatus but missing value parameter.\n"});
        true  -> Req:respond({200, add_header(), []})
    end.

change_init_status(undefined) ->
    ns_log:log(?MODULE, ?INIT_STATUS_BAD_PARAM, "Received request to initStatus but missing value parameter.", []),
    false;

change_init_status(InitStatus) ->
    ns_log:log(?MODULE, ?INIT_STATUS_UPDATED, "initStatus updated to ~p.", [InitStatus]),
    ns_config:set(init_status, [{value, InitStatus}]),
    true.

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
    %%                    clusterMemberPort=8080&
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
                            ok = ns_cluster:shun(OtpNode),
                            ns_log:log(?MODULE, ?NODE_EJECTED, "Node ejected: ~p from node: ~p",
                                       [OtpNode, erlang:node()]),
                            Req:respond({200, add_header(), []});
                        false ->
                            % Node doesn't exist.
                            ns_log:log(?MODULE, 0018, "Request to eject nonexistant node failed.  Requested node: ~p",
                                       [OtpNode]),
                            Req:respond({400, add_header(), "Node does not exist.\n"})
                    end
            end
    end.

handle_settings_web(Req) ->
    reply_json(Req, build_settings_web()).

build_settings_web() ->
    Config = ns_config:get(),
    {U, P} = case ns_config:search_prop(Config, rest_creds, creds) of
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
                               {[], []} -> true;
                               {[_Head | _], P} ->
                                   case length(P) =< 5 of
                                       true -> <<"The password must be at least six characters.">>;
                                       _ -> true
                                   end;
                               _ -> <<"Username must not be blank if Password is provided">>
                           end],
             lists:filter(fun (E) -> E =/= true end,
                          Candidates)
    end.

handle_settings_web_post(Req) ->
    PostArgs = Req:parse_post(),
    Port = proplists:get_value("port", PostArgs),
    U = proplists:get_value("username", PostArgs),
    P = proplists:get_value("password", PostArgs),
    InitStatus = proplists:get_value("initStatus", PostArgs),
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
            change_init_status(InitStatus),
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

build_port_settings(PoolId) ->
    PoolConfig = find_pool_by_id(PoolId),
    [{proxyPort, proplists:get_value(port, PoolConfig)},
     {directPort, 11212}]. % TODO: this needs to come from the config

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
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
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
    warn;
ns_log_cat(?INIT_STATUS_BAD_PARAM) ->
    warn;
ns_log_cat(?INIT_STATUS_UPDATED) ->
    info.

ns_log_code_string(0013) ->
    "node join failure";
ns_log_code_string(0019) ->
    "server error during request processing";
ns_log_code_string(?START_FAIL) ->
    "failed to start service";
ns_log_code_string(?NODE_EJECTED) ->
    "node was ejected";
ns_log_code_string(?UI_SIDE_ERROR_REPORT) ->
    "client-side error report";
ns_log_code_string(?INIT_STATUS_BAD_PARAM) ->
    "init status bad parameter";
ns_log_code_string(?INIT_STATUS_UPDATED) ->
    "init status".

alert_key(?BUCKET_CREATED)  -> bucket_created;
alert_key(?BUCKET_DELETED)  -> bucket_deleted;
alert_key(_) -> all.

%% I'm trying to avoid consing here, but, probably, too much
diag_filter_out_config_password_list([], UnchangedMarker) ->
    UnchangedMarker;
diag_filter_out_config_password_list([X | Rest], UnchangedMarker) ->
    NewX = diag_filter_out_config_password_rec(X, UnchangedMarker),
    case diag_filter_out_config_password_list(Rest, UnchangedMarker) of
        UnchangedMarker ->
            case NewX of
                UnchangedMarker -> UnchangedMarker;
                _ -> [NewX | Rest]
            end;
        NewRest -> [case NewX of
                        UnchangedMarker -> X;
                        _ -> NewX
                    end | NewRest]
    end.

diag_filter_out_config_password_rec(Config, UnchangedMarker) when is_tuple(Config) ->
    case Config of
        {password, _} ->
            {password, 'filtered-out'};
        {pass, _} ->
            {pass, 'filtered-out'};
        _ -> case diag_filter_out_config_password_rec(tuple_to_list(Config), UnchangedMarker) of
                 UnchangedMarker -> Config;
                 List -> list_to_tuple(List)
             end
    end;
diag_filter_out_config_password_rec(Config, UnchangedMarker) when is_list(Config) ->
    diag_filter_out_config_password_list(Config, UnchangedMarker);
diag_filter_out_config_password_rec(_Config, UnchangedMarker) -> UnchangedMarker.

diag_filter_out_config_password(Config) ->
    UnchangedMarker = make_ref(),
    case diag_filter_out_config_password_rec(Config, UnchangedMarker) of
        UnchangedMarker -> Config;
        NewConfig -> NewConfig
    end.

do_diag_per_node() ->
    [{version, ns_info:version()},
     {config, diag_filter_out_config_password(ns_config:get())},
     {basic_info, element(2, ns_info:basic_info())},
     {memory, memsup:get_memory_data()},
     {disk, disksup:get_disk_data()}].

diag_multicall(Mod, F, Args) ->
    Nodes = [node() | nodes()],
    {Results, BadNodes} = rpc:multicall(Nodes, Mod, F, Args, 5000),
    lists:zipwith(fun (Node,Res) -> {Node, Res} end,
                  lists:subtract(Nodes, BadNodes),
                  Results)
        ++ lists:map(fun (Node) -> {Node, diag_failed} end,
                     BadNodes).

diag_format_timestamp(EpochMilliseconds) ->
    SecondsRaw = trunc(EpochMilliseconds/1000),
    AsNow = {SecondsRaw div 1000000, SecondsRaw rem 1000000, 0},
    %% not sure about local time here
    {{YYYY, MM, DD}, {Hour, Min, Sec}} = calendar:now_to_local_time(AsNow),
    io_lib:format("~4.4.0w-~2.2.0w-~2.2.0w ~2.2.0w:~2.2.0w:~2.2.0w.~3.3.0w",
                  [YYYY, MM, DD, Hour, Min, Sec, EpochMilliseconds rem 1000]).

diag_format_log_entry(Entry) ->
    [Type, Code, Module,
     TStamp, ShortText, Text] = lists:map(fun (K) ->
                                                  proplists:get_value(K, Entry)
                                          end,
                                          [type, code, module, tstamp, shortText, text]),
    FormattedTStamp = diag_format_timestamp(TStamp),
    io_lib:format("~s ~s:~B:~s:~s - ~s~n",
                  [FormattedTStamp, Module, Code, Type, ShortText, Text]).

handle_diag(Req) ->
    Pool = find_pool_by_id("default"),
    Buckets = lists:sort(fun (A,B) -> element(1, A) =< element(1, B) end,
                         expect_prop_value(buckets, Pool)),
    Logs = lists:flatmap(fun ({struct, Entry}) -> diag_format_log_entry(Entry) end,
                         menelaus_alert:build_logs([{"limit", "1000000"}])),
    Infos = [["per_node_diag = ~p", diag_multicall(?MODULE, do_diag_per_node, [])],
             ["nodes_info = ~p", build_nodes_info(Pool, true)],
             ["buckets = ~p", Buckets],
             ["logs:~n-------------------------------~n~s", Logs]],
    Text = lists:flatmap(fun ([Fmt | Args]) ->
                                 io_lib:format(Fmt ++ "~n~n", Args)
                         end, Infos),
    Req:ok({"text/plain; charset=utf-8",
            server_header(),
            list_to_binary(Text)}).

ymd_to_string({Y, M, D}) ->
    integer_to_list(Y) ++ "/" ++
    integer_to_list(M) ++ "/" ++
    integer_to_list(D);

ymd_to_string(invalid) -> "invalid";
ymd_to_string(forever) -> "forever".

handle_node("Self", Req)            -> handle_node("default", node(), Req);
handle_node(S, Req) when is_list(S) -> handle_node("default", list_to_atom(S), Req).

handle_node(PoolId, Node, Req) ->
    MyPool = find_pool_by_id(PoolId),
    KV = build_node_info(MyPool, Node),
    {License, Valid, ValidUntil} = case ns_license:license(Node) of
        {undefined, V, VU} -> {"", V, ymd_to_string(VU)};
        {X, V, VU}         -> {X, V, ymd_to_string(VU)}
    end,
    MemQuota = case ns_storage_conf:memory_quota(Node) of
                   none -> <<"none">>;
                   Y    -> Y
               end,
    R = {struct, storage_conf_to_json(ns_storage_conf:storage_conf(Node))},
    reply_json(Req,
               {struct, [{"license", list_to_binary(License)},
                         {"licenseValid", Valid},
                         {"licenseValidUntil", list_to_binary(ValidUntil)},
                         {"memoryQuota", MemQuota},
                         {"storage", R}] ++ KV}).

% S = [{"ssd", []},
%      {"hdd", [[{"path", "/some/nice/disk/path"}, {"quotaMb", 1234}, {"state", ok}],
%               [{"path", "/another/good/disk/path"}, {"quotaMb", 5678}, {"state", ok}]]}].
%
storage_conf_to_json(S) ->
    lists:map(fun ({StorageType, Locations}) -> % StorageType is "ssd" or "hdd".
                  {StorageType, lists:map(fun (LocationPropList) ->
                                              {struct, lists:map(fun location_prop_to_json/1, LocationPropList)}
                                          end,
                                          Locations)}
              end,
              S).

location_prop_to_json({"path", L}) -> {"path", list_to_binary(L)};
location_prop_to_json({"quotaMb", none}) -> {"quotaMb", <<"none">>};
location_prop_to_json({"state", ok}) -> {"state", <<"ok">>};
location_prop_to_json(KV) -> KV.

handle_node_resources_post("Self", Req)            -> handle_node_resources_post(node(), Req);
handle_node_resources_post(S, Req) when is_list(S) -> handle_node_resources_post(list_to_atom(S), Req);

handle_node_resources_post(Node, Req) ->
    Params = Req:parse_post(),
    Path = proplists:get_value("path", Params),
    Quota = case proplists:get_value("quota", Params) of
              "none" -> none;
              X      -> list_to_integer(X)
            end,
    Kind = case proplists:get_value("kind", Params) of
              "ssd" -> ssd;
              "hhd" -> hdd;
              _     -> undefined
           end,
    case lists:member(undefined, [Path, Quota, Kind]) of
        true -> Req:respond({400, add_header(), "Invalid input while adding storage resource to node"});
        false ->
            case ns_storage_conf:add_storage(Node, Path, Kind, Quota) of
                ok -> Req:respond({200, add_header(), "Added storage location to node"});
                {error, _} -> Req:respond({400, add_header(), "Error while adding storage resource to node"})
            end
    end.

handle_resource_delete("Self", Path, Req)            -> handle_resource_delete(node(), Path, Req);
handle_resource_delete(S, Path, Req) when is_list(S) -> handle_resource_delete(list_to_atom(S), Path, Req);

handle_resource_delete(Node, Path, Req) ->
    case ns_storage_conf:remove_storage(Node, Path) of
        ok -> Req:respond({204, add_header(), []});
        {error, _} -> Req:respond({404, add_header(), "The storage location could not be removed.\r\n"})
    end.

handle_node_settings_post("Self", Req)            -> handle_node_settings_post(node(), Req);
handle_node_settings_post(S, Req) when is_list(S) -> handle_node_settings_post(list_to_atom(S), Req);

handle_node_settings_post(Node, Req) ->
    %% parameter example: license=some_license_string, memoryQuota=NumInMb
    %%
    Params = Req:parse_post(),
    Results = [
        case proplists:get_value("license", Params) of
            undefined -> ok;
            License -> case ns_license:change_license(Node, License) of
                            ok         -> ok;
                            {error, _} -> "Error changing license.\n"
                       end
        end,
        case proplists:get_value("memoryQuota", Params) of
            undefined -> ok;
            X -> MQNum = case X of
                             "none" -> none;
                             _      -> list_to_integer(X)
                         end,
                 case ns_storage_conf:change_memory_quota(Node, MQNum) of
                     ok         -> ok;
                     {error, _} -> "Error changing memory quota.\n"
                 end
        end
    ],
    case lists:filter(fun(X) -> X =/= ok end, Results) of
        [] -> Req:respond({200, add_header(), []});
        Errs -> Req:respond({400, add_header(), lists:flatten(Errs)})
    end.

validate_add_node_params(Hostname, Port, User, Password) ->
    Candidates = case lists:member(undefined, [Hostname, Port, User, Password]) of 
                     true -> [<<"Missing required parameter">>];
                     _ -> [is_valid_port_number(Port) orelse <<"Invalid rest port specified">>,
                           case Hostname of
                               [] -> <<"Hostname cannot be empty">>;
                               _ -> true
                           end,
                           case {User, Password} of
                               {[], []} -> true;
                               {[_Head | _], [_PasswordHead | _]} -> true;
                               {[], [_PasswordHead | _]} -> <<"Password must be passed with non-empty username">>;
                               _ -> <<"Empty password given">>
                           end]
                 end,
    lists:filter(fun (E) -> E =/= true end, Candidates).

handle_add_node(Req) ->
    %% parameter example: hostname=epsilon.local, user=Administrator, password=asd!23
    Params = Req:parse_post(),
    {Hostname, StringPort} = case proplists:get_value("hostname", Params, "") of
                                 [_ | _] = V ->
                                     case string:tokens(V, ":") of
                                         [N] -> {N, "8080"};
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

%% TODO
handle_failover(Req) -> 
    Req:respond({200, [], []}).

handle_rebalance(Req) ->
    Params = Req:parse_post(),
    KnownNodesS = string:tokens(proplists:get_value("knownNodes", Params, ""),","),
    EjectedNodesS = string:tokens(proplists:get_value("ejectedNodes", Params, ""), ","),
    KnownNodes = [list_to_atom(N) || N <- KnownNodesS],
    EjectedNodes = [list_to_atom(N) || N <- EjectedNodesS],
    case ns_cluster_membership:start_rebalance(KnownNodes, EjectedNodes) of
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
                 _ -> [{status, <<"none">>}]
             end,
    reply_json(Req, {struct, Status}, 200).

handle_stop_rebalance(Req) ->
    ns_cluster_membership:stop_rebalance(),
    Req:respond({200, [], []}).

%% TODO
handle_re_add_node(Req) ->
    Req:respond({200, [], []}).
