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
           get_env_default(max_r, 3),
           get_env_default(max_t, 10)},
          get_child_specs()}}.

get_env_default(Var, Def) ->
    case application:get_env(Var) of
        {ok, Value} -> Value;
        undefined -> Def
    end.

get_child_specs() ->
    [
     {ns_config_sup, {ns_config_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_config_sup, ns_config, ns_config_default]},
     {ns_port_sup, {ns_port_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_port_sup, ns_port_server]},
     {emoxi_sup, {emoxi_sup, start_link, []},
      permanent, infinity, supervisor,
      []},
     {menelaus, {menelaus_app, start_subapp, []},
      permanent, infinity, supervisor,
      []},
     % ensure ns_server_init is the last child, because its init()
     % has all the remaining init steps after everything's running.
     {ns_server_init, {ns_server_init, start_link, []},
      transient, 10, worker,
      []}
    ].
