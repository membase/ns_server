-module(mc_test).

-compile(export_all).

% To build:
%   make clean && make
%
% To run tests:
%   erl -pa ebin -noshell -s mc_test test -s init stop
%
test() ->
    mc_ascii:test(),
    mc_client_ascii:test(),
    mc_client_ascii_ac:test(),
    mc_binary:test(),
    mc_client_binary:test(),
    mc_client_binary_ac:test(),
    mc_bucket:test(),
    ok.
