% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.
-module(ns_server_test).

-compile(export_all).

% To build:
%   make clean && make
%
% To run tests:
%   erl -pa ebin -noshell -s ns_server_test test -s init stop
%
tests(ns_server) ->
    [misc,
     stats_aggregator_manager,
     ns_config,
     ns_log,
     ns_port_init].

test() ->
    {test_list(tests(ns_server))}.

test_cover(Tests) ->
    cover:start(),
    cover:compile_directory("src", [{i, "include"}]),
    test_list(Tests),
    file:make_dir("tmp"),
    lists:foreach(
      fun (Test) ->
              {ok, _Cov} =
                  cover:analyse_to_file(
                    Test,
                    "tmp/" ++ atom_to_list(Test) ++ ".cov.html",
                    [html])
      end,
      Tests),
    ok.

test_list(Tests) ->
    process_flag(trap_exit, true),
    lists:foreach(
      fun (Test) ->
              io:format("  ~p...~n", [Test]),
              misc:rm_rf("./test/log"),
              Test:test()
      end,
      Tests),
    ok.

cucumber_features()     -> [].
cucumber_step_modules() -> [].

cucumber() ->
    CucumberStepModules = cucumber_step_modules(),
    CucumberFeatures = cucumber_features(),
    cucumber(CucumberStepModules, CucumberFeatures).

cucumber(CucumberStepModules, CucumberFeatures) ->
    process_flag(trap_exit, true),
    TotalStats =
        lists:foldl(
          fun (Feature, Acc) ->
                  {ok, Stats} =
                      cucumberl:run("./features/" ++ Feature ++ ".feature",
                                    CucumberStepModules),
                  cucumberl:stats_add(Stats, Acc)
          end,
          cucumberl:stats_blank(),
          CucumberFeatures),
    io:format("total stats: ~p~n", [TotalStats]),
    {ok, TotalStats}.

