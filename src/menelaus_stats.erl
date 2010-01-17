%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_stats).
-author('Northscale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test/0]).
-import(menelaus_util,
        [test_under_debugger/0, debugger_apply/2,
         wrap_tests_with_cache_setup/1]).
-endif.

-export([handle_bucket_stats/3]).

-import(menelaus_util,
        [reply_json/2,
         java_date/0,
         string_hash/1,
         my_seed/1,
         stateful_map/3,
         stateful_takewhile/3,
         low_pass_filter/2,
         caching_result/2]).

%% External API

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
                            ((CutMsec > 0) andalso
                             (CutMsec < SamplesInterval*SamplesSize)) ->
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

