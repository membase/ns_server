% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_server).

-behavior(application).

-export([start/2, stop/1, ns_log_cat/1]).

start(_Type, _Args) ->
    Result = ns_server_sup:start_link(),
    ns_log:log(?MODULE, 1, "NorthScale Memcached Server has started on port ~p.",
               [ns_config:search_prop(ns_config:get(), rest, port, 8080)]),
    Result.

stop(_State) ->
    ok.

ns_log_cat(_) -> info.
