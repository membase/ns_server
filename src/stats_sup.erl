-module(stats_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_all, 5, 10},
          [
           {stat_collector,
            {stats_collector, start_link, []},
            permanent, 10, worker, []},
           {stats_aggregator,
            {stats_aggregator, start_link, []},
            permanent, 10, worker, []}
          ]}}.
