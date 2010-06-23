% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_server_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1, pull_plug/1]).

start_link() ->
    application:start(os_mon),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    pre_start(),
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          get_child_specs()}}.

pre_start() ->
    misc:make_pidfile(),
    misc:ping_jointo().

get_child_specs() ->
    [
     {ns_config_sup, {ns_config_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_config_sup]},

     {ns_node_disco_sup, {ns_node_disco_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_node_disco_sup]},

     {ns_port_sup, {ns_port_sup, start_link, []},
      permanent, 10, worker,
      [supervisor_cushion, ns_port_sup, ns_port_server]},

     {menelaus, {menelaus_app, start_subapp, []},
      permanent, infinity, supervisor,
      []},

     {ns_memcached,
      {ns_memcached, start_link, []},
      permanent, 10, worker, [ns_memcached]},

     {ns_vbm_sup, {ns_vbm_sup, start_link, []},
      permanent, infinity, supervisor, [ns_vbm_sup]},

     {global_singleton_supervisor, {global_singleton_supervisor, start_link, []},
      permanent, infinity, supervisor, [global_singleton_supervisor]},

     {ns_heart, {ns_heart, start_link, []},
      permanent, 10, worker,
      [ns_heart, ns_log, ns_port_sup, ns_doctor, ns_info]}
    ].

%% beware that if it's called from one of restarted childs it won't
%% work. This can be allowed with further work here. As of now it's not needed
pull_plug(Fun) ->
    GoodChildren = [ns_config_sup, ns_port_sup, menelaus, ns_node_disco_sup],
    BadChildren = [Id || {Id,_,_,_} <- supervisor:which_children(?MODULE),
                         not lists:member(Id, GoodChildren)],
    error_logger:info_msg("~p plug pulled.  Killing ~p, keeping ~p~n",
                          [?MODULE, BadChildren, GoodChildren]),
    lists:foreach(fun(C) -> ok = supervisor:terminate_child(?MODULE, C) end,
                  BadChildren),
    Fun(),
    lists:foreach(fun(C) ->
                          R = supervisor:restart_child(?MODULE, C),
                          error_logger:info_msg("Restarting ~p: ~p~n", [C, R])
                  end,
                  BadChildren).
