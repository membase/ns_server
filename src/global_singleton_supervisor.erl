%% Processes supervised by this supervisor will only exist in one
%% place in a cluster.

-module(global_singleton_supervisor).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

start_link() ->
    supervisor:start_link({global, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok,{{one_for_all, 5, 5},
         [
          %% Everything in here is run once per entire cluster.  Be careful.
          {ns_log, {ns_log, start_link, []},
           permanent, 10, worker, [ns_log]}
         ]}}.
