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
    error_logger:info_msg("Monitoring global singleton at ~p~n", [Pid]),
    receive
    LikelyExit ->
        error_logger:info_msg("Global singleton supervisor at ~p exited for reason ~p. Restarting.~n",
                              [Pid, LikelyExit])
    end.


init([]) ->
    {ok,{{one_for_all, 5, 5},
         [
          %% Everything in here is run once per entire cluster.  Be careful.
          {ns_log, {ns_log, start_link, []},
           permanent, 10, worker, [ns_log]},
          {ns_log_events, {gen_event, start_link, [{local, ns_log_events}]},
           permanent, 10, worker, []},
          {ns_mail_sup, {ns_mail_sup, start_link, []},
           permanent, infinity, supervisor, []},
          {ns_doctor, {ns_doctor, start_link, []},
           permanent, 10, worker, [ns_doctor]},
          {stats_aggregator, {stats_aggregator, start_link, []},
           permanent, 10, worker, [stats_aggregator]},
          {stats_collector, {stats_collector, start_link, []},
           permanent, 10, worker, [stats_collector]}
         ]}}.
