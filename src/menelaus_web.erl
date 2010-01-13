%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_web).
-author('Northscale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").
-ifdef(EUNIT).
-export([test_under_debugger/0, debugger_apply/2, test/0]).
-endif.

-export([start/1, stop/0, loop/2]).

-import(simple_cache, [call_simple_cache/2]).

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
                             {need_auth_bucket, fun handle_pools/1};
                         ["pools", Id] ->
                             {need_auth_bucket, fun handle_pool_info/2, [Id]};
                         ["pools", Id, "stats"] ->
                             {need_auth, fun handle_bucket_stats/3, ["asd", Id]};
                         ["poolsStreaming", Id] ->
                             {need_auth, fun handle_pool_info_streaming/2, [Id]};
                         ["pools", PoolId, "buckets", Id] ->
                             {need_auth_bucket, fun handle_bucket_info/3, [PoolId, Id]};
                         ["pools", PoolId, "buckets", Id, "stats"] ->
                             {need_auth, fun handle_bucket_stats/3, [PoolId, Id]};
                         ["alerts"] ->
                             {need_auth, fun handle_alerts/1};
                         ["t", "index.html"] ->
                             {done, serve_index_html_for_tests(Req, DocRoot)};
                         _ ->
                             {done, Req:serve_file(Path, DocRoot)}
                     end;
                 'POST' ->
                     case PathTokens of
                         ["alerts", "settings"] ->
                             {need_auth, fun handle_alerts_settings_post/1};
                         ["pools", _, "buckets", _, "generatorControl"] ->
                             {need_auth, fun handle_traffic_generator_control_post/1};
                         _ ->
                             {done, Req:not_found()}
                     end;
                 _ ->
                     {done, Req:respond({501, [], []})}
             end,
    CheckAuth =
        fun (F, Args) ->
                UserPassword = extract_basic_auth(Req),
                case check_auth(UserPassword) of
                    true -> apply(F, Args ++ [Req]);
                    _ -> Req:respond({401, [{"WWW-Authenticate",
                                             "Basic realm=\"api\""}],
                                      []})
                end
        end,
    CheckAuthBucket =
        fun (F, Args) ->
                UserPassword = extract_basic_auth(Req),
                case check_bucket_auth(UserPassword) of
                    true -> apply(F, Args ++ [Req]);
                    _    -> CheckAuth(F, Args)
                end
        end,
    case Action of
        {done, RV} -> RV;
        {need_auth, F} -> CheckAuth(F, []);
        {need_auth, F, Args} -> CheckAuth(F, Args);
        {need_auth_bucket, F} -> CheckAuthBucket(F, []);
        {need_auth_bucket, F, Args} -> CheckAuthBucket(F, Args)
    end.

%% Internal API

serve_index_html_for_tests(Req, DocRoot) ->
    case file:read_file(DocRoot ++ "/index.html") of
        {ok, Data} ->
            StringData = re:replace(binary_to_list(Data), "js/all.js\"", "js/t-all.js\""),
            Req:ok({"text/html", list_to_binary(StringData)});
        _ -> {Req:not_found()}
    end.

% {rest_creds, [{creds, [{"user", [{password, "password"}]},
%                        {"admin", [{password, "admin"}]}]}
%              ]}. % An empty list means no login/password auth check.

check_bucket_auth(UserPassword) ->
    % Default pool only for 1.0.
    case ns_config:search_prop(ns_config:get(), pools, "default", empty) of
        empty -> false;
        Pool ->
            Buckets = proplists:get_value(buckets, Pool),
            lists:any(bucket_auth_fun(UserPassword),
                      Buckets)
    end.

check_auth(UserPassword) ->
    case ns_config:search_prop(ns_config:get(), rest_creds, creds, empty) of
        []    -> true; % An empty list means no login/password auth check.
        empty -> true; % An empty list means no login/password auth check.
        Creds -> check_auth(UserPassword, Creds)
    end.

check_auth(_UserPassword, []) ->
    false;
check_auth({User, Password}, [{User, PropList} | _]) ->
    Password =:= proplists:get_value(password, PropList, "");
check_auth(UserPassword, [_NotRightUser | Rest]) ->
    check_auth(UserPassword, Rest).

extract_basic_auth(Req) ->
    case Req:get_header_value("authorization") of
        []        -> undefined;
        undefined -> undefined;
        "Basic " ++ Value ->
            case string:tokens(base64:decode_to_string(Value), ":") of
                [] -> undefined;
                [User, Password] -> {User, Password}
            end
    end.

redirect_permanently(Path, Req) -> redirect_permanently(Path, Req, []).

%% mostly extracted from mochiweb_request:maybe_redirect/3
redirect_permanently(Path, Req, ExtraHeaders) ->
    %% TODO: support https transparently
    Location = "http://" ++ Req:get_header_value("host") ++ Path,
    LocationBin = list_to_binary(Location),
    Top = <<"<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">"
           "<html><head>"
           "<title>301 Moved Permanently</title>"
           "</head><body>"
           "<h1>Moved Permanently</h1>"
           "<p>The document has moved <a href=\"">>,
    Bottom = <<">here</a>.</p></body></html>\n">>,
    Body = <<Top/binary, LocationBin/binary, Bottom/binary>>,
    Req:respond({301,
                 [{"Location", Location},
                  {"Content-Type", "text/html"} | ExtraHeaders],
                 Body}).

reply_json(Req, Body) ->
    Req:ok({"application/json",
            [{"Server", "NorthScale menelaus %TODO gitversion%"}],
            mochijson2:encode(Body)}).

expect_config(Key) ->
    {value, RV} = ns_config:search(Key),
    RV.

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

handle_pools(Req) ->
    reply_json(Req, build_pools()).

expect_prop_value(K, List) ->
    Ref = make_ref(),
    try
        case proplists:get_value(K, List, Ref) of
            RV when RV =/= Ref -> RV
        end
    catch
        error:X -> erlang:error(X, [K, List])
    end.

find_pool_by_id(Id) -> expect_prop_value(Id, expect_config(pools)).

direct_port(_Node) ->
    case ns_port_server:get_port_server_param(ns_config:get(), memcached, "-p") of
        false ->
            ns_log:log(?MODULE, 0003, "missing memcached port"),
            false;
        {value, MemcachedPortStr} ->
            {value, list_to_integer(MemcachedPortStr)}
    end.

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
                                   KV1 ++ [{otp_node,
                                            list_to_binary(
                                              atom_to_list(WantENode))},
                                           {otp_cookie, OtpCookie}];
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

bucket_auth_fun(UserPassword) ->
    fun({BucketName, BucketProps}) ->
            case proplists:get_value(auth_plain, BucketProps) of
                undefined -> true;
                BucketPassword ->
                    case UserPassword of
                        undefined -> false;
                        {User, Password} ->
                            (BucketName =:= User andalso
                             BucketPassword =:= Password)
                    end
            end
    end.

build_pool_info(Id, UserPassword) ->
    MyPool = find_pool_by_id(Id),
    Nodes = build_nodes_info(MyPool, true),
    IsSuper = check_auth(UserPassword),
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
                  bucket_auth_fun(UserPassword),
                  BucketsAll)
        end,
    BucketsInfo = [{struct, [{uri, list_to_binary("/pools/" ++ Id ++
                                                  "/buckets/" ++ Name)},
                             {name, list_to_binary(Name)}]}
                   || Name <- proplists:get_keys(Buckets)],
    {struct, [{name, list_to_binary(Id)},
              {nodes, Nodes},
              {buckets, BucketsInfo},
              {stats, {struct,
                       [{uri, list_to_binary("/pools/" ++ Id ++ "/stats")}]}}]}.
    %% case Id of
    %%     "default" -> {struct, [{nodes, [{struct, [{hostname, <<"foo1.bar.com">>},
    %%                                               {status, <<"healthy">>},
    %%                                               {ports, {struct, [{proxy, 11211},
    %%                                                                 {direct, 11212}]}}]},
    %%                                     {struct, [{hostname, <<"foo2.bar.com">>},
    %%                                               {status, <<"healthy">>},
    %%                                               {ports, {struct, [{proxy, 11211},
    %%                                                                 {direct, 11212}]}}]}]},
    %%                            {buckets, [{struct, [{uri, <<"/buckets/4">>},
    %%                                                 {name, <<"Excerciser Application">>}]}]},
    %%                            {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=1">>}]}},
    %%                            {name, <<"Default Pool">>}]};
    %%     _ -> {struct, [{nodes, [{struct, [{hostname, <<"foo1.bar.com">>},
    %%                                       {status, <<"healthy">>},
    %%                                       {ports, {struct, [{proxy, 11211},
    %%                                                         {direct, 11212}]}},
    %%                                       % TODO?
    %%                                       {uptime, 123321},
    %%                                       {uri, <<"https://first_node.in.pool.com:80/pool/Another Pool/node/first_node/">>}]},
    %%                    {buckets, [{struct, [{uri, <<"/buckets/5">>},
    %%                                         {name, <<"Excerciser Another">>}]}]},
    %%                    {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=2">>}]}},
    %%                    {name, <<"Another Pool">>}]}
    %% end.

handle_pool_info(Id, Req) ->
    UserPassword = extract_basic_auth(Req),
    reply_json(Req, build_pool_info(Id, UserPassword)).

handle_pool_info_streaming(Id, Req) ->
    %% TODO: this shouldn't be timer driven, but rather should register a callback based on some state change in the Erlang OS
    HTTPRes = Req:ok({"application/json; charset=utf-8",
                      [{"Server", "NorthScale menelaus %TODO gitversion%"}],
                      chunked}),
    UserPassword = extract_basic_auth(Req),
    Res = build_pool_info(Id, UserPassword),
    HTTPRes:write_chunk(mochijson2:encode(Res)),
    %% TODO: resolve why mochiweb doesn't support zero chunk... this
    %%       indicates the end of a response for now
    HTTPRes:write_chunk("\n\n\n\n"),
    handle_pool_info_streaming(Id, Req, HTTPRes, 3000).

handle_pool_info_streaming(Id, Req, HTTPRes, Wait) ->
    receive
    after Wait ->
            UserPassword = extract_basic_auth(Req),
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

%% TODO: ask tgen module instead
is_test_app_bucket(_Pool, BucketName) ->
    BucketName =:= "test_application".
%% true iff test app is running
%% TODO: ask tgen module instead
get_tgen_status() ->
    false.

handle_bucket_info(PoolId, Id, Req) ->
    Pool = find_pool_by_id(PoolId),
    _Bucket = find_bucket_by_id(Pool, Id),
    StatsURI = list_to_binary("/pools/"++PoolId++"/buckets/"++Id++"/stats"),
    Nodes = build_nodes_info(Pool, false),
    List1 = [{name, list_to_binary(Id)},
                    {nodes, Nodes},
                    {stats, {struct, [{uri, StatsURI}]}}],
    List2 = case is_test_app_bucket(Pool, Id) of
                true -> [{testAppBucket, true},
                         {controlURL, list_to_binary("/pools/"++PoolId++"/buckets/"++Id++"/generatorControl")},
                         {status, get_tgen_status()}
                         | List1];
                _ -> List1
            end,
    Res = {struct, List2},
    reply_json(Req, Res).

%% milliseconds since 1970 Jan 1 at UTC
java_date() ->
    {MegaSec, Sec, Micros} = erlang:now(),
    (MegaSec * 1000000 + Sec) * 1000 + (Micros div 1000).

string_hash(String) ->
    lists:foldl((fun (Val, Acc) -> (Acc * 31 + Val) band 16#0fffffff end),
                0,
                String).

my_seed(Number) ->
    {Number*31, Number*13, Number*113}.

%% applies F to every InList element and current state.
%% F must return pair of {new list element value, new current state}.
%% returns pair of {new list, current state}
full_stateful_map(F, InState, InList) ->
    {RV, State} = full_stateful_map_rec(F, InState, InList, []),
    {lists:reverse(RV), State}.

full_stateful_map_rec(_F, State, [], Acc) ->
    {Acc, State};
full_stateful_map_rec(F, State, [H|Tail], Acc) ->
    {Value, NewState} = F(H, State),
    full_stateful_map_rec(F, NewState, Tail, [Value|Acc]).

%% same as full_stateful_map/3, but discards state and returns only transformed list
stateful_map(F, InState, InList) -> element(1, full_stateful_map(F, InState, InList)).

low_pass_filter(Alpha, List) ->
    Beta = 1 - Alpha,
    F = fun (V, Prev) ->
                RV = Alpha*V + Beta*Prev,
                {RV, RV}
        end,
    case List of
        [] -> [];
        [H|Tail] -> [H | stateful_map(F, H, Tail)]
    end.

generate_samples(Seed, Size) ->
    RawSamples = stateful_map(fun (_, S) ->
                                      {F, S2} = random:uniform_s(S),
                                      {F*100, S2}
                              end,
                              Seed,
                              lists:seq(0, Size)),
    lists:map(fun trunc/1, low_pass_filter(0.5, RawSamples)).

caching_result(Key, Computation) ->
    case call_simple_cache(lookup, [Key]) of
        [] -> begin
                  V = Computation(),
                  call_simple_cache(insert, [{Key, V}]),
                  V
              end;
        [{_, V}] -> V
    end.

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

string_hash_test_() ->
    [
     ?_assert(string_hash("hello1") /= string_hash("hi")),
     ?_assert(string_hash("hi") == ($h*31+$i))
    ].

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

wrap_tests_with_cache_setup(Tests) ->
    {spawn, {setup,
             fun () ->
                     simple_cache:start_link()
             end,
             fun (_) ->
                     exit(whereis(simple_cache), die)
             end,
             Tests}}.

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

debugger_apply(Fun, Args) ->
    i:im(),
    {module, _} = i:ii(?MODULE),
    i:iaa([break]),
    ok = i:ib(?MODULE, Fun, length(Args)),
    apply(?MODULE, Fun, Args).

test_under_debugger() ->
    i:im(),
    {module, _} = i:ii(?MODULE),
    i:iaa([init]),
    eunit:test({spawn, {timeout, infinity, {module, ?MODULE}}}, [verbose]).

-endif.

handle_bucket_stats(_PoolId, Id, Req) ->
    Now = java_date(),
    Params = Req:parse_qs(),
    Res = build_bucket_stats_response(Id, Params, Now),
    reply_json(Req, Res).


get_option(Option, Options) ->
    {proplists:get_value(Option, Options), proplists:delete(Option, Options)}.

-define(INITIAL_ALERTS, [{struct, [{number, 3},
                                   {type, <<"info">>},
                                   {tstamp, 1259836260000},
                                   {shortText, <<"Above Average Operations per Second">>},
                                   {text, <<"Licensing, capacity, NorthScale issues, etc.">>}]},
                         {struct, [{number, 2},
                                   {type, <<"attention">>},
                                   {tstamp, 1259836260000},
                                   {shortText, <<"New Node Joined Pool">>},
                                   {text, <<"A new node is now online">>}]},
                         {struct, [{number, 1},
                                   {type, <<"warning">>},
                                   {tstamp, 1259836260000},
                                   {shortText, <<"Server Node Down">>},
                                   {text, <<"Server node is no longer available">>}]}]).
-ifdef(EUNIT).

reset_alerts() ->
    call_simple_cache(delete, [alerts]).

fetch_default_alerts_test() ->
    reset_alerts(),
    ?assertEqual(?INITIAL_ALERTS,
                 fetch_alerts()),

    ?assertEqual(?INITIAL_ALERTS,
                 fetch_alerts()).

create_new_alert_test() ->
    reset_alerts(),
    create_new_alert(),
    List1 = fetch_alerts(),
    ?assertEqual(?INITIAL_ALERTS,
                 tl(List1)),
    ?assertMatch({struct, [{number, 4}|_]},
                 lists:nth(1, List1)),
    ?assertEqual([], lists:nthtail(4, List1)),

    create_new_alert(),
    List2 = fetch_alerts(),
    ?assertEqual(?INITIAL_ALERTS,
                 tl(tl(List2))),
    ?assertMatch({struct, [{number, 5}|_]},
                 lists:nth(1, List2)),
    ?assertMatch({struct, [{number, 4}|_]},
                 lists:nth(2, List2)),
    ?assertEqual([], lists:nthtail(5, List2)).

build_alerts_test() ->
    reset_alerts(),
    ?assertEqual(?INITIAL_ALERTS,
                 tl(build_alerts([]))),

    reset_alerts(),
    ?assertMatch([{struct, [{number, 4} | _]}],
                 build_alerts([{"lastNumber", "3"}])).

-endif.


fetch_alerts() ->
    caching_result(alerts,
                   fun () -> ?INITIAL_ALERTS end).

create_new_alert() ->
    fetch_alerts(), %% side effect
    [{alerts, OldAlerts}] = call_simple_cache(lookup, [alerts]),
    [{struct, [{number, LastNumber} | _]} | _] = OldAlerts,
    NewAlerts = [{struct, [{number, LastNumber+1},
                           {type, <<"attention">>},
                           {tstamp, java_date()},
                           {shortText, <<"Lorem ipsum">>},
                           {text, <<"Lorem ipsum dolor sit amet, consectetur adipiscing elit. Maecenas egestas dictum iaculis.">>}]}
                 | OldAlerts],
    call_simple_cache(insert, [{alerts, NewAlerts}]),
    nil.

stateful_takewhile_rec(_F, [], _State, App) ->
    App;
stateful_takewhile_rec(F, [H|Tail], State, App) ->
    case F(H, State) of
        {true, NewState} ->
            stateful_takewhile_rec(F, Tail, NewState, [H|App]);
        _ -> App
    end.

stateful_takewhile(F, List, State) ->
    lists:reverse(stateful_takewhile_rec(F, List, State, [])).

-define(ALERTS_LIMIT, 15).

build_alerts(Params) ->
    create_new_alert(),
    [{alerts, Alerts}] = call_simple_cache(lookup, [alerts]),
    LastNumber = case proplists:get_value("lastNumber", Params) of
                     undefined -> 0;
                     V -> list_to_integer(V)
                 end,
    Limit = ?ALERTS_LIMIT,
    CutAlerts = stateful_takewhile(fun ({struct, [{number, N} | _]}, Index) ->
                                           {(N > LastNumber) andalso (Index < Limit), Index+1}
                                   end,
                                   Alerts,
                                   0),
    CutAlerts.

fetch_alert_settings() ->
    caching_result(alert_settings,
                   fun () ->
                           [{email, <<"alk@tut.by">>},
                            {sendAlerts, <<"1">>},
                            {sendForLowSpace, <<"1">>},
                            {sendForLowMemory, <<"1">>},
                            {sendForNotResponding, <<"1">>},
                            {sendForJoinsCluster, <<"1">>},
                            {sendForOpsAboveNormal, <<"1">>},
                            {sendForSetsAboveNormal, <<"1">>}]
                   end).

handle_alerts(Req) ->
    reply_json(Req, {struct, [{limit, ?ALERTS_LIMIT},
                              {settings, {struct, [{updateURI, <<"/alerts/settings">>}
                                                   | fetch_alert_settings()]}},
                              {list, build_alerts(Req:parse_qs())}]}).

handle_alerts_settings_post(Req) ->
    PostArgs = Req:parse_post(),
    call_simple_cache(insert, [{alert_settings,
                               lists:map(fun ({K,V}) ->
                                                 {list_to_atom(K), list_to_binary(V)}
                                         end,
                                         PostArgs)}]),
    %% TODO: make it more RESTful
    Req:respond({200, [], []}).


handle_traffic_generator_control_post(Req) ->
    PostArgs = Req:parse_post(),
    case proplists:get_value(PostArgs, "onOrOff") of
        "off" -> tgen:traffic_stop();
        "on" -> tgen:traffic_start()
    end,
    Req:respond({200, [], []}).
