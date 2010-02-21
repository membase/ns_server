%% This is a supervisor adaptor that either:
%%  1. monitors an existing instance and crashes when it exits.
%%  2. registers itself as a global process and runs a supervisor.

-module(dist_sup_dispatch).

-export([start_link/0, init/1]).

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
    case do_initialization() of
        ok ->
            proc_lib:init_ack(Parent, {ok, self()});
        {error, Reason} ->
            exit(Reason)
    end,
    wait().

do_initialization() ->
    monitor_or_supervise(global:whereis_name(?MODULE)).

monitor_or_supervise(undefined) ->
    yes = global:register_name(?MODULE, self()),
    {ok, _Pid} = global_singleton_supervisor:start_link(),
    ok;
monitor_or_supervise(Pid) when is_pid(Pid) ->
    erlang:monitor(process, Pid),
    ok.

wait() ->
    receive
        LikelyExitMessage ->
            error_logger:info_msg("Exiting, I got a message: ~p~n",
                                  [LikelyExitMessage])
    end.
