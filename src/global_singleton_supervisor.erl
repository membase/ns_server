%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% Processes supervised by this supervisor will only exist in one
%% place in a cluster.

-module(global_singleton_supervisor).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

start_link() ->
    case supervisor:start_link({global, ?MODULE}, ?MODULE, []) of
    {ok, Pid} -> {ok, Pid};
    {error, {already_started, Pid}} ->
        {ok, spawn_link(fun () -> watch(Pid) end)}
    end.

watch(Pid) ->
    process_flag(trap_exit, true),
    erlang:monitor(process, Pid),
    error_logger:info_msg("Monitoring global singleton at ~p (at node: ~p) from node ~p~n",
                          [Pid, node(Pid), node()]),
    receive
    LikelyExit ->
        error_logger:info_msg("Global singleton supervisor at ~p (at node: ~p) exited for reason ~p, seen from node ~p. Restarting.~n",
                              [Pid, node(Pid), LikelyExit, node()])
    end.


init([]) ->
    {ok,{{one_for_all, 5, 5},
         [
          %% Everything in here is run once per entire cluster.  Be careful.
          {ns_log, {ns_log, start_link, []},
           permanent, 10, worker, [ns_log]},
          {ns_log_events, {gen_event, start_link, [{local, ns_log_events}]},
           permanent, 10, worker, [ns_log_events]},
          {ns_mail_sup, {ns_mail_sup, start_link, []},
           permanent, infinity, supervisor, [ns_mail_sup]},
          {ns_orchestrator_events, {gen_event, start_link, [{global, ns_orchestrator_events}]},
           permanent, 10, worker, [gen_event]},
          {ns_orchestrator_sup, {ns_orchestrator_sup, start_link, []},
           permanent, infinity, supervisor, [ns_orchestrator_sup]},
          {ns_doctor, {ns_doctor, start_link, []},
           permanent, 10, worker, [ns_doctor]}
         ]}}.
