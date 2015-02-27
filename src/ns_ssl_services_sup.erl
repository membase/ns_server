-module(ns_ssl_services_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-export([init/1, start_link/0, restart_ssl_service/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{rest_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          child_specs()}}.

restart_ssl_service() ->
    {ok, _} = restartable:restart(?MODULE, ns_rest_ssl_service),
    ok.

child_specs() ->
    [{ns_ssl_services_setup,
      {ns_ssl_services_setup, start_link, []},
      permanent, 1000, worker, []},

     restartable:spec(
       {ns_rest_ssl_service,
        {ns_ssl_services_setup, start_link_rest_service, []},
        permanent, 1000, worker, []})
    ].
