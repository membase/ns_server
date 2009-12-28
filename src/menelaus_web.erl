%% @author Northscale <info@northscale.com>
%% @copyright 2009 Northscale.

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
                             {need_auth, fun handle_pools/1};
                         ["pools", Id] ->
                             {need_auth, fun handle_pool_info/2, [Id]};
                         ["poolsStreaming", Id] ->
                             {need_auth, fun handle_pool_info_streaming/2, [Id]};
                         ["buckets", Id] ->
                             {need_auth, fun handle_bucket_info/2, [Id]};
                         ["buckets", Id, "stats"] ->
                             {need_auth, fun handle_bucket_stats/2, [Id]};
                         ["alerts"] ->
                             {need_auth, fun handle_alerts/1};
                         _ ->
                             {done, Req:serve_file(Path, DocRoot)}
                     end;
                 'POST' ->
                     case PathTokens of
                         ["alerts", "settings"] ->
                             {need_auth, fun handle_alerts_settings_post/1};
                         _ ->
                             {done, Req:not_found()}
                     end;
                 _ ->
                     {done, Req:respond({501, [], []})}
             end,
    CheckAuth = fun (F, Args) ->
                        case check_auth(extract_basic_auth(Req)) of
                            true -> apply(F, Args ++ [Req]);
                            _ -> Req:respond({401, [{"WWW-Authenticate", "Basic realm=\"api\""}], []})
                        end
                end,
    case Action of
        {done, RV} -> RV;
        {need_auth, F} -> CheckAuth(F, []);
        {need_auth, F, Args} -> CheckAuth(F, Args)
    end.

%% Internal API

check_auth(undefined) -> false;
check_auth({User, Password}) ->
    (User =:= "admin") andalso (Password =:= "admin").

extract_basic_auth(Req) ->
    case Req:get_header_value("authorization") of
        undefined -> undefined;
        "Basic " ++ Value ->
            case string:tokens(base64:decode_to_string(Value), ":") of
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

handle_pools(Req) ->
    reply_json(Req, {struct, [
                              %% TODO: pull this from git describe
                              {implementationVersion, <<"comes_from_git_describe">>},
                              {pools, [{struct, [{name, <<"default">>},
                                                 {uri, <<"/pools/default">>},
                                                 {streamingUri, <<"/poolsStreaming/default">>}]},
                                       %% only one pool at first release, this 
                                       %% is just for prototyping
                                       {struct, [{name, <<"Another Pool">>},
                                                 {uri, <<"/pools/Another Pool">>}]}]}]}).

handle_pool_info(Id, Req) ->
    Res = case Id of
              "default" -> {struct, [{nodes, [{struct, [{ipAddress, <<"10.0.1.20">>},
                                                  {status, <<"healthy">>},
                                                  {ports, {struct, [{routing, 11211},
                                                                  {caching, 11311},
                                                                  {kvstore, 11411}]}},
                                                  {name, <<"first_node">>},
                                                  {fqdn, <<"first_node.in.pool.com">>}]},
                                              {struct, [{ipAddress, <<"10.0.1.21">>},
                                                        {status, <<"healthy">>},
                                                        {ports, {struct, [{routing, 11211},
                                                                          {caching, 11311},
                                                                          {kvstore, 11411}]}},
                                                        {uri, <<"/addresses/10.0.1.20">>},
                                                        {name, <<"second_node">>},
                                                        {fqdn, <<"second_node.in.pool.com">>}]}]},
                                {buckets, [{struct, [{uri, <<"/buckets/4">>},
                                                    {name, <<"Excerciser Application">>}]}]},
                                {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=1">>}]}},
                                {name, <<"Default Pool">>}]};
              _ -> {struct, [{nodes, [{struct, [{ipAddress, <<"10.0.1.22">>},
                                               {uptime, 123321},
                                               {status, <<"healthy">>},
                                               {ports, {struct, [{routing, 11211},
                                                                  {caching, 11311},
                                                                  {kvstore, 11411}]}},
                                               {uri, <<"https://first_node.in.pool.com:80/pool/Another Pool/node/first_node/">>},
                                               {name, <<"first_node">>},
                                               {fqdn, <<"first_node.in.pool.com">>}]}, {struct, [{ipAddress, <<"10.0.1.23">>},
                                                                                             {uptime, 123123},
                                                                                             {status, <<"healthy">>},
                                                                                             {ports, {struct, [{routing, 11211},
                                                                                                                {caching, 11311},
                                                                                                                {kvstore, 11411}]}},
                                                                                             {uri, <<"https://second_node.in.pool.com:80/pool/Another Pool/node/second_node/">>},
                                                                                             {name, <<"second_node">>},
                                                                                             {fqdn, <<"second_node.in.pool.com">>}]}]},
                             {buckets, [{struct, [{uri, <<"/buckets/5">>},
                                                 {name, <<"Excerciser Another">>}]}]},
                             {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=2">>}]}},
                             {name, <<"Another Pool">>}]}
          end,
    reply_json(Req, Res).

handle_pool_info_streaming(Id, Req) ->
    %% TODO: this shouldn't be timer driven, but rather should register a callback based on some state change in the Erlang OS
    HTTPRes = Req:ok({"application/json; charset=utf-8",
                  [{"Server", "NorthScale menelaus %TODO gitversion%"}],
                  chunked}),
    Res = case Id of
              "default" -> {struct, [{nodes, [{struct, [{ipAddress, <<"10.0.1.20">>},
                                                  {status, <<"healthy">>},
                                                  {ports, {struct, [{routing, 11211},
                                                                  {caching, 11311},
                                                                  {kvstore, 11411}]}},
                                                  {name, <<"first_node">>},
                                                  {fqdn, <<"first_node.in.pool.com">>}]}, {struct, [{ipAddress, <<"10.0.1.21">>},
                                                                                              {status, <<"healthy">>},
                                                                                              {ports, {struct, [{routing, 11211},
                                                                                                                {caching, 11311},
                                                                                                                {kvstore, 11411}]}},
                                                                                              {uri, <<"/addresses/10.0.1.20">>},
                                                                                              {name, <<"first_node">>},
                                                                                              {fqdn, <<"first_node.in.pool.com">>}]}]},
                                {buckets, [{struct, [{uri, <<"/buckets/4">>},
                                                    {name, <<"Excerciser Application">>}]}]},
                                {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=1">>}]}},
                                {name, <<"Default Pool">>}]};
              _ -> {struct, [{nodes, [{struct, [{ipAddress, <<"10.0.1.22">>},
                                               {uptime, 123321},
                                               {status, <<"healthy">>},
                                               {ports, {struct, [{routing, 11211},
                                                                  {caching, 11311},
                                                                  {kvstore, 11411}]}},
                                               {uri, <<"https://first_node.in.pool.com:80/pool/Another Pool/node/first_node/">>},
                                               {name, <<"first_node">>},
                                               {fqdn, <<"first_node.in.pool.com">>}]}, {struct, [{ipAddress, <<"10.0.1.23">>},
                                                                                             {uptime, 123123},
                                                                                             {status, <<"healthy">>},
                                                                                             {ports, {struct, [{routing, 11211},
                                                                                                                {caching, 11311},
                                                                                                                {kvstore, 11411}]}},
                                                                                             {uri, <<"https://second_node.in.pool.com:80/pool/Another Pool/node/second_node/">>},
                                                                                             {name, <<"second_node">>},
                                                                                             {fqdn, <<"second_node.in.pool.com">>}]}]},
                             {buckets, [{struct, [{uri, <<"/buckets/5">>},
                                                 {name, <<"Excerciser Another">>}]}]},
                             {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=2">>}]}},
                             {name, <<"Another Pool">>}]}
          end,
    HTTPRes:write_chunk(mochijson2:encode(Res)),
    %% TODO: resolve why mochiweb doesn't support zero chunk... this
    %%       indicates the end of a response for now
    HTTPRes:write_chunk("\n\n\n\n"),
    handle_pool_info_streaming(Id, HTTPRes, 3000).

handle_pool_info_streaming(Id, HTTPRes, Wait) ->
    receive
    after Wait ->
            Res = case Id of
                "default" -> {struct, [{nodes, [{struct, [{ipAddress, <<"10.0.1.20">>},
                                                    {status, <<"healthy">>},
                                                    {ports, {struct, [{routing, 11211},
                                                                    {caching, 11311},
                                                                    {kvstore, 11411}]}},
                                                    {name, <<"first_node">>},
                                                    {fqdn, <<"first_node.in.pool.com">>}]}, {struct, [{ipAddress, <<"10.0.1.21">>},
                                                                                                {status, <<"healthy">>},
                                                                                                {ports, {struct, [{routing, 11211},
                                                                                                                  {caching, 11311},
                                                                                                                  {kvstore, 11411}]}},
                                                                                                {uri, <<"/addresses/10.0.1.20">>},
                                                                                                {name, <<"first_node">>},
                                                                                                {fqdn, <<"first_node.in.pool.com">>}]}]},
                                  {buckets, [{struct, [{uri, <<"/buckets/4">>},
                                                      {name, <<"Excerciser Application">>}]}]},
                                  {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=1">>}]}},
                                  {name, <<"Default Pool">>}]};
                _ -> {struct, [{nodes, [{struct, [{ipAddress, <<"10.0.1.22">>},
                                                 {uptime, 123321},
                                                 {status, <<"healthy">>},
                                                 {ports, {struct, [{routing, 11211},
                                                                    {caching, 11311},
                                                                    {kvstore, 11411}]}},
                                                 {uri, <<"https://first_node.in.pool.com:80/pool/Another Pool/node/first_node/">>},
                                                 {name, <<"first_node">>},
                                                 {fqdn, <<"first_node.in.pool.com">>}]}, {struct, [{ipAddress, <<"10.0.1.23">>},
                                                                                               {uptime, 123123},
                                                                                               {status, <<"healthy">>},
                                                                                               {ports, {struct, [{routing, 11211},
                                                                                                                  {caching, 11311},
                                                                                                                  {kvstore, 11411}]}},
                                                                                               {uri, <<"https://second_node.in.pool.com:80/pool/Another Pool/node/second_node/">>},
                                                                                               {name, <<"second_node">>},
                                                                                               {fqdn, <<"second_node.in.pool.com">>}]}]},
                               {buckets, [{struct, [{uri, <<"/buckets/5">>},
                                                   {name, <<"Excerciser Another">>}]}]},
                               {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=2">>}]}},
                               {name, <<"Another Pool">>}]}
                end,
        HTTPRes:write_chunk(mochijson2:encode(Res)),
        %% TODO: resolve why mochiweb doesn't support zero chunk... this
        %%       indicates the end of a response for now
        HTTPRes:write_chunk("\n\n\n\n")
    end,
    handle_pool_info_streaming(Id, HTTPRes, 10000).


handle_bucket_info(Id, Req) ->
    Res = case Id of
              "4" -> {struct, [{pool_uri, <<"asdasdasdasd">>},
                               {stats, {struct, [{uri, <<"/buckets/4/stats">>}]}},
                               {name, <<"Excerciser Application">>}]};
              _ -> {struct, [{pool_uri, <<"asdasdasdasd">>},
                             {stats, {struct, [{uri, <<"/buckets/5/stats">>}]}},
                             {name, <<"Excerciser Another">>}]}
          end,
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
    OpsPerSecondZoom = case proplists:get_value("opspersecond_zoom", Params) of
                           undefined -> "1hr";
                           Val -> Val
                       end,
    Samples = mk_samples(OpsPerSecondZoom),
    SamplesSize = length(element(2, hd(Samples))),
    SamplesInterval = case OpsPerSecondZoom of
                          "now" -> 1;
                          "24hr" -> 86400 div SamplesSize;
                          "1hr" -> 3600 div SamplesSize
                      end,
    StartTstampParam = proplists:get_value("opsbysecond_start_tstamp", Params),
    {LastSampleTstamp, CutNumber} = case StartTstampParam of
                    undefined -> {Now, SamplesSize};
                    _ ->
                        StartTstamp = list_to_integer(StartTstampParam),
                        CutMsec = Now - StartTstamp,
                        if
                            ((CutMsec > 0) andalso (CutMsec < SamplesInterval*1000*SamplesSize)) ->
                                N = trunc(CutMsec/SamplesInterval/1000),
                                {StartTstamp + N * SamplesInterval * 1000, N};
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
                             {samples_interval, SamplesInterval}
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
                                      [{"opspersecond_zoom", "now"},
                                       {"keys_opspersecond_zoom", "now"},
                                       {"opsbysecond_start_tstamp", "1259747672559"}],
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

handle_bucket_stats(_Id, Req) ->
    Now = java_date(),
    Params = Req:parse_qs(),
    Res = build_bucket_stats_response(_Id, Params, Now),
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
