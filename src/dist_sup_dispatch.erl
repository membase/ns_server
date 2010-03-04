%% This is a supervisor adaptor that either:
%%  1. monitors an existing instance and crashes when it exits.
%%  2. registers itself as a global process and runs a supervisor.

-module(dist_sup_dispatch).

-export([start_link/0, init/1]).

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
    process_flag(trap_exit, true),
    case do_initialization() of
        {ok, Pid} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            wait(Pid);
        {error, Reason} ->
            exit(Reason)
    end.

do_initialization() ->
    case global:register_name(?MODULE, self()) of
    yes ->
        error_logger:info_msg("dist_sup_dispatch: starting global singleton.~n"),
        {ok, Pid} = global_singleton_supervisor:start_link(),
        ns_log:log(?MODULE, 1, "Global singleton started on node ~p", [node()]),
        {ok, Pid};
    no ->
        Pid = global:whereis_name(?MODULE),
        true = is_pid(Pid),
        erlang:monitor(process, Pid),
        {ok, undefined}
    end.

drown_in_lake(Pid) ->
    error_logger:info_msg("dist_sup_dispatch: Drowning ~p in a lake.~n", [Pid]),
    exit(Pid, shutdown),
    receive
        {'EXIT', Pid, Reason} ->
            error_logger:info_msg("dist_sup_dispatch: Child exited with reason ~p~n",
                                  [Reason]),
            {shutdown, Reason}
    end.

wait(Pid) ->
    receive
        {'EXIT', From, _Reason} when Pid =/= undefined, From =/= Pid ->
            drown_in_lake(Pid);
        LikelyExitMessage ->
            error_logger:info_msg("dist_sup_dispatch: Exiting, I got a message: ~p~n",
                                  [LikelyExitMessage])
    end.
