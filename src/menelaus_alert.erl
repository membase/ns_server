%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_alert).
-author('Northscale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test/0]).
-import(menelaus_util,
        [test_under_debugger/0, debugger_apply/2,
         wrap_tests_with_cache_setup/1]).
-endif.

-export([handle_alerts/1, handle_alerts_settings_post/1]).

-import(simple_cache, [call_simple_cache/2]).

-import(menelaus_util,
        [reply_json/2,
         java_date/0,
         stateful_takewhile/3,
         caching_result/2]).

%% External API

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

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

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
                                           {(N > LastNumber) andalso
                                            (Index < Limit), Index+1}
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
                              {settings, {struct, [{updateURI,
                                                    <<"/alerts/settings">>}
                                                   | fetch_alert_settings()]}},
                              {list, build_alerts(Req:parse_qs())}]}).

handle_alerts_settings_post(Req) ->
    PostArgs = Req:parse_post(),
    call_simple_cache(insert,
                      [{alert_settings,
                        lists:map(fun ({K,V}) ->
                                          {list_to_atom(K), list_to_binary(V)}
                                  end,
                                  PostArgs)}]),
    %% TODO: make it more RESTful
    Req:respond({200, [], []}).

