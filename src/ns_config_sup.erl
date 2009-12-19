-module(ns_config_sup).
-behavior(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, CfgPath} = application:get_env(ns_server_config),
    error_logger:info_msg("Loading config from ~p~n", [CfgPath]),
    {ok, {{one_for_one, 3, 10},
          [
           % current state
           {ns_config, {ns_config, start_link, [CfgPath]},
            permanent, 10, worker, [ns_config, ns_config_default]},
           % gen_event for the config events
           {ns_config_events,
            {gen_event, start_link, [{local, ns_config_events}]},
            permanent, 10, worker, []},
           {ns_config_log,
            {ns_config_log, start, []},
            transient, 10, worker, []}
          ]}}.
