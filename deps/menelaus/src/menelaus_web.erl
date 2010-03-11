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

-export([ns_log_cat/1, ns_log_code_string/1]).

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

-define(IMPL_VERSION, "1.0").

%% The range used within this file is arbitrary and undefined, so I'm
%% defining an arbitrary value here just to be rebellious.
-define(START_FAIL, 100).

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
    Config = ns_config:get(),
    Ip = case os:getenv("MOCHIWEB_IP") of
             false -> "0.0.0.0";
             Any -> Any
         end,
    Port = case os:getenv("MOCHIWEB_PORT") of
               false ->
                   case ns_config:search_prop(Config,
                                              {node, node(), rest},
                                              port, false) of
                       false ->
                           ns_config:search_prop(Config, rest, port, 8080);
                       P -> P
                   end;
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
        "/" ++ Path = Req:get(path),
        PathTokens = string:tokens(Path, "/"),
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
                             ["diag"] ->
                                 {auth, fun handle_diag/1};
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
                             ["node", "controller", "doJoinCluster"] ->
                                 {auth, fun handle_join/1};
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
                                                            ns_log:log(?MODULE, 0020, "Client-side error-report for user ~p on node ~p: ~p~n",
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
                             _ ->
                                 ns_log:log(?MODULE, 0002, "Invalid delete received: ~p", [Req]),
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
            ns_log:log(?MODULE, 0019, "Server error during processing: ~p", Report),
            reply_json(Req, [list_to_binary("Unexpected server error, request logged.")], 500)
    end.


%% Internal API

implementation_version() ->
    list_to_binary(?IMPL_VERSION).

handle_pools(Req) ->
    reply_json(Req, build_pools()).

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
    {struct, [{pools, Pools} | build_versions()]}.

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
    proplists:get_bool(memcached_running, InfoNode).

build_pool_info(Id, UserPassword) ->
    build_pool_info(Id, UserPassword, normal).

build_pool_info(Id, _UserPassword, InfoLevel) ->
    MyPool = find_pool_by_id(Id),
    Nodes = build_nodes_info(MyPool, true, InfoLevel),
    BucketsInfo = {struct, [{uri,
                             list_to_binary(concat_url_path(["pools", Id, "buckets"]))}]},
    {struct, [{name, list_to_binary(Id)},
              {nodes, Nodes},
              {buckets, BucketsInfo},
              {controllers, {struct,
                             [{ejectNode, {struct, [{uri, <<"/controller/ejectNode">>}]}},
                              {testWorkload, {struct,
                                             [{uri,
                                               list_to_binary(concat_url_path(["pools", Id, "controller", "testWorkload"]))}]}}]}},
              {stats, {struct,
                       [{uri,
                         list_to_binary(concat_url_path(["pools", Id, "stats"]))}]}}]}.

find_pool_by_id(Id) -> expect_prop_value(Id, expect_config(pools)).

build_nodes_info(MyPool, IncludeOtp) ->
    build_nodes_info(MyPool, IncludeOtp, normal).

build_nodes_info(MyPool, IncludeOtp, InfoLevel) ->
    OtpCookie = list_to_binary(atom_to_list(ns_node_disco:cookie_get())),
    WantENodes = ns_node_disco:nodes_wanted(),
    NodeStatuses = ns_doctor:get_nodes(),
    BucketsAll = expect_prop_value(buckets, MyPool),
    NodesBucketMemoryTotal =
        length(WantENodes) *
            lists:foldl(fun({_BucketName, BucketConfig}, Acc) ->
                                Acc + proplists:get_value(size_per_node, BucketConfig, 0)
                        end,
                        0,
                        BucketsAll),
    {ok, Stats} = stats_aggregator:get_stats(1),
    NodesBucketMemoryAllocated = case dict:find("bytes", Stats) of
        {ok, [Bytes]} -> Bytes;
        error -> 0
    end,
    Nodes =
        lists:map(
          fun(WantENode) ->
                  {_Name, Host} = misc:node_name_host(WantENode),
                  InfoNode = case dict:find(WantENode, NodeStatuses) of
                                 {ok, Info} -> Info;
                                 error -> []
                             end,
                  Status = case is_healthy(InfoNode) of
                               true -> <<"healthy">>;
                               false -> <<"unhealthy">>
                           end,
                  {value, DirectPort} = direct_port(WantENode),
                  ProxyPort = pool_proxy_port(MyPool, WantENode),
                  Versions = proplists:get_value(version, InfoNode, []),
                  Version = proplists:get_value(ns_server, Versions, "unknown"),
                  OS = proplists:get_value(system_arch, InfoNode, "unknown"),
                  {UpSecs, {MemoryTotal, MemoryAlloced, _}} =
                      case InfoLevel of
                          normal ->
                              {proplists:get_value(wall_clock, InfoNode, 0),
                               proplists:get_value(memory_data, InfoNode,
                                                   {0, 0, undefined})};
                          stable ->
                              % These stats are zero'ed so that
                              % successive calls will provide results
                              % that are comparable and appear stable as long
                              % the cluster is stable (health is stable, no-reconfigurations).
                              {0, {0, 0, undefined}}
                      end,
                  KV1 = [{hostname, list_to_binary(Host)},
                         {status, Status},
                         {uptime, list_to_binary(integer_to_list(UpSecs))},
                         {version, list_to_binary(Version)},
                         {os, list_to_binary(OS)},
                         {memoryTotal, erlang:trunc(MemoryTotal)},
                         {memoryFree, erlang:trunc(MemoryTotal - MemoryAlloced)},
                         {mcdMemoryReserved, erlang:trunc(NodesBucketMemoryTotal)},
                         {mcdMemoryAllocated, erlang:trunc(NodesBucketMemoryAllocated)},
                         {ports,
                          {struct, [{proxy, ProxyPort},
                                    {direct, DirectPort}]}}],
                  KV2 = case IncludeOtp of
                               true ->
                                   KV1 ++ [{otpNode,
                                            list_to_binary(
                                              atom_to_list(WantENode))},
                                           {otpCookie, OtpCookie}];
                               false -> KV1
                        end,
                  {struct, KV2}
          end,
          WantENodes),
    Nodes.

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
    Pool = find_pool_by_id(PoolId),
    Bucket = find_bucket_by_id(Pool, Id),
    case menelaus_auth:is_bucket_accessible({Id, Bucket}, Req) of
        true -> apply(Body, [Pool, Bucket]);
        _ -> menelaus_auth:require_auth(Req)
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

handle_bucket_info(PoolId, Id, Req, Pool, _Bucket) ->
    reply_json(Req, build_bucket_info(PoolId, Id, Pool)).

handle_bucket_info(PoolId, Id, Req) ->
    Pool = find_pool_by_id(PoolId),
    Bucket = find_bucket_by_id(Pool, Id),
    handle_bucket_info(PoolId, Id, Req, Pool, Bucket).

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
             %% TODO: move this somewhere else
             %% {passwordUri, <<"none">>},
             {basicStats, {struct, case InfoLevel of
                                       normal -> menelaus_stats:basic_stats(PoolId, Id);
                                       stable -> []
                                   end}},
             {nodes, Nodes},
             {stats, {struct, [{uri, StatsUri}]}}],
    List2 = case tgen:is_traffic_bucket(PoolId, Id) of
                true -> [{testAppBucket, true},
                         {controlURL, list_to_binary(concat_url_path(["pools", PoolId,
                                                                      "controller", "testWorkload"]))},
                         {status, tgen:traffic_started()}
                         | List1];
                _ -> List1
            end,
    {struct, List2}.

handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket) ->
    F = fun(InfoLevel) -> build_bucket_info(PoolId, Id, Pool, InfoLevel) end,
    handle_streaming(F, Req, undefined).

handle_bucket_delete(PoolId, BucketId, Req) ->
    case mc_bucket:bucket_delete(PoolId, BucketId) of
        true ->
            ns_log:log(?MODULE, 0011, "Deleted bucket ~p from pool ~p (via node ~p).",
                       [BucketId, PoolId, node()]),
            Req:respond({204, add_header(), []});
        false ->
            %% if bucket isn't found
            Req:respond({404, add_header(), "The bucket to be deleted was not found.\r\n"})
    end,
    ok.

handle_bucket_update(PoolId, BucketId, Req) ->
    % Req will contain a urlencoded form which may contain
    % name, cacheSize, password, verifyPassword
    %
    % A POST means create or update existing bucket settings.  For
    % 1.0, this will *only* allow setting the memory to a higher or
    % lower, but non-zero value.
    %
    % TODO: convert to handling memory changes
    % TODO: remove password handling
    % TODO: define new URI for password handling for the pool
    %
    case mc_bucket:bucket_config_get(mc_pool:pools_config_get(),
                                     PoolId, BucketId) of
        false -> handle_bucket_create(PoolId, BucketId, Req);
        BucketConfig ->
            % Update, only the auth_plain/password field for 1.0.
            {struct, Params} = parse_json(Req),
            Auth = case proplists:get_value(<<"password">>, Params) of
                       undefined -> undefined;
                       <<>>      -> undefined;
                       Password  -> {BucketId, binary_to_list(Password)}
                   end,
            BucketConfig2 =
                lists:keystore(auth_plain, 1, BucketConfig,
                               {auth_plain, Auth}),
            case BucketConfig2 =:= BucketConfig of
                true  -> Req:respond({200, add_header(), []}); % No change.
                false -> ns_log:log(?MODULE, 0010, "updating bucket config: ~p in: ~p via node ~p",
                                    [BucketId, PoolId, node()]),
                         mc_bucket:bucket_config_make(PoolId,
                                                      BucketId,
                                                      BucketConfig2),
                         Req:respond({200, add_header(), []})
            end
    end.

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

handle_bucket_create(PoolId, BucketId, Req) ->
    % Bucket size validation.
    PostArgs = Req:parse_post(),
    %% TODO: we have a race here, but it's not very bad, and there are
    %% more, so we'll simply ignore it for now
    DupNameV = case mc_bucket:bucket_config_get(mc_pool:pools_config_get(),
                                                PoolId, BucketId) of
                   false -> undefined;
                   _ -> <<"A cache bucket with given name already exists.">>
               end,
    ParsedSizeWanted = (catch list_to_integer(proplists:get_value("cacheSize", PostArgs))),
    NzV = if
              not is_integer(ParsedSizeWanted) -> <<"The cache size must be an integer.">>;
              ParsedSizeWanted =< 0 -> <<"The cache size must be non-zero.">>;
              true -> undefined
          end,
    SizeWanted = if
                     NzV =:= undefined -> ParsedSizeWanted;
                     true -> 0
                 end,
    %  go get the memory out there, reusing nodes_info, not caring about OTP
    Pool = find_pool_by_id(PoolId),
    PoolNodes = build_nodes_info(Pool, false),

    TotalBucketsSize = lists:foldl(fun (B,A) -> A + expect_prop_value(size_per_node, element(2, B)) end,
                                   0,
                                   expect_prop_value(buckets, Pool)),
    SmallestNodeRAM = lists:min(lists:map(
                                  fun(X) -> proplists:get_value(memoryTotal, X) end,
                                  proplists:get_all_values(struct, PoolNodes))),
    % let's reserve 128MB of memory for OS & our code
    MinMemFree = (trunc(SmallestNodeRAM/1048576) - TotalBucketsSize - 128),
    SzV = case SizeWanted > MinMemFree of
              true -> list_to_binary(
                        io_lib:format("Cannot create cache bucket; the cluster only has ~p megabytes free for new cache buckets.",
                                      [trunc(MinMemFree)]));
              false -> undefined
          end,

    % Input bucket name cannot have whitespace.
    FmtV = case mc_bucket:is_valid_bucket_name(BucketId) of
               true -> undefined;
               _ -> <<"The cache bucket name is invalid.">>
           end,
    PossMsg = [DupNameV, SzV, FmtV, NzV],
    Msgs = lists:filter(fun (X) -> X =/= undefined end,
                        PossMsg),
    case Msgs of
        [] -> handle_bucket_create_do(PoolId, BucketId, Req);
        _ -> reply_json(Req, Msgs, 400)
    end.

handle_bucket_create_do(PoolId, BucketId, Req) ->
    PostArgs = Req:parse_post(),
    BucketConfigDefault = mc_bucket:bucket_config_default(),
    BucketConfig =
        lists:foldl(
          fun({auth_plain, _}, C) ->
                  case proplists:get_value("name", PostArgs) of
                      undefined -> C;
                      Pass -> lists:keystore(auth_plain, 1, C,
                                             {auth_plain, {BucketId, Pass}})
                  end;
             ({size_per_node, _}, C) ->
                  case proplists:get_value("cacheSize", PostArgs) of
                      undefined -> C;
                      SList when is_list(SList) ->
                          S = list_to_integer(SList),
                          lists:keystore(size_per_node, 1, C,
                                         {size_per_node, S});
                      SBin when is_binary(SBin) ->
                          S = list_to_integer(binary_to_list(SBin)),
                          lists:keystore(size_per_node, 1, C,
                                         {size_per_node, S});
                      S when is_integer(S) ->
                          lists:keystore(size_per_node, 1, C,
                                         {size_per_node, S})
                  end
          end,
          BucketConfigDefault,
          BucketConfigDefault),
    mc_bucket:bucket_config_make(PoolId,
                                 BucketId,
                                 BucketConfig),
    ns_log:log(?MODULE, 0012, "bucket created: ~p in: ~p",
               [BucketId, PoolId]),
    handle_bucket_info(PoolId, BucketId, Req).

handle_bucket_flush(PoolId, Id, Req) ->
    ns_log:log(?MODULE, 0005, "Flushing pool ~p bucket ~p from node ~p",
               [PoolId, Id, erlang:node()]),
    case mc_bucket:bucket_flush(PoolId, Id) of
        ok    -> Req:respond({204, add_header(), []});
        false -> Req:respond({404, add_header(), []})
    end.

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
                [] -> handle_join(Req, OtherHost, OtherPort, OtherUser, OtherPswd);
                _ -> reply_json(Req, Msgs, 400)
            end
    end.

handle_join(Req, OtherHost, OtherPort, OtherUser, OtherPswd) ->
    case tgen:system_joinable() of
        true ->
            case menelaus_rest:rest_get_otp(OtherHost, OtherPort,
                                            {OtherUser, OtherPswd}) of
                {ok, undefined, _} ->
                    ns_log:log(?MODULE, 0014, "During node join, remote node (~p:~p) returned an invalid response: missing otpCookie (from node ~p).",
                               [OtherHost, OtherPort, node()]),
                    reply_json(Req, [list_to_binary("Invalid response from remote node, missing otpCookie.")], 400);
                {ok, _, undefined} ->
                    ns_log:log(?MODULE, 0015, "During node join, remote node (~p:~p) returned an invalid response: missing otpNode (from node ~p).",
                               [OtherHost, OtherPort, node()]),
                    reply_json(Req, [list_to_binary("Invalid response from remote node, missing otpNode.")], 400);
                {ok, Node, Cookie} ->
                    handle_join(Req,
                                list_to_atom(binary_to_list(Node)),
                                list_to_atom(binary_to_list(Cookie)));
                {error, econnrefused} ->
                    ns_log:log(?MODULE, 0016, "During node join, could not connect to ~p on port ~p from node ~p.", [OtherHost, OtherPort, node()]),
                    reply_json(Req, [list_to_binary(io_lib:format("Could not connect to ~p on port ~p.", [OtherHost, OtherPort]))], 400);
                {error, nxdomain} ->
                    ns_log:log(?MODULE, 0020, "During node join, failed to resolve host ~p on port ~p from node ~p.", [OtherHost, OtherPort, node()]),
                    reply_json(Req, [list_to_binary(io_lib:format("Failed to resolve address for ~p.  The hostname may be incorrect or not resolvable.", [OtherHost]))], 400);
                {error, timeout} ->
                    ns_log:log(?MODULE, 0021, "During node join, timeout connecting to ~p on port ~p from node ~p.", [OtherHost, OtherPort, node()]),
                    reply_json(Req, [list_to_binary(io_lib:format("Timeout connecting to ~p on port ~p.", [OtherHost, OtherPort]))], 400);
                Any ->
                    ns_log:log(?MODULE, 0022, "During node join, the remote host ~p on port ~p did not return a REST response.  Error encountered was: ~p",
                               [OtherHost, OtherPort, Any]),
                    reply_json(Req, [list_to_binary("Invalid response from remote node.  Error logged.")],400)
            end;
        false ->
            % We are not an 'empty' node, so user should first remove
            % buckets, etc.
            reply_json(Req, [list_to_binary("Your server cannot join this cluster because you have existing buckets configured on this server. Please remove them before joining a cluster.")],400)
    end.

handle_join(Req, OtpNode, OtpCookie) ->
    case ns_cluster:join(OtpNode, OtpCookie) of
        ok -> ns_log:log(?MODULE, 0009, "Joined cluster at node: ~p with cookie: ~p from node: ~p",
                         [OtpNode, OtpCookie, erlang:node()]),
              % No need to restart here, as our ns_config event watcher
              % will do it if our rest config changes.
              Req:respond({200, add_header(), []});
        Any -> ns_log:log(?MODULE, 0017, "Unexpected error encountered during cluster join ~p", [Any]),
               reply_json(Req, [list_to_binary("Unexpected error encountered during cluster join.")],500)
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
    %% using cast because I don't expect our node to be able
    %% to respond after being ejected and trying all nodes,
    %% because we don't know who of them are actually alife
    OtherNodes = lists:subtract(ns_node_disco:nodes_actual_proper(), [node()]),
    error_logger:info_msg("Calling leave on ~p~n", [OtherNodes]),
    lists:foreach(fun (Node) ->
                          rpc:cast(Node, ns_cluster, leave, [node()])
                          end, OtherNodes),
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
                            ok = ns_cluster:leave(OtpNode),
                            ns_log:log(?MODULE, 0013, "Node ejected: ~p from node: ~p",
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
                               {[_Head | _], _} -> true;
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
    case validate_settings(Port, U, P) of
        [_Head | _]=Errors ->
            reply_json(Req, Errors, 400);
        [] ->
            PortInt = list_to_integer(Port),
            case build_settings_web() =:= build_settings_web(PortInt, U, P) of
                true -> ok; % No change.
                false ->
                    ns_config:set(rest,
                                  [{port, PortInt}]),
                    if
                        {[], []} == {U,P} ->
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

build_port_settings(PoolId) ->
    PoolConfig = find_pool_by_id(PoolId),
    [{proxyPort, proplists:get_value(port, PoolConfig)},
     {directPort, list_to_integer(mc_pool:memcached_port(ns_config:get(),
                                                         node()))}].

validate_port_settings(ProxyPort, DirectPort) ->
    CS = [is_valid_port_number(ProxyPort) orelse <<"Proxy port must be a positive integer less than 65536">>,
          is_valid_port_number(DirectPort) orelse <<"Direct port must be a positive integer less than 65536">>],
    lists:filter(fun (C) -> C =/= true end,
                 CS).

handle_port_settings_post(PostArgs, PoolId) ->
    PPort = proplists:get_value("proxyPort", PostArgs),
    DPort = proplists:get_value("directPort", PostArgs),
    case validate_port_settings(PPort, DPort) of
        [] -> {ok, fun () ->
                           Config = ns_config:get(),
                           Pools = mc_pool:pools_config_get(Config),
                           Pool = mc_pool:pool_config_get(Pools, PoolId),
                           Pool2 = lists:keystore(port, 1, Pool,
                                                  {port, list_to_integer(PPort)}),
                           mc_pool:pools_config_set(
                             mc_pool:pool_config_set(Pools, PoolId, Pool2)),
                           mc_pool:memcached_port_set(Config, undefined, DPort),
                           ok
                   end};
        Errors -> {errors, Errors}
    end.

handle_traffic_generator_control_post(Req) ->
    PostArgs = Req:parse_post(),
    case proplists:get_value("onOrOff", PostArgs) of
        "off" -> ns_log:log(?MODULE, 0006, "Stopping Test Server workload from node ~p",
                            [erlang:node()]),
                 tgen:traffic_stop(),
                 Req:respond({204, add_header(), []});
        "on" -> ns_log:log(?MODULE, 0007, "Starting Test Server workload from node ~p",
                           [erlang:node()]),
                % TODO: Use rpc:multicall here to turn off traffic
                %       generation across all actual nodes in the cluster.
                tgen:traffic_start(),
                Req:respond({204, add_header(), []});
        _ ->
            ns_log:log(?MODULE, 0008, "Invalid post to testWorkload controller.  PostArgs ~p evaluated to ~p",
                       [PostArgs, proplists:get_value(PostArgs, "onOrOff")]),
            Req:respond({400, add_header(), "Bad Request\n"})
    end.

% Make sure an input parameter string is clean and not too long.
% Second argument means "undefinedIsAllowed"

%% is_clean(undefined, true, _MinLen)  -> true;
%% is_clean(undefined, false, _MinLen) -> false;
%% is_clean(S, _UndefinedIsAllowed, MinLen) ->
%%     Len = length(S),
%%     (Len >= MinLen) andalso (Len < 80) andalso (S =:= (S -- " \t\n")).

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
ns_log_cat(0014) ->
    crit;
ns_log_cat(0015) ->
    crit;
ns_log_cat(0016) ->
    crit;
ns_log_cat(0017) ->
    crit;
ns_log_cat(0019) ->
    warn;
ns_log_cat(?START_FAIL) ->
    crit.

ns_log_code_string(0013) ->
    "node join failure";
ns_log_code_string(0014) ->
    "node join failure";
ns_log_code_string(0015) ->
    "node join failure";
ns_log_code_string(0016) ->
    "node join failure";
ns_log_code_string(0017) ->
    "node join failure";
ns_log_code_string(0019) ->
    "server error during request processing";
ns_log_code_string(?START_FAIL) ->
    "failed to start service".

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
