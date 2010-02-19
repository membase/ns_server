-module(ns_bootstrap).

-export([start/0]).

start() ->
    ok = application:start(sasl),
    ok = application:start(dist_manager),
    ok = application:start(ns_server).
