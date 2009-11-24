-module(mc_test).

-compile(export_all).

% To build:
%   make clean && make
%
% To run tests:
%   erl -pa ebin -noshell -s mc_test test -s init stop
%
test() ->
    Tests = [mc_ascii,
             mc_client_ascii,
             mc_client_ascii_ac,
             mc_binary,
             mc_client_binary,
             mc_client_binary_ac,
             mc_bucket,
             mc_pool,
             mc_server_ascii_proxy
            ],
    lists:foreach(fun (Test) ->
                          io:format("~p~n", [Test]),
                          apply(Test, test, [])
                  end,
                  Tests).
