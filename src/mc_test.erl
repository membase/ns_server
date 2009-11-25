-module(mc_test).

-compile(export_all).

main() ->
    {mc_server_ascii_proxy:main(),
     mc_downstream:start()}.

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
              apply(Test, test, []),
              {ok, Cov} =
                  cover:analyse_to_file(Test,
                                        atom_to_list(Test) ++ ".cov.html",
                                        [html])
      end,
      Tests),
    ok.


