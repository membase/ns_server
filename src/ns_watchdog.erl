% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.
-module(ns_watchdog).
-include_lib("eunit/include/eunit.hrl").
-export([bark/1, bark/2, eat/3]).
-define(DEFAULT_TIMEOUT, 5000). % five seconds

%% API
bark(Info) ->
    bark(?DEFAULT_TIMEOUT, Info).

bark(Timeout, Info) ->
    case get(?MODULE) of
    undefined -> ok;
    Tref -> {ok, cancel} = timer:cancel(Tref)
    end,
    {ok, Tref2} = timer:apply_after(Timeout, ?MODULE, eat, [self(), Info, Timeout]),
    put(?MODULE, Tref2).

eat(Pid, Info, Timeout) ->
    case misc:running(Pid) of
    true ->
        ns_log:log(?MODULE, 1, "killing ~p (~p) after it failed to respond for ~pms.",
                   [Pid, Info, Timeout]),
        exit(Pid, kill);
    false -> ok
    end.


%% Tests
kill_test() ->
    process_flag(trap_exit, true),
    Pid = spawn_link(fun test_killed/0),
    wait_for_killed(Pid).

normal_test() ->
    Pid = spawn_link(fun test_normal/0),
    wait_for_normal(Pid).

%% Internal testing funcs
test_killed() ->
    bark(500, ?MODULE),
    timer:sleep(1000).

wait_for_killed(Pid) ->
    receive
    {'EXIT', Pid, killed} -> pass;
    {'EXIT', Pid, Other} -> exit({fail, Other})
    after 2000 -> exit({fail, timeout})
    end.

test_normal() ->
    test_normal(5).

test_normal(0) -> ok;
test_normal(N) ->
    ns_watchdog:bark(500, ?MODULE),
    timer:sleep(250),
    test_normal(N-1).

wait_for_normal(Pid) ->
    io:format("waiting for ~p~n", [Pid]),
    receive
    {'EXIT', Pid, normal} -> pass;
    {'EXIT', Pid, Other} -> exit({fail, Other})
    after 2000 -> exit({fail, timeout})
    end.


