% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_server).

-behavior(application).

-export([start_link/0, start/2, start/0, stop/1]).

-export([start_win/0]).

start() ->
    application:start(ns_server).

start_win() ->
    % Main entry point for windows/NT-service.
    %
    % Also, native erl5.7.4/bin/inet_gethost.exe is broken on windows
    % (XP, 2003 server, 7), so explicitly skip native inet lookup.
    %
    % See: http://osdir.com/ml/lang.erlang.general/2004-04/msg00155.html
    %
    inet_db:set_lookup([file, dns]),
    start().

start(_Type, _Args) ->
    start_link().

stop(_State) ->
    ok.

start_link() ->
    misc:make_pidfile(),
    misc:ping_jointo(),
    ns_server_sup:start_link().
