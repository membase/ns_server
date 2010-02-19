-module(dist_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_all, 0, 1},
          [
           %% gen_event for the config events.
           {ns_network_events,
            {gen_event, start_link, [{local, ns_network_events}]},
            permanent, 10, worker, []},

           %% Watch for network changes.
           {net_watcher,
            {net_watcher, start_link, []},
            permanent, 10, worker, [net_watcher]},

           %% Set up distributed erlang.
           {dist_manager, {dist_manager, start_link, []},
            permanent, 10, worker, [dist_manager]}
          ]}}.
