% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_server_sup).

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
     {ns_log, {ns_log, start_link, []},
      permanent, 10, worker, [ns_log]},

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
     {menelaus, {menelaus_app, start_subapp, []},
      permanent, infinity, supervisor,
      []}
    ].
