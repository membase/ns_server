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
                         [] -> {done, redirect_permanently("/index.html", Req)};
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
                         ["alerts"] ->
                             {auth, fun menelaus_alert:handle_alerts/1};
                         ["t", "index.html"] ->
                             {done, serve_index_html_for_tests(Req, DocRoot)};
                         _ ->
                             {done, Req:serve_file(Path, DocRoot)}
                     end;
                 'POST' ->
                     case PathTokens of
                         ["alerts", "settings"] ->
                             {auth,
                              fun menelaus_alert:handle_alerts_settings_post/1};
                         ["pools", _, "buckets", _, "generatorControl"] ->
                             {auth,
                              fun handle_traffic_generator_control_post/1};
                         _ ->
                             {done, Req:not_found()}
                     end;
                 _ ->
                     {done, Req:respond({501, [], []})}
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
    HTTPRes = Req:ok({"application/json; charset=utf-8",
                      server_header(),
                      chunked}),
    %% Register to get config state change messages.
    menelaus_event:register_watcher(self()),
    Sock = Req:get(socket),
    inet:setopts(Sock, [{active, true}]),
    handle_pool_info_streaming(Id, Req, UserPassword, HTTPRes,
                               undefined, 3000).

handle_pool_info_streaming(Id, Req, UserPassword, HTTPRes,
                           LastRes, Wait) ->
    Res = build_pool_info(Id, UserPassword),
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
    handle_pool_info_streaming(Id, Req, UserPassword, HTTPRes,
                               Res, Wait).

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
	BucketsInfo = [{struct, [{uri, list_to_binary("/pools/" ++ Id ++
                                                  "/buckets/" ++ Name)},
							 {streamingUri, list_to_binary("/pools/" ++ Id ++
                                                  "/bucketsStreaming/" ++ Name)},
                                 {name, list_to_binary(Name)},
                                 {basicStats,
                                  {struct,
                                   menelaus_stats:basic_stats(Id, Name)}},
                                 {sampleConnectionString,
                                  <<"fake connection string">>}]}
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
                    {nodes, Nodes},
                    {stats, {struct, [{uri, StatsURI}]}}],
    List2 = case tgen:is_traffic_bucket(Pool, Id) of
                true -> [{testAppBucket, true},
                         {controlURL, list_to_binary("/pools/"++PoolId++
                                                     "/buckets/"++Id++
                                                     "/generatorControl")},
                         {status, tgen:traffic_started()}
                         | List1];
                _ -> List1
            end,
    {struct, List2}.

handle_bucket_info_streaming(PoolId, Id, Req) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    HTTPRes = Req:ok({"application/json; charset=utf-8",
                      server_header(),
                      chunked}),
    %% Register to get config state change messages.
    menelaus_event:register_watcher(self()),
    Sock = Req:get(socket),
    inet:setopts(Sock, [{active, true}]),
    handle_bucket_info_streaming(PoolId, Id, Req, UserPassword, HTTPRes,
                                 undefined, 3000).

handle_bucket_info_streaming(PoolId, Id, Req, UserPassword, HTTPRes,
                             LastRes, Wait) ->
    Res = build_bucket_info(PoolId, Id, UserPassword),
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
    handle_bucket_info_streaming(PoolId, Id, Req, UserPassword, HTTPRes,
                                 Res, Wait).

-ifdef(EUNIT).

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

-endif.

handle_traffic_generator_control_post(Req) ->
    PostArgs = Req:parse_post(),
    case proplists:get_value(PostArgs, "onOrOff") of
        "off" -> tgen:traffic_stop();
        "on" -> tgen:traffic_start()
    end,
    Req:respond({200, [], []}).

serve_index_html_for_tests(Req, DocRoot) ->
    case file:read_file(DocRoot ++ "/index.html") of
        {ok, Data} ->
            StringData = re:replace(binary_to_list(Data),
                                    "js/all.js\"", "js/t-all.js\""),
            Req:ok({"text/html", list_to_binary(StringData)});
        _ -> {Req:not_found()}
    end.

