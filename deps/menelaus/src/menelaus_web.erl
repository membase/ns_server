%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_web).
-author('NorthScale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test/0]).
-import(menelaus_util,
        [test_under_debugger/0, debugger_apply/2,
         wrap_tests_with_cache_setup/1]).
-endif.

-export([start_link/0, start_link/1, stop/0, loop/2, webconfig/0, restart/0,
         find_pool_by_id/1, all_accessible_buckets/2,
         find_bucket_by_id/2]).

-import(menelaus_util,
        [server_header/0,
         redirect_permanently/2,
         reply_json/2,
         parse_json/1,
         expect_config/1,
         expect_prop_value/2,
         get_option/2,
         direct_port/1]).

%% External API

start_link() ->
    start_link(webconfig()).

start_link(Options) ->
    {DocRoot, Options1} = get_option(docroot, Options),
    Loop = fun (Req) ->
                   ?MODULE:loop(Req, DocRoot)
           end,
    mochiweb_http:start([{name, ?MODULE}, {loop, Loop} | Options1]).

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
                 {docroot, menelaus_deps:local_path(["priv","public"],
                                                    ?MODULE)}],
    WebConfig.

loop(Req, DocRoot) ->
    "/" ++ Path = Req:get(path),
    PathTokens = string:tokens(Path, "/"),
    Action = case Req:get(method) of
                 Method when Method =:= 'GET'; Method =:= 'HEAD' ->
                     case PathTokens of
                         [] ->
                             {done, redirect_permanently("/index.html", Req)};
                         ["pools"] ->
                             {auth_bucket, fun handle_pools/1};
                         ["pools", Id] ->
                             {auth_bucket, fun handle_pool_info/2, [Id]};
                         ["pools", Id, "stats"] ->
                             {auth, fun menelaus_stats:handle_bucket_stats/3,
                              [Id, all]};
                         ["poolsStreaming", Id] ->
                             {auth, fun handle_pool_info_streaming/2, [Id]};
                         ["pools", PoolId, "buckets"] ->
                             {auth, fun handle_bucket_list/2, [PoolId]};
                         ["pools", PoolId, "buckets", Id] ->
                             {auth_bucket, fun handle_bucket_info/3,
                              [PoolId, Id]};
                         ["pools", PoolId, "bucketsStreaming", Id] ->
                             {auth_bucket, fun handle_bucket_info_streaming/3,
                              [PoolId, Id]};
                         ["pools", PoolId, "buckets", Id, "stats"] ->
                             {auth, fun menelaus_stats:handle_bucket_stats/3,
                              [PoolId, Id]};  %% todo: seems broken
                         ["logs"] ->
                             {auth, fun menelaus_alert:handle_logs/1};
                         ["alerts"] ->
                             {auth, fun menelaus_alert:handle_alerts/1};
                         ["settings", "web"] ->
                             {auth, fun handle_settings_web/1};
                         ["settings", "advanced"] ->
                             {auth, fun handle_settings_advanced/1};
                         ["t", "index.html"] ->
                             {done, serve_index_html_for_tests(Req, DocRoot)};
                         ["index.html"] ->
                             {done, serve_static_file(Req, {DocRoot, Path},
                                                      "text/html; charset=utf8",
                                                      [{"Pragma", "no-cache"},
                                                       {"Cache-Control", "no-cache must-revalidate"}])};
                         _ ->
                             {done, Req:serve_file(Path, DocRoot, [{"Pragma", "no-cache"},
                                                                   {"Cache-Control", "no-cache must-revalidate"}])}
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
                             {done, Req:respond({405, [], ""})};
                         ["pools", _PoolId, "controller", "testWorkload"] ->
                             {auth, fun handle_traffic_generator_control_post/1};
                         ["controller", "ejectNode"] ->
                             {auth, fun handle_eject_post/1};
                         ["pools", PoolId, "buckets", Id] ->
                             {auth_bucket, fun handle_bucket_update/3,
                              [PoolId, Id]};
                         ["pools", PoolId, "buckets"] ->
                             {auth_bucket, fun handle_bucket_update/2,
                              [PoolId]};
                         ["pools", PoolId, "buckets", Id, "controller", "doFlush"] ->
                             {auth_bucket, fun handle_bucket_flush/3,
                              [PoolId, Id]};
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
                              {done, Req:respond({405, [], "Method Not Allowed"})}
                     end;
                 'PUT' ->
                     case PathTokens of
                         _ ->
                             ns_log:log(?MODULE, 0003, "Invalid put received: ~p", [Req]),
                             {done, Req:respond({405, [], "Method Not Allowed"})}
                     end;
                 _ ->
                     ns_log:log(?MODULE, 0004, "Invalid request received: ~p", [Req]),
                     {done, Req:respond({405, [], "Method Not Allowed"})}
             end,
    case Action of
        {done, RV} -> RV;
        {auth, F} -> menelaus_auth:apply_auth(Req, F, []);
        {auth, F, Args} -> menelaus_auth:apply_auth(Req, F, Args);
        {auth_bucket, F} -> menelaus_auth:apply_auth_bucket(Req, F, []);
        {auth_bucket, F, Args} -> menelaus_auth:apply_auth_bucket(Req, F, Args)
    end.

%% Internal API

implementation_version() ->
    list_to_binary(proplists:get_value(menelaus,ns_info:version())).

handle_pools(Req) ->
    reply_json(Req, build_pools()).

build_pools() ->
    Pools = lists:map(fun ({Name, _}) ->
                              {struct,
                               [{name, list_to_binary(Name)},
                                {uri, list_to_binary("/pools/" ++ Name)},
                                {streamingUri,
                                 list_to_binary("/poolsStreaming/" ++ Name)}]}
                      end,
                      expect_config(pools)),
    {struct, [{implementationVersion, implementation_version()},
              {componentsVersion, {struct,
                                   lists:map(fun ({K,V}) ->
                                                     {K, list_to_binary(V)}
                                             end,
                                             proplists:delete(menelaus, ns_info:version()))}},
              {pools, Pools}]}.

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

build_pool_info(Id, _UserPassword) ->
    MyPool = find_pool_by_id(Id),
    Nodes = build_nodes_info(MyPool, true),
    BucketsInfo = {struct, [{uri,
                             list_to_binary("/pools/" ++ Id ++ "/buckets")}]},
    {struct, [{name, list_to_binary(Id)},
              {nodes, Nodes},
              {buckets, BucketsInfo},
              {controllers, {struct,
                             [{ejectNode, {struct, [{uri, <<"/controller/ejectNode">>}]}},
                              {testWorkload, {struct,
                                             [{uri,
                                               list_to_binary("/pools/" ++ Id ++ "/controller/testWorkload")}]}}]}},
              %%
              {stats, {struct,
                       [{uri,
                         list_to_binary("/pools/" ++ Id ++ "/stats")}]}}]}.

find_pool_by_id(Id) -> expect_prop_value(Id, expect_config(pools)).

build_nodes_info(MyPool, IncludeOtp) ->
    OtpCookie = list_to_binary(atom_to_list(ns_node_disco:cookie_get())),
    WantENodes = ns_node_disco:nodes_wanted(),
    ActualENodes = ns_node_disco:nodes_actual_proper(),
    {InfoList, _} = rpc:multicall(ActualENodes, ns_info, basic_info, [], 200),
    BucketsAll = expect_prop_value(buckets, MyPool),
    NodesBucketMemoryTotal =
        length(WantENodes) *
            lists:foldl(fun({_BucketName, BucketConfig}, Acc) ->
                                Acc + proplists:get_value(size_per_node, BucketConfig, 0)
                        end,
                        0,
                        BucketsAll),
    NodesBucketMemoryAllocated = NodesBucketMemoryTotal * 0.75, % TODO: Get from stats_aggregator, all buckets for this node.
    Nodes =
        lists:map(
          fun(WantENode) ->
                  {_Name, Host} = misc:node_name_host(WantENode),
                  %% TODO: more granular, more efficient node status
                  %%       that's not O(N^2).
                  Status = case lists:member(WantENode, ActualENodes) of
                               true -> <<"healthy">>;
                               false -> <<"unhealthy">>
                           end,
                  {value, DirectPort} = direct_port(WantENode),
                  ProxyPort = pool_proxy_port(MyPool, WantENode),
                  InfoNode = proplists:get_value(WantENode, InfoList, []),
                  Versions = proplists:get_value(version, InfoNode, []),
                  Version = proplists:get_value(ns_server, Versions, "unknown"),
                  UpSecs = proplists:get_value(wall_clock, InfoNode, 0),
                  OS = proplists:get_value(system_arch, InfoNode, "unknown"),
                  {MemoryTotal, MemoryAlloced, _} =
                      proplists:get_value(memory_data, InfoNode,
                                          {0, 0, undefined}),
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
    F = fun() -> build_pool_info(Id, UserPassword) end,
    handle_streaming(F, Req, undefined, 3000).

handle_streaming(F, Req, LastRes, Wait) ->
    HTTPRes = Req:ok({"application/json; charset=utf-8",
                      server_header(),
                      chunked}),
    %% Register to get config state change messages.
    menelaus_event:register_watcher(self()),
    Sock = Req:get(socket),
    inet:setopts(Sock, [{active, true}]),
    handle_streaming(F, Req, HTTPRes, LastRes, Wait).

handle_streaming(F, Req, HTTPRes, LastRes, Wait) ->
    Res = F(),
    case Res =:= LastRes of
        true -> ok;
        false ->
            error_logger:info_msg("menelaus_web streaming: ~p~n",
                                  [Res]),
            HTTPRes:write_chunk(mochijson2:encode(Res)),
            %% TODO: resolve why mochiweb doesn't support zero chunk... this
            %%       indicates the end of a response for now
            HTTPRes:write_chunk("\n\n\n\n")
    end,
    receive
        {notify_watcher, _} -> ok;
        _ ->
            error_logger:info_msg("menelaus_web streaming socket closed~n"),
            exit(normal)
    after Wait -> ok
    end,
    handle_streaming(F, Req, HTTPRes, Res, Wait).

all_accessible_buckets(PoolId, Req) ->
    MyPool = find_pool_by_id(PoolId),
    UserPassword = menelaus_auth:extract_auth(Req),
    IsSuper = menelaus_auth:check_auth(UserPassword),
    BucketsAll = expect_prop_value(buckets, MyPool),
    %% We got this far, so we assume we're authorized.
    %% Only emit the buckets that match our UserPassword;
    %% or, emit all buckets if our UserPassword matches the rest_creds
    %% or, emit all buckets if we're not secure.
    case {IsSuper, UserPassword} of
        {true, _}      -> BucketsAll;
        {_, undefined} -> BucketsAll;
        {_, {_User, _Password} = UserPassword} ->
            lists:filter(
              menelaus_auth:bucket_auth_fun(UserPassword),
              BucketsAll)
    end.

handle_bucket_list(Id, Req) ->
    Buckets = all_accessible_buckets(Id, Req),
    BucketsInfo = [build_bucket_info(Id, Name, undefined)
                   || Name <- proplists:get_keys(Buckets)],
    reply_json(Req, BucketsInfo).

find_bucket_by_id(Pool, Id) ->
    Buckets = expect_prop_value(buckets, Pool),
    expect_prop_value(Id, Buckets).

handle_bucket_info(PoolId, Id, Req) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    reply_json(Req, build_bucket_info(PoolId, Id, UserPassword)).

build_bucket_info(PoolId, Id, _UserPassword) ->
    Pool = find_pool_by_id(PoolId),
    _Bucket = find_bucket_by_id(Pool, Id),
    StatsUri = list_to_binary("/pools/"++PoolId++"/buckets/"++Id++"/stats"),
    Nodes = build_nodes_info(Pool, false),
    List1 = [{name, list_to_binary(Id)},
             {uri, list_to_binary("/pools/" ++ PoolId ++
                                  "/buckets/" ++ Id)},
             {streamingUri, list_to_binary("/pools/" ++ PoolId ++
                                           "/bucketsStreaming/" ++ Id)},
             %% TODO: this should be under a controllers/ kind of namespacing
             {flushCacheUri, list_to_binary("/pools/" ++ PoolId ++
                                           "/buckets/" ++ Id ++ "/controller/doFlush")},
             %% TODO: move this somewhere else
             %% {passwordUri, <<"none">>},
             {basicStats, {struct, menelaus_stats:basic_stats(PoolId, Id)}},
             {nodes, Nodes},
             {stats, {struct, [{uri, StatsUri}]}}],
    List2 = case tgen:is_traffic_bucket(PoolId, Id) of
                true -> [{testAppBucket, true},
                         {controlURL, list_to_binary("/pools/"++PoolId++
                                                     "/controller/testWorkload")},
                         {status, tgen:traffic_started()}
                         | List1];
                _ -> List1
            end,
    {struct, List2}.

handle_bucket_info_streaming(PoolId, Id, Req) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    F = fun() -> build_bucket_info(PoolId, Id, UserPassword) end,
    handle_streaming(F, Req, undefined, 3000).

handle_bucket_delete(PoolId, BucketId, Req) ->
    case mc_bucket:bucket_delete(PoolId, BucketId) of
        true ->
            ns_log:log(?MODULE, 0011, "Deleted bucket ~p from pool ~p",
                       [BucketId, PoolId]),
            Req:respond({204, [], []});
        false ->
            %% if bucket isn't found
            Req:respond({404, [], "The bucket to be deleted was not found.\r\n"})
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
                true  -> Req:respond({200, [], []}); % No change.
                false -> ns_log:log(?MODULE, 0010, "bucket updated: ~p in: ~p",
                                    [BucketId, PoolId]),
                         mc_bucket:bucket_config_make(PoolId,
                                                      BucketId,
                                                      BucketConfig2),
                         Req:respond({200, [], []})
            end
    end.

handle_bucket_update(PoolId, Req) ->
    PostArgs = Req:parse_post(),
    case proplists:get_value("name", PostArgs) of
        undefined -> Req:respond({400, [], []});
        <<>>      -> Req:respond({400, [], []});
        BucketId  -> handle_bucket_create(PoolId, BucketId, Req)
    end.

handle_bucket_create(_PoolId, [$_ | _], Req) ->
    % Bucket name cannot have a leading underscore character.
    Req:respond({400, [], []});

handle_bucket_create(PoolId, BucketId, Req) ->
    PostArgs = Req:parse_post(),
    Pass = proplists:get_value("password", PostArgs),
    % Input bucket name and password cannot have whitespace.
    case {is_clean(BucketId, false, 1), is_clean(Pass, true, 1)} of
        {true, true} -> handle_bucket_create_do(PoolId, BucketId, Req);
        _ -> Req:respond({400, [], []})
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
                  case proplists:get_value("size", PostArgs) of
                      undefined -> C;
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
        ok    -> Req:respond({204, [], []});
        false -> Req:respond({404, [], []})
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
    OtherHost = proplists:get_value("clusterMemberHostIp", Params),
    OtherPort = proplists:get_value("clusterMemberPort", Params),
    OtherUser = proplists:get_value("user", Params),
    OtherPswd = proplists:get_value("password", Params),
    case lists:member(undefined,
                      [OtherHost, OtherPort, OtherUser, OtherPswd]) of
        true  -> ns_log:log(?MODULE, 0013, "Received request to join cluster missing a parameter.", [Params]),
                 Req:respond({400, [], "Attempt to join node to cluster received with missing parameters.\n"});
        false -> handle_join(Req, OtherHost, OtherPort, OtherUser, OtherPswd)
    end.

handle_join(Req, OtherHost, OtherPort, OtherUser, OtherPswd) ->
    case tgen:system_joinable() of
        true ->
            case menelaus_rest:rest_get_otp(OtherHost, OtherPort,
                                            {OtherUser, OtherPswd}) of
                {ok, undefined, _} -> Req:respond({401, [], []});
                {ok, _, undefined} -> Req:respond({401, [], []});
                {ok, N, C} ->
                    handle_join(Req,
                                list_to_atom(binary_to_list(N)),
                                list_to_atom(binary_to_list(C)));
                _ -> Req:respond({401, [], []})
            end;
        false ->
            % We are not an 'empty' node, so user should first remove
            % buckets, etc.
            Req:respond({401, [], []})
    end.

handle_join(Req, OtpNode, OtpCookie) ->
    case ns_cluster:join(OtpNode, OtpCookie) of
        ok -> ns_log:log(?MODULE, 0009, "Joined cluster at node: ~p with cookie: ~p from node: ~p",
                         [OtpNode, OtpCookie, erlang:node()]),
              % No need to restart here, as our ns_config event watcher
              % will do it if our rest config changes.
              Req:respond({200, [], []});
        _  -> Req:respond({401, [], []})
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
        undefined -> Req:respond({400, [], "Bad Request\n"});
        "Self" -> do_eject_myself();
        OtpNodeStr ->
            OtpNode = list_to_atom(OtpNodeStr),
            case OtpNode =:= node() of
                true ->
                    % Cannot eject ourselves.
                    Req:respond({400, [], "Bad Request\n"});
                false ->
                    case lists:member(OtpNode, ns_node_disco:nodes_wanted()) of
                        true ->
                            ok = ns_cluster:leave(OtpNode),
                            ns_log:log(?MODULE, 0013, "Node ejected: ~p from node: ~p",
                                       [OtpNode, erlang:node()]),
                            Req:respond({200, [], []});
                        false ->
                            % Node doesn't exist.
                            Req:respond({400, [], []})
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
    Port = ns_config:search_prop(Config, rest, port),
    build_settings_web(Port, U, P).

build_settings_web(Port, U, P) ->
    {struct, [{port, Port},
              {username, list_to_binary(U)},
              {password, list_to_binary(P)}]}.

handle_settings_web_post(Req) ->
    PostArgs = Req:parse_post(),
    Port = proplists:get_value("port", PostArgs),
    U = proplists:get_value("username", PostArgs),
    P = proplists:get_value("password", PostArgs),
    case lists:member(undefined, [Port, U, P]) of
        true -> Req:respond({400, [], []});
        false ->
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
    case (ok =:= menelaus_alert:handle_alerts_settings_post(PostArgs)) andalso
         (ok =:= handle_port_settings_post(PostArgs, "default")) of
        true  -> Req:respond({200, [], []});
        false -> Req:respond({400, [], []})
    end.

build_port_settings(PoolId) ->
    PoolConfig = find_pool_by_id(PoolId),
    [{proxyPort, proplists:get_value(port, PoolConfig)},
     {directPort, list_to_integer(mc_pool:memcached_port(ns_config:get(),
                                                         node()))}].

handle_port_settings_post(PostArgs, PoolId) ->
    PPort = proplists:get_value("proxyPort", PostArgs),
    DPort = proplists:get_value("directPort", PostArgs),
    case lists:member(undefined, [PPort, DPort]) of
        true -> error;
        false ->
            Config = ns_config:get(),
            Pools = mc_pool:pools_config_get(Config),
            Pool = mc_pool:pool_config_get(Pools, PoolId),
            Pool2 = lists:keystore(port, 1, Pool,
                                   {port, list_to_integer(PPort)}),
            mc_pool:pools_config_set(
              mc_pool:pool_config_set(Pools, PoolId, Pool2)),
            mc_pool:memcached_port_set(Config, undefined, DPort),
            ok
    end.

handle_traffic_generator_control_post(Req) ->
    PostArgs = Req:parse_post(),
    case proplists:get_value("onOrOff", PostArgs) of
        "off" -> ns_log:log(?MODULE, 0006, "Stopping workload from node ~p",
                            [erlang:node()]),
                 tgen:traffic_stop(),
                 Req:respond({204, [], []});
        "on" -> ns_log:log(?MODULE, 0007, "Starting workload from node ~p",
                           [erlang:node()]),
                % TODO: Use rpc:multicall here to turn off traffic
                %       generation across all actual nodes in the cluster.
                tgen:traffic_start(),
                Req:respond({204, [], []});
        _ ->
            ns_log:log(?MODULE, 0008, "Invalid post to testWorkload controller.  PostArgs ~p evaluated to ~p",
                       [PostArgs, proplists:get_value(PostArgs, "onOrOff")]),
            Req:respond({400, [], "Bad Request\n"})
    end.

% Make sure an input parameter string is clean and not too long.
% Second argument means "undefinedIsAllowed"

is_clean(undefined, true, _MinLen)  -> true;
is_clean(undefined, false, _MinLen) -> false;
is_clean(S, _UndefinedIsAllowed, MinLen) ->
    Len = length(S),
    (Len >= MinLen) andalso (Len < 80) andalso (S =:= (S -- " \t\n")).

-ifdef(EUNIT).

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

-endif.

-include_lib("kernel/include/file.hrl").

%% stolen from mochiweb_request.erl maybe_serve_file/2
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

