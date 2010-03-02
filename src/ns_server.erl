% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_server).

-behavior(application).

-export([start/2, stop/1, ns_log_cat/1]).

start(_Type, _Args) ->
    Result = ns_server_sup:start_link(),
    WConfig = menelaus_web:webconfig(),
    ns_log:log(?MODULE, 1, "NorthScale Memcached Server has started on web/REST port ~p.",
               [proplists:get_value(port, WConfig)]),
    Result.

stop(_State) ->
    ok.

ns_log_cat(_) -> info.
