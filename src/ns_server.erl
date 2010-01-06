% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.


-module(ns_server).

-behavior(application).

-export([start_link/0, start/2, stop/1]).

start(_Type, _Args) ->
    start_link().

stop(_State) ->
    ok.

start_link() ->
    make_pidfile(),
    ping_jointo(),
    ns_server_sup:start_link().

% ----------------------------------

make_pidfile() ->
    case application:get_env(pidfile) of
        {ok, PidFile} -> make_pidfile(PidFile);
        X -> X
    end.

make_pidfile(PidFile) ->
    Pid = os:getpid(),
    ok = file:write_file(PidFile, list_to_binary(Pid)),
    ok.

ping_jointo() ->
    case application:get_env(jointo) of
        {ok, NodeName} -> ping_jointo(NodeName);
        X -> X
    end.

ping_jointo(NodeName) ->
    io:format("jointo: attempting to contact ~p~n", [NodeName]),
    case net_adm:ping(NodeName) of
        pong -> io:format("jointo: connected to ~p~n", [NodeName]);
        pang -> {error, io:format("jointo: could not ping ~p~n", [NodeName])}
    end.

