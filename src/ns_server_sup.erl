% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_server_sup).

-behavior(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    application:start(os_mon),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    pre_start(),
    {ok, {{rest_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          get_child_specs()}}.

pre_start() ->
    misc:make_pidfile(),
    misc:ping_jointo().

get_child_specs() ->
    [
     %% This supervises the (or monitors an existing) global singleton
     %% supervisor.  It's used by a few things below.
     {dist_sup_dispatch, {dist_sup_dispatch, start_link, []},
      permanent, 2000, worker, [dist_sup_dispatch]},

     {ns_config_sup, {ns_config_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_config_sup, ns_config, ns_config_default]},

     {ns_node_disco_sup, {ns_node_disco_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_node_disco_sup, ns_node_disco_events, ns_node_disco]},

     {ns_port_sup, {ns_port_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_port_sup, ns_port_server]},

     {emoxi_sup, {emoxi_sup, start_link, []},
      permanent, infinity, supervisor,
      []},

     {stats_sup,
      {stats_sup, start_link, []},
      permanent, infinity, supervisor,
      [stats_sup, stats_aggregator, stat_collection_clock,
       stats_collector]},

     {menelaus, {menelaus_app, start_subapp, []},
      permanent, infinity, supervisor,
      []}
    ].
