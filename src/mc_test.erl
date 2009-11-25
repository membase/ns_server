-module(mc_test).

-compile(export_all).

main() ->
    AsciiAddrs = [mc_addr:local(ascii)],
    P1 = mc_pool:create(AsciiAddrs,
                        [mc_bucket:create("default", AsciiAddrs)]),
    {mc_downstream:start(),
     mc_accept:start(11300,
                     {mc_server_ascii,
                      mc_server_ascii_proxy, P1})}.

% To build:
%   make clean && make
%
% To run tests:
%   erl -pa ebin -noshell -s mc_test test -s init stop
%
tests() -> [mc_ascii,
            mc_client_ascii,
            mc_client_ascii_ac,
            mc_binary,
            mc_client_binary,
            mc_client_binary_ac,
            mc_bucket,
            mc_pool,
            mc_downstream,
            mc_server_ascii_proxy
           ].

test() ->
    cover:start(),
    cover:compile_directory("src", [{i, "include"}]),
    Tests = tests(),
    lists:foreach(
      fun (Test) ->
              io:format("  ~p...~n", [Test]),
              apply(Test, test, [])
      end,
      Tests),
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


