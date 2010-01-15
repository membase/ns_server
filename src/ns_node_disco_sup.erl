% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_node_disco_sup).

-behavior(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{rest_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          get_child_specs()}}.

get_child_specs() ->
    [
     % gen_event for the node disco events.
     {ns_node_disco_events,
      {gen_event, start_link, [{local, ns_node_disco_events}]},
      permanent, 10, worker, []},
     % manages node discovery and health.
     {ns_node_disco,
      {ns_node_disco, start_link, []},
      permanent, 10, worker, []},
     % logs node disco events for debugging.
     {ns_node_disco_log,
      {ns_node_disco_log, start_link, []},
      transient, 10, worker, []},
     % listens for ns_config events relevant to node_disco.
     {ns_node_disco_conf_events,
      {ns_node_disco_conf_events, start_link, []},
      transient, 10, worker, []},
     % replicate config across nodes.
     {ns_config_rep, {ns_config_rep, start_link, []},
      permanent, 10, worker,
      [ns_config_rep]}
    ].
