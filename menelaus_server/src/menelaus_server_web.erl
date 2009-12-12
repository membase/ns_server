%% @author Northscale <info@northscale.com>
%% @copyright 2009 Northscale.

%% @doc Web server for menelaus_server.

-module(menelaus_server_web).
-author('Northscale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").
-ifdef(EUNIT).
-export([test_under_debugger/0, debugger_apply/2, test/0]).
-endif.

-export([start/1, stop/0, loop/2]).

-export([simple_memory_proc/0]).

%% External API

start(Options) ->
    {DocRoot, Options1} = get_option(docroot, Options),
    Loop = fun (Req) ->
                   ?MODULE:loop(Req, DocRoot)
           end,
    register(simple_memory_proc, spawn(?MODULE, simple_memory_proc, [])),
    mochiweb_http:start([{name, ?MODULE}, {loop, Loop} | Options1]).

stop() ->
    mochiweb_http:stop(?MODULE).

loop(Req, DocRoot) ->
    "/" ++ Path = Req:get(path),
    Action = case Req:get(method) of
                 Method when Method =:= 'GET'; Method =:= 'HEAD' ->
                     case string:tokens(Path, "/") of
                         [] -> {done, redirect_permanently("/index.html", Req)};
                         ["pools"] ->
                             {need_auth, fun () -> handle_pools(Req) end};
                         ["pools", Id] ->
                             {need_auth, fun () -> handle_pool_info(Id, Req) end};
                         ["buckets", Id] ->
                             {need_auth, fun () -> handle_bucket_info(Id, Req) end};
                         ["buckets", Id, "stats"] ->
                             {need_auth, fun () -> handle_bucket_stats(Id, Req) end};
                         _ ->
                             {call, fun () -> Req:serve_file(Path, DocRoot) end}
                     end;
                 'POST' ->
                     case Path of
                         _ ->
                             {done, Req:not_found()}
                     end;
                 _ ->
                     {done, Req:respond({501, [], []})}
             end,
    case Action of
        {done, RV} -> RV;
        {call, F} -> F();
        {need_auth, F} ->
            case check_auth(extract_basic_auth(Req)) of
                true -> F();
                _ -> Req:respond({401, [{"WWW-Authenticate", "Basic realm=\"api\""}], []})
            end
    end.

%% Internal API

simple_memory_proc() ->
    Table = ets:new(x, []),
    receive
        {Caller, Op, Args} -> Caller ! {sresult, erlang:apply(ets, Op, [Table | Args])}
    end,
    simple_memory_proc().

call_simple_memory_proc(Op, Args) ->
    simple_memory_proc ! {self(), Op, Args},
    receive
        {sresult, RV} ->
             RV
    end.

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
    Req:ok({"application/json", mochijson2:encode(Body)}).

handle_pools(Req) ->
    reply_json(Req, {struct, [
                              %% TODO: pull this from git describe
                              {implementationVersion, <<"comes_from_git_describe">>},
                              {pools, [{struct, [{name, <<"default">>},
                                                 {uri, <<"/pools/default">>}]},
                                       %% only one pool at first release, this 
                                       %% is just for prototyping
                                       {struct, [{name, <<"Another Pool">>},
                                                 {uri, <<"/pools/Another Pool">>}]}]}]}).

handle_pool_info(Id, Req) ->
    Res = case Id of
              "12" -> {struct, [{node, [{struct, [{ipAddress, <<"10.0.1.20">>},
                                                  {running, true},
                                                  {ports, [11211]},
                                                  {uri, <<"https://first_node.in.pool.com:80/pool/Default Pool/node/first_node/">>},
                                                  {name, <<"first_node">>},
                                                  {fqdn, <<"first_node.in.pool.com">>}]}, {struct, [{ip_address, <<"10.0.1.21">>},
                                                                                                {running, true},
                                                                                                {ports, [11211]},
                                                                                                {uri, <<"https://second_node.in.pool.com:80/pool/Default Pool/node/second_node/">>},
                                                                                                {name, <<"second_node">>},
                                                                                                {fqdn, <<"second_node.in.pool.com">>}]}]},
                                {bucket, [{struct, [{uri, <<"/buckets/4">>},
                                                    {name, <<"Excerciser Application">>}]}]},
                                {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=1">>}]}},
                                {name, <<"Default Pool">>}]};
              _ -> {struct, [{node, [{struct, [{ip_address, <<"10.0.1.22">>},
                                               {uptime, 123443},
                                               {running, true},
                                               {ports, [11211]},
                                               {uri, <<"https://first_node.in.pool.com:80/pool/Another Pool/node/first_node/">>},
                                               {name, <<"first_node">>},
                                               {fqdn, <<"first_node.in.pool.com">>}]}, {struct, [{ip_address, <<"10.0.1.22">>},
                                                                                             {uptime, 123123},
                                                                                             {running, true},
                                                                                             {ports, [11211]},
                                                                                             {uri, <<"https://second_node.in.pool.com:80/pool/Another Pool/node/second_node/">>},
                                                                                             {name, <<"second_node">>},
                                                                                             {fqdn, <<"second_node.in.pool.com">>}]}]},
                             {bucket, [{struct, [{uri, <<"/buckets/5">>},
                                                 {name, <<"Excerciser Another">>}]}]},
                             {stats, {struct, [{uri, <<"/buckets/4/stats?really_for_pool=2">>}]}},
                             {name, <<"Another Pool">>}]}
          end,
    reply_json(Req, Res).

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
    %% what a lame language! There's no support for self-recurion, it seems.
    Rec = fun (_Rec, State, [], Acc) -> {Acc, State};
              (Rec, State, [H|Tail], Acc) ->
                  {Value, NewState} = F(H, State),
                  Rec(Rec, NewState, Tail, [Value|Acc])
          end,
    {RV, State} = Rec(Rec, InState, InList, []),
    {lists:reverse(RV), State}.

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
    case call_simple_memory_proc(lookup, [Key]) of
        [] -> begin
                  V = Computation(),
                  call_simple_memory_proc(insert, [{Key, V}]),
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

test() ->
    eunit:test({spawn, {setup,
                        fun () ->
                                register(simple_memory_proc, spawn(?MODULE, simple_memory_proc, []))
                        end,
                        fun (Pid) ->
                                exit(Pid, die)
                        end,
                        {module, ?MODULE}}}, [verbose]).

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
