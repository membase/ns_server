%% This module exists to slow down supervisors to prevent fast spins
%% on crashes.
-module(supervisor_cushion).

-behaviour(gen_server).

%% API
-export([start_link/5]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {name, delay, started}).

start_link(Name, Delay, M, F, A) ->
    gen_server:start_link(?MODULE, [Name, Delay, M, F, A], []).

init([Name, Delay, M, F, A]) ->
    process_flag(trap_exit, true),
    error_logger:info_msg("starting ~p with delay of ~p~n", [M, Delay]),
    Val = apply(M, F, A),
    error_logger:info_msg("~p:~p(~p) returned ~p~n", [M, F, A, Val]),
    {ok, #state{name=Name, delay=Delay, started=now()}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, Reason}, State) ->
    error_logger:info_msg("Cushion managed supervisor for ~p failed:  ~p~n",
                          [State#state.name, Reason]),
    maybe_sleep(State),
    exit({error, cushioned_supervisor, Reason});
handle_info(Info, State) ->
    error_logger:info_msg("Cushion got unexpected info supervising ~p: ~p~n",
                          [State#state.name, Info]),
    maybe_sleep(State),
    exit({error, cushioned_supervisor, Info}).

maybe_sleep(State) ->
    %% now_diff returns microseconds, so let's do the same.
    Microseconds = State#state.delay * 1000,
    %% If the restart was too soon, slow down a bit.
    case timer:now_diff(now(), State#state.started) < Microseconds of
        true ->
            timer:sleep(State#state.delay);
        _ -> ok %% default case, no delay
    end.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
