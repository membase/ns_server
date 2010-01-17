%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_web).
-author('Northscale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test/0]).
-import(menelaus_util,
        [test_under_debugger/0, debugger_apply/2,
         wrap_tests_with_cache_setup/1]).
-endif.

-export([start/1, stop/0, loop/2]).

-import(simple_cache, [call_simple_cache/2]).

-import(menelaus_util,
        [server_header/0,
         redirect_permanently/2,
         redirect_permanently/3,
         reply_json/2,
         expect_config/1,
         expect_prop_value/2,
         get_option/2,
         direct_port/1,
         java_date/0,
         string_hash/1,
         my_seed/1,
         stateful_map/3,
         stateful_takewhile/3,
         low_pass_filter/2,
         caching_result/2]).

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
                             {auth, fun handle_bucket_stats/3, ["asd", Id]};
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
                             {auth, fun handle_bucket_stats/3, [PoolId, Id]};
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
                             {auth, fun menelaus_alert:handle_alerts_settings_post/1};
                         ["pools", _, "buckets", _, "generatorControl"] ->
                             {auth, fun handle_traffic_generator_control_post/1};
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

serve_index_html_for_tests(Req, DocRoot) ->
    case file:read_file(DocRoot ++ "/index.html") of
        {ok, Data} ->
            StringData = re:replace(binary_to_list(Data),
                                    "js/all.js\"", "js/t-all.js\""),
            Req:ok({"text/html", list_to_binary(StringData)});
        _ -> {Req:not_found()}
    end.

handle_pools(Req) ->
    reply_json(Req, build_pools()).

build_pools() ->
    Pools = lists:map(fun ({Name, _}) ->
                              {struct, [{name, list_to_binary(Name)},
                                        {uri, list_to_binary("/pools/" ++ Name)},
                                        {streamingUri, list_to_binary("/poolsStreaming/" ++ Name)}]}
                      end,
                      expect_config(pools)),
    {struct, [
              %% TODO: pull this from git describe
              {implementationVersion, <<"comes_from_git_describe">>},
              {pools, Pools}]}.

find_pool_by_id(Id) -> expect_prop_value(Id, expect_config(pools)).

build_nodes_info(MyPool, IncludeOtp) ->
    OtpCookie = list_to_binary(atom_to_list(ns_node_disco:cookie_get())),
    WantENodes = ns_node_disco:nodes_wanted(),
    ActualENodes = ns_node_disco:nodes_actual_proper(),
    ProxyPort = expect_prop_value(port, MyPool),
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
                  KV1 = [{hostname, list_to_binary(Host)},
                         {status, Status},
                         {ports,
                          {struct, [{proxy, ProxyPort},
                                    {direct, DirectPort}]}}],
                  KV2 = case IncludeOtp of
                               true ->
                                %% TODO: convert to camelcase
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

build_pool_info(Id, _UserPassword) ->
    MyPool = find_pool_by_id(Id),
    Nodes = build_nodes_info(MyPool, true),
    BucketsInfo = {struct, [{uri, list_to_binary("/pools/" ++ Id ++ "/buckets")}]},
    {struct, [{name, list_to_binary(Id)},
              {nodes, Nodes},
              {buckets, BucketsInfo},
              {stats, {struct,
                       [{uri, list_to_binary("/pools/" ++ Id ++ "/stats")}]}}]}.

handle_pool_info(Id, Req) ->
    UserPassword = menelaus_auth:extract_auth(Req),
    reply_json(Req, build_pool_info(Id, UserPassword)).

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
                                 {name, list_to_binary(Name)},
                                 {basicStats, {struct, [{cacheSize, 64},
                                                        {opsPerSec, 100},
                                                        {evictionsPerSec, 5},
                                                        {cachePercentUsed, 50}]}},
                                 {sampleConnectionString, <<"fake connection string">>}]}
                   || Name <- proplists:get_keys(Buckets)],
	reply_json(Req, BucketsInfo).

handle_pool_info_streaming(Id, Req) ->
    %% TODO: this shouldn't be timer driven, but rather should
    %% register a callback based on some state change in the Erlang OS
    HTTPRes = Req:ok({"application/json; charset=utf-8",
                      server_header(),
                      chunked}),
    UserPassword = menelaus_auth:extract_auth(Req),
    Res = build_pool_info(Id, UserPassword),
    HTTPRes:write_chunk(mochijson2:encode(Res)),
    %% TODO: resolve why mochiweb doesn't support zero chunk... this
    %%       indicates the end of a response for now
    HTTPRes:write_chunk("\n\n\n\n"),
    handle_pool_info_streaming(Id, Req, HTTPRes, 3000).

handle_pool_info_streaming(Id, Req, HTTPRes, Wait) ->
    receive
    after Wait ->
            UserPassword = menelaus_auth:extract_auth(Req),
            Res = build_pool_info(Id, UserPassword),
            HTTPRes:write_chunk(mochijson2:encode(Res)),
            %% TODO: resolve why mochiweb doesn't support zero chunk... this
            %%       indicates the end of a response for now
            HTTPRes:write_chunk("\n\n\n\n")
    end,
    handle_pool_info_streaming(Id, Req, HTTPRes, 10000).

find_bucket_by_id(Pool, Id) ->
    Buckets = expect_prop_value(buckets, Pool),
    expect_prop_value(Id, Buckets).

handle_bucket_info(PoolId, Id, Req) ->
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
    Res = {struct, List2},
    reply_json(Req, Res).

handle_bucket_info_streaming(_PoolId, Id, Req) ->
    %% TODO: this shouldn't be timer driven, but rather should register a callback based on some state change in the Erlang OS
    HTTPRes = Req:ok({"application/json; charset=utf-8",
                      server_header(),
                      chunked}),
    UserPassword = menelaus_auth:extract_auth(Req),
    Res = build_pool_info(Id, UserPassword),
    HTTPRes:write_chunk(mochijson2:encode(Res)),
    %% TODO: resolve why mochiweb doesn't support zero chunk... this
    %%       indicates the end of a response for now
    HTTPRes:write_chunk("\n\n\n\n"),
    handle_bucket_info_streaming(_PoolId, Id, Req, HTTPRes, 3000).

handle_bucket_info_streaming(_PoolId, Id, Req, HTTPRes, Wait) ->
    receive
    after Wait ->
            UserPassword = menelaus_auth:extract_auth(Req),
            Res = build_pool_info(Id, UserPassword),
            HTTPRes:write_chunk(mochijson2:encode(Res)),
            %% TODO: resolve why mochiweb doesn't support zero chunk... this
            %%       indicates the end of a response for now
            HTTPRes:write_chunk("\n\n\n\n")
    end,
    handle_pool_info_streaming(Id, Req, HTTPRes, 10000).

generate_samples(Seed, Size) ->
    RawSamples = stateful_map(fun (_, S) ->
                                      {F, S2} = random:uniform_s(S),
                                      {F*100, S2}
                              end,
                              Seed,
                              lists:seq(0, Size)),
    lists:map(fun trunc/1, low_pass_filter(0.5, RawSamples)).

mk_samples(Mode) ->
    Key = lists:concat(["samples_for_", Mode]),
    Computation = fun () ->
                          stateful_map(fun (Label, N) ->
                                               {{Label, generate_samples(my_seed(N*string_hash(Mode)), 20)},
                                                N+1}
                                       end,
                                       16#a21,
                                       [gets, misses, sets, ops])
                  end,
    caching_result(Key, Computation).

build_bucket_stats_response(_Id, Params, Now) ->
    OpsPerSecondZoom = case proplists:get_value("opsPerSecondZoom", Params) of
                           undefined -> "1hr";
                           Val -> Val
                       end,
    Samples = mk_samples(OpsPerSecondZoom),
    SamplesSize = length(element(2, hd(Samples))),
    SamplesInterval = case OpsPerSecondZoom of
                          "now" -> 5000;
                          "24hr" -> 86400000 div SamplesSize;
                          "1hr" -> 3600000 div SamplesSize
                      end,
    StartTstampParam = proplists:get_value("opsbysecondStartTStamp", Params),
    {LastSampleTstamp, CutNumber} = case StartTstampParam of
                    undefined -> {Now, SamplesSize};
                    _ ->
                        StartTstamp = list_to_integer(StartTstampParam),
                        CutMsec = Now - StartTstamp,
                        if
                            ((CutMsec > 0) andalso (CutMsec < SamplesInterval*SamplesSize)) ->
                                N = trunc(CutMsec/SamplesInterval),
                                {StartTstamp + N * SamplesInterval, N};
                            true -> {Now, SamplesSize}
                        end
                end,
    Rotates = (Now div 1000) rem SamplesSize,
    CutSamples = lists:map(fun ({K, S}) ->
                                   V = case SamplesInterval of
                                           1 -> lists:sublist(lists:append(S, S), Rotates + 1, SamplesSize);
                                           _ -> S
                                       end,
                                   NewSamples = lists:sublist(V, SamplesSize-CutNumber+1, CutNumber),
                                   {K, NewSamples}
                           end,
                           Samples),
    {struct, [{hot_keys, [{struct, [{name, <<"user:image:value">>},
                                    {gets, 10000},
                                    {bucket, <<"Excerciser application">>},
                                    {misses, 100},
                                    {type, <<"Persistent">>}]},
                          {struct, [{name, <<"user:image:value2">>},
                                    {gets, 10000},
                                    {bucket, <<"Excerciser application">>},
                                    {misses, 100},
                                    {type, <<"Cache">>}]},
                          {struct, [{name, <<"user:image:value3">>},
                                    {gets, 10000},
                                    {bucket, <<"Excerciser application">>},
                                    {misses, 100},
                                    {type, <<"Persistent">>}]},
                          {struct, [{name, <<"user:image:value4">>},
                                    {gets, 10000},
                                    {bucket, <<"Excerciser application">>},
                                    {misses, 100},
                                    {type, <<"Cache">>}]}]},
              {op, {struct, [{tstamp, LastSampleTstamp},
                             {samplesInterval, SamplesInterval}
                             | CutSamples]}}]}.

-ifdef(EUNIT).

generate_samples_test() ->
    V = generate_samples({1,2,3}, 10),
    io:format("V=~p~n", [V]),
    ?assertEqual([0,1,39,22,48,48,73,77,74,77,88], V).

mk_samples_basic_test() ->
    V = mk_samples("now"),
    ?assertMatch([{gets, _},
                  {misses, _},
                  {sets, _},
                  {ops, _}],
                 V).

build_bucket_stats_response_cutting_1_test() ->
    Now = 1259747673659,
    Res = build_bucket_stats_response("4",
                                      [{"opsPerSecondZoom", "now"},
                                       {"keysOpsPerSecondZoom", "now"},
                                       {"opsbysecondStartTStamp", "1259747672559"}],
                                      Now),
    ?assertMatch({struct, [{hot_keys, _},
                           {op, _}]},
                 Res),
    {struct, [_, {op, Ops}]} = Res,
    ?assertMatch({struct, [{tstamp, 1259747673559},
                           {samples_interval, 1},
                           {gets, [_]},
                           {misses, [_]},
                           {sets, [_]},
                           {ops, [_]}]},
                 Ops).

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

-endif.

handle_bucket_stats(_PoolId, Id, Req) ->
    Now = java_date(),
    Params = Req:parse_qs(),
    Res = build_bucket_stats_response(Id, Params, Now),
    reply_json(Req, Res).


handle_traffic_generator_control_post(Req) ->
    PostArgs = Req:parse_post(),
    case proplists:get_value(PostArgs, "onOrOff") of
        "off" -> tgen:traffic_stop();
        "on" -> tgen:traffic_start()
    end,
    Req:respond({200, [], []}).

