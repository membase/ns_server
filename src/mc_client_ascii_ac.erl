% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_client_ascii_ac).

-behavior(mc_client_ac).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-export([cmd/5]).

-compile(export_all).

%% A memcached client that speaks ascii protocol,
%% with an "API conversion" interface.

cmd(Cmd, Sock, RecvCallback, CBData, Entry) when is_atom(Cmd) ->
    mc_client_ascii:cmd(Cmd, Sock, RecvCallback, CBData, Entry);

cmd(Cmd, Sock, RecvCallback, CBData, Entry) ->
    % Dispatch to cmd_binary() in case the caller was
    % using a binary protocol opcode.
    cmd_binary(Cmd, Sock, RecvCallback, CBData, Entry).

% -------------------------------------------------

%% For binary upstream talking to downstream ascii server.
%% The RecvCallback function will receive ascii-oriented parameters.

cmd_binary(?SET, Sock, RecvCallback, CBData, Entry) ->
    cmd(set, Sock, RecvCallback, CBData, Entry);

cmd_binary(?DELETE, Sock, RecvCallback, CBData, Entry) ->
    cmd(delete, Sock, RecvCallback, CBData, Entry);

cmd_binary(?FLUSH, Sock, RecvCallback, CBData, Entry) ->
    cmd(flush_all, Sock, RecvCallback, CBData, Entry);

cmd_binary(?NOOP, _Sock, RecvCallback, CBData, _Entry) ->
    % Assuming NOOP used to uncork GETKQ's.
    case is_function(RecvCallback) of
       true  -> RecvCallback(<<"END">>, #mc_entry{}, CBData);
       false -> ok
    end;

cmd_binary(?VERSION, Sock, RecvCallback, CBData, Entry) ->
    cmd(version, Sock, RecvCallback, CBData, Entry);

cmd_binary(?GETKQ, Sock, RecvCallback, CBData, Entry) ->
    cmd(get, Sock, RecvCallback, CBData, Entry);

cmd_binary(Cmd, _S, _RC, _CD, _E) -> exit({unimplemented, Cmd}).

% -------------------------------------------------

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    ok = gen_tcp:close(Sock).

set_test_sock(Sock, Key) ->
    flush_test_sock(Sock),
    (fun () ->
        {ok, RB} = cmd(?SET, Sock, undefined, undefined,
                       #mc_entry{key =  Key,
                                 data = <<"AAA">>}),
        ?assertMatch(RB, <<"STORED">>)
    end)().

flush_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    ok = gen_tcp:close(Sock).

flush_test_sock(Sock) ->
    {ok, RB} = cmd(?FLUSH, Sock, undefined, undefined, #mc_entry{}),
    ?assertMatch(RB, <<"OK">>).

