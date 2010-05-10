% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_server).

-behavior(application).

-export([start/2, stop/1, ns_log_cat/1]).

start(_Type, _Args) ->
    supervisor:start_link({local, ns_server_cluster_sup},
                          gen_sup, {{one_for_one, 10, 1},
                                     [
                                      {dist_manager, {dist_manager, start_link, []},
                                       permanent, 10, worker, [dist_manager]},
                                      {ns_cluster, {ns_cluster, start_link, []},
                                       permanent, 5000, worker, [ns_cluster]}
                                      ]}).

stop(_State) ->
    ok.

ns_log_cat(_) -> info.
