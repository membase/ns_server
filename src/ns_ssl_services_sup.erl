-module(ns_ssl_services_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-export([init/1, start_link/0, restart_ssl_services/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{rest_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          child_specs()}}.

restart_ssl_services() ->
    [begin
         ok = supervisor2:terminate_child(?MODULE, Child),
         {ok, _} = supervisor2:restart_child(?MODULE, Child)
     end || Child <- [ns_rest_ssl_service, ns_capi_ssl_service]],
    ok.


child_specs() ->
    [{ns_ssl_services_setup,
      {ns_ssl_services_setup, start_link, []},
      permanent, 1000, worker, []},

     {ns_rest_ssl_service,
      {ns_ssl_services_setup, start_link_rest_service, []},
      permanent, 1000, worker, []},

     {ns_capi_ssl_service,
      {ns_ssl_services_setup, start_link_capi_service, []},
      permanent, 1000, worker, []}].

