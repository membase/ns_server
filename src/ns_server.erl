% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_server).

-behavior(application).

-export([start/2, stop/1, ns_log_cat/1]).

start(_Type, _Args) ->
    ns_cluster:start_link().

stop(_State) ->
    ok.

ns_log_cat(_) -> info.
