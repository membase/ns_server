-module(mc_test).

-include("mc_entry.hrl").

-compile(export_all).

main() ->
    Config = [[{replica_n, 1},
               {replica_w, 1},
               {replica_r, 1}]],

    AsciiAddrs = [mc_addr:local(ascii)],
    AsciiPool = mc_pool:create(ascii_pool, AsciiAddrs, Config,
                               [mc_bucket:create("default", AsciiAddrs,
                                                  Config)]),
    BinaryAddrs = [mc_addr:local(binary)],
    BinaryPool = mc_pool:create(binary_pool, BinaryAddrs, Config,
                                [mc_bucket:create("default", BinaryAddrs,
                                                  Config)]),

    Addrs2 = [mc_addr:local(ascii),
              mc_addr:local(binary)],
    Pool2 = mc_pool:create(pool2, Addrs2, Config,
                           [mc_bucket:create("default", Addrs2,
                                             Config)]),

    {mc_downstream:start(),
     mc_replication:start(),
     mc_accept:start(11300,
                     {mc_server_ascii,
                      mc_server_ascii_proxy, AsciiPool}),
     mc_accept:start(11400,
                     {mc_server_ascii,
                      mc_server_ascii_proxy, BinaryPool}),
     mc_accept:start(11500,
                     {mc_server_binary,
                      mc_server_binary_proxy, AsciiPool}),
     mc_accept:start(11600,
                     {mc_server_binary,
                      mc_server_binary_proxy, BinaryPool}),
     mc_accept:start(11233,
                     {mc_server_detect,
                      mc_server_detect, AsciiPool}),
     mc_accept:start(11244,
                     {mc_server_detect,
                      mc_server_detect, BinaryPool}),
     mc_accept:start(11255,
                     {mc_server_detect,
                      mc_server_detect, Pool2})}.

% To build:
%   make clean && make
%
% To run tests:
%   erl -pa ebin -noshell -s mc_test test -s init stop
%
tests_mc() ->
    [mc_ascii,
     mc_client_ascii,
     mc_client_ascii_ac,
     mc_binary,
     mc_client_binary,
     mc_client_binary_ac,
     mc_bucket,
     mc_pool,
     mc_downstream
    ].

tests_emoxi() ->
    [util,
     misc,
     config,
     cring,
     bootstrap,
     vclock,
     stream,
     dmerkle,
     dmerkle_tree,
     partition,
     membership,
     storage_server,
     storage_manager,
     sync_manager].

test() ->
    {test_list(tests_mc()),
     test_list(tests_emoxi())}.

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

cucumber_features() -> ["rebalance"].

cucumber_step_modules() -> [].

cucumber() ->
    process_flag(trap_exit, true),
    CucumberStepModules = cucumber_step_modules(),
    CucumberFeatures = cucumber_features(),
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

