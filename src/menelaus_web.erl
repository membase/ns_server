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

-export([start/1, stop/0, loop/2,
         find_pool_by_id/1,
         find_bucket_by_id/2]).

-import(simple_cache, [call_simple_cache/2]).

-import(menelaus_util,
        [server_header/0,
         redirect_permanently/2,
         redirect_permanently/3,
         reply_json/2,
         parse_json/1,
         expect_config/1,
         expect_prop_value/2,
         get_option/2,
         direct_port/1]).

%% External API

start(Options) ->
    {DocRoot, Options1} = get_option(docroot, Options),
    Loop = fun (Req) ->
                   ?MODULE:loop(Req, DocRoot)
           end,
    mochiweb_http:start([{name, ?MODULE}, {loop, Loop} | Options1]).

stop() ->
    mochiweb_http:stop(?MODULE).

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
                              [PoolId, Id]};
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
                         _ ->
                             {done, Req:serve_file(Path, DocRoot)}
                     end;
                 'POST' ->
                     case PathTokens of
						 ["node", "controller", "doJoinCluster"]  ->
                             {auth, fun handle_join/1};
                         ["settings", "web"] ->
                             {auth, fun handle_settings_web_post/1};
                         ["settings", "advanced"] ->
                             {auth, fun handle_settings_advanced_post/1};
                         ["pools", _PoolId] ->
                             {done, Req:response(403, [], "")};
                         ["pools", _PoolId, "controller", "testWorkload"] ->
                             {auth, fun handle_traffic_generator_control_post/1};
                         ["controller", "ejectNode"] ->
                             {auth, fun handle_eject_post/1};
                         ["pools", PoolId, "buckets", Id] ->
                             {auth_bucket, fun handle_bucket_update/3,
                              [PoolId, Id]};
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
                         ["pools", PoolId, "buckets", Id] ->
                             {auth, fun handle_bucket_update/3, [PoolId, Id]};
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
    %% TODO: pull this from git describe.
    <<"comes_from_git_describe">>.

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
                             [{testWorkload, {struct,
                                             [{uri,
                                               list_to_binary("/pools/" ++ Id ++ "/testWorkload")}]}}]}},
              %%
              {stats, {struct,
                       [{uri,
                         list_to_binary("/pools/" ++ Id ++ "/stats")}]}}]}.

find_pool_by_id(Id) -> expect_prop_value(Id, expect_config(pools)).

build_nodes_info(MyPool, IncludeOtp) ->
    OtpCookie = list_to_binary(atom_to_list(ns_node_disco:cookie_get())),
    WantENodes = ns_node_disco:nodes_wanted(),
    ActualENodes = ns_node_disco:nodes_actual_proper(),
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
                  KV1 = [{hostname, list_to_binary(Host)},
                         {status, Status},
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

handle_bucket_list(Id, Req) ->
    MyPool = find_pool_by_id(Id),
    UserPassword = menelaus_auth:extract_auth(Req),
    IsSuper = menelaus_auth:check_auth(UserPassword),
    BucketsAll = expect_prop_value(buckets, MyPool),
    Buckets =
        % We got this far, so we assume we're authorized.
        % Only emit the buckets that match our UserPassword;
        % or, emit all buckets if our UserPassword matches the rest_creds
        % or, emit all buckets if we're not secure.
        case {IsSuper, UserPassword} of
            {true, _}      -> BucketsAll;
            {_, undefined} -> BucketsAll;
            {_, {_User, _Password} = UserPassword} ->
                lists:filter(
                  menelaus_auth:bucket_auth_fun(UserPassword),
                  BucketsAll)
        end,
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
    StatsURI = list_to_binary("/pools/"++PoolId++"/buckets/"++Id++"/stats"),
    Nodes = build_nodes_info(Pool, false),
    List1 = [{name, list_to_binary(Id)},
             {uri, list_to_binary("/pools/" ++ PoolId ++
                                  "/buckets/" ++ Id)},
             {streamingUri, list_to_binary("/pools/" ++ PoolId ++
                                           "/bucketsStreaming/" ++ Id)},
             %% TODO: undocumented
             {flushCacheURI, list_to_binary("/pools/" ++ PoolId ++
                                           "/buckets/" ++ Id ++ "/controller/doFlush")},
             %% TODO: undocumented
             {passwordURI, <<"none">>},
             {basicStats, {struct, menelaus_stats:basic_stats(PoolId, Id)}},
             {nodes, Nodes},
             {stats, {struct, [{uri, StatsURI}]}}],
    List2 = case tgen:is_traffic_bucket(Pool, Id) of
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
            ns_log:log(?MODULE, 0004, "Deleted bucket ~p from pool ~p",
                       [BucketId, PoolId]),
            Req:respond(204, [], []);
        false ->
            %% if bucket isn't found
            Req:respond(404, [], "The bucket to be deleted was not found.")
    end,
    ok.

handle_bucket_update(PoolId, BucketId, Req) ->
    % There are two ways one would get here, Req will contain a JSON
    % payload
    %
    % A PUT means create/update.  A PUT may be sparse as some things
    % (like memory amount) will fall back to server defaults
    %
    % A POST means modify existing bucket settings.  For 1.0, this will *only*
    % allow changing the password or setting the password to ""
    %
    % The JSON looks like...
    %
    % {"password": "somepassword",
    %  "size_per_node", "64"}
    %
    % An empty password string ("") is the same as undefined auth_plain.
    %
    % TODO: after 1.0: allow password changes via urlencoded post
    %
    % {buckets, [
    %   {"default", [
    %     {auth_plain, undefined},
    %     {size_per_node, 64} % In MB.
    %   ]}
    % ]}
    %
    {struct, Params} = parse_json(Req),
    case mc_bucket:bucket_config_get(mc_pool:pools_config_get(),
                                     PoolId, BucketId) of
        false ->
            % Create...
            BucketConfigDefault = mc_bucket:bucket_config_default(),
            BucketConfig =
                lists:foldl(
                  fun({auth_plain, _}, C) ->
                          V = case proplists:get_value(<<"password">>,
                                                       Params) of
                                  undefined -> undefined;
                                  <<>>      -> undefined;
                                  PasswordB ->
                                      {BucketId, binary_to_list(PasswordB)}
                              end,
                          lists:keystore(auth_plain, 1, C,
                                         {auth_plain, V});
                     ({size_per_node, _}, C) ->
                          case proplists:get_value(<<"size_per_node">>,
                                                   Params) of
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
            Req:respond({200, [], []});
        BucketConfig ->
            % Update, only the auth_plain/password field for 1.0.
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
                false -> mc_bucket:bucket_config_make(PoolId,
                                                      BucketId,
                                                      BucketConfig2),
                         Req:respond({200, [], []})
            end
    end.

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
    Params = Req:parse_qs(),
    OtherHost = proplist:get_value("clusterMemberHostIp", Params),
    OtherPort = proplist:get_value("clusterMemberPort", Params),
    OtherUser = proplist:get_value("user", Params),
    OtherPswd = proplist:get_value("password", Params),
    case lists:member(undefined,
                      [OtherHost, OtherPort, OtherUser, OtherPswd]) of
        true  -> Req:response({400, [], []});
        false -> handle_join(Req, OtherHost, OtherPort, OtherUser, OtherPswd)
    end.

handle_join(Req, OtherHost, OtherPort, OtherUser, OtherPswd) ->
    case tgen:system_joinable() of
        true ->
            case menelaus_rest:rest_get_otp(OtherHost, OtherPort,
                                            {OtherUser, OtherPswd}) of
                {ok, undefined, _} -> Req:response({401, [], []});
                {ok, _, undefined} -> Req:response({401, [], []});
                {ok, N, C} ->
                    handle_join(Req,
                                list_to_atom(binary_to_list(N)),
                                list_to_atom(binary_to_list(C)));
                _ -> Req:response({401, [], []})
            end;
        false ->
            % We are not an 'empty' node, so user should first remove
            % buckets, etc.
            Req:response({401, [], []})
    end.

handle_join(Req, OtpNode, OtpCookie) ->
    case ns_cluster:join(OtpNode, OtpCookie) of
        ok -> ns_log:log(?MODULE, 0009, "Joined cluster at node: ~p with cookie: ~p from node: ~p",
                         [OtpNode, OtpCookie, erlang:node()]),
              % TODO: Need to restart menelaus?  emoxi?
              % ns_port_server?  Or, let ns_node_config events
              % handle it.
              Req:respond({200, [], []});
        _  -> Req:respond({401, [], []})
    end.

handle_eject_post(Req) ->
    PostArgs = Req:parse_post(),
    %
    % either Eject a running node, or eject a node which is down.
    %
    % request is a urlencoded form with just clusterMemberHostIp
    %
    % responses are 200 when complete
    %               401 if creds were not supplied and are required
    %               403 if creds were supplied and are incorrect
    %               400 if the node to be ejected doesn't exist
    %
    case proplists:get_value("otpNode", PostArgs) of
        undefined -> Req:respond({400, [], "Bad Request\n"});
        OtpNodeB ->
            OtpNode = list_to_atom(OtpNodeB),
            case OtpNode =:= node() of
                true ->
                    % Cannot eject ourselves.
                    Req:respond({400, [], "Bad Request\n"});
                false ->
                    case lists:member(OtpNode, ns_node_disco:nodes_wanted()) of
                        true ->
                            ok = ns_cluster:leave(OtpNode),
                            Req:respond({200, [], []});
                        false ->
                            % Node doesn't exist.
                            Req:respond({400, [], []})
                    end
            end
    end.

handle_settings_web(Req) ->
    Req:reply_json(build_settings_web()).

build_settings_web() ->
    Config = ns_config:get(),
    {U, P} = case ns_config:search_prop(Config, rest_cred, creds) of
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
                    ns_config:set(rest_creds,
                                  [{creds,
                                    [{U, [{password, P}]}]}])
                    % TODO: Need to restart menelaus?
            end,
            Req:respond({200, [], []})
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

-ifdef(EUNIT).

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

-endif.

serve_index_html_for_tests(Req, DocRoot) ->
    case file:read_file(DocRoot ++ "/index.html") of
        {ok, Data} ->
            StringData = re:replace(binary_to_list(Data),
                                    "js/all.js\"", "js/t-all.js\""),
            Req:ok({"text/html", list_to_binary(StringData)});
        _ -> {Req:not_found()}
    end.

