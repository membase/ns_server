-module(ns_config_sup).
-behavior(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 3, 10},
          [
           % current state
           {ns_config, {ns_config, start_link, [undefined]},
            permanent, 10, worker, [ns_config, ns_config_default]},
           % gen_event for the config events
           {ns_config_events,
            {gen_event, start_link, [{local, ns_config_events}]},
            permanent, 10, worker, []}
          ]}}.
