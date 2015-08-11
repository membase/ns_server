-module(the_supervisor2_tests).

-include_lib("eunit/include/eunit.hrl").

-export([init/1]).

init(Spec) ->
    {ok, Spec}.

frequent_crashes_child_start_link(Name) ->
    proc_lib:start_link(erlang, apply, [fun frequent_crashes_child_init/1, [Name]]).

frequent_crashes_child_init(Name) ->
    erlang:register(Name, self()),
    proc_lib:init_ack({ok, self()}),
    receive
        X ->
            erlang:exit(X)
    end.


sync_shutdown_child(Pid, Reason) ->
    Pid ! Reason,
    misc:wait_for_process(Pid, infinity).

find_child(Sup, Name) ->
    {_, ChildAfterDeath, _, _} = lists:keyfind(Name, 1, supervisor2:which_children(Sup)),
    ChildAfterDeath.


frequent_crashes_run() ->
    ChildSpecs = [{c1, {erlang, apply, [fun frequent_crashes_child_start_link/1, [frequent_crashes_child]]},
                   {permanent, 3},
                   1000,
                   worker, []},
                  {c2, {erlang, apply, [fun frequent_crashes_child_start_link/1, [frequent_crashes_child_2]]},
                   {permanent, 1},
                   1000,
                   worker, []}],
    {ok, Sup} = supervisor2:start_link(?MODULE,
                                       {{one_for_one, 2, 3}, ChildSpecs}),


    ChildBeforeDeath = find_child(Sup, c1),
    ?assertEqual(ChildBeforeDeath, erlang:whereis(frequent_crashes_child)),
    sync_shutdown_child(ChildBeforeDeath, die),
    ChildAfterDeath = find_child(Sup, c1),
    ?assertEqual(ChildAfterDeath, erlang:whereis(frequent_crashes_child)),
    ?assertNotEqual(ChildAfterDeath, ChildBeforeDeath),

    timer:sleep(1000),
    sync_shutdown_child(ChildAfterDeath, shutdown),
    timer:sleep(1000),
    sync_shutdown_child(find_child(Sup, c1), shutdown),
    %% three crashes in a row should delay restart

    ?assertEqual(undefined, find_child(Sup, c1)),

    timer:sleep(2000),

    ?assertEqual(undefined, find_child(Sup, c1)),

    sync_shutdown_child(find_child(Sup, c2), shutdown),
    ?assertNotEqual(undefined, find_child(Sup, c2)),

    timer:sleep(500),

    ?assertEqual(undefined, find_child(Sup, c1)),

    timer:sleep(500),

    ?assertNotEqual(undefined, find_child(Sup, c1)),

    %% delayed restarts reset the restart counters; this makes it two; the
    %% next shutdown should delay the restart again
    sync_shutdown_child(find_child(Sup, c2), die),
    ?assertNotEqual(undefined, find_child(Sup, c2)),

    sync_shutdown_child(find_child(Sup, c1), die1),
    sync_shutdown_child(find_child(Sup, c2), die),
    ?assertEqual(undefined, find_child(Sup, c2)),
    ?assertEqual(undefined, find_child(Sup, c1)),
    timer:sleep(4000),
    ?assertEqual(2, length([T || T <- [find_child(Sup, c1), find_child(Sup, c2)],
                                 T =/= undefined])),

    erlang:process_flag(trap_exit, true),
    Sup ! {'EXIT', self(), shutdown},
    misc:wait_for_process(Sup, infinity).


frequent_crashes_test_() ->
    {timeout, 20, fun frequent_crashes_run/0}.
