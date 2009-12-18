-module(ns_server).

-behavior(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ns_server_sup:start_link().

stop(_State) ->
    ok.
