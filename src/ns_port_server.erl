-module(ns_port_server).

-behavior(gen_server).

-export([start_link/4, params/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

%% Server state
-record(state, {port, name, params, started}).

start_link(Name, Cmd, Args, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE,
                          {Name, Cmd, Args, Opts}, []).

params(Pid) ->
    gen_server:call(Pid, params).

init({Name, _Cmd, _Args, _Opts} = Params) ->
    Port = open_port(Params),
    case is_port(Port) of
        true  -> {ok, #state{port = Port, name = Name, params = Params,
                             started = now()}};
        false -> ns_log:log(port_0001, "could not start process: ~p",
                            [Params]),
                 {stop, Port}
    end.

open_port({_Name, Cmd, Args, Opts}) ->
    {ok, Pwd} = file:get_cwd(),
    PrivDir = filename:join(Pwd, "priv"),
    FullPath = filename:join(PrivDir, Cmd),
    error_logger:info_msg("Starting ~p in ~p with ~p / ~p~n",
                          [FullPath, PrivDir, Args, Opts]),
    process_flag(trap_exit, true),
    open_port({spawn_executable, FullPath},
              [{args, Args},
               {cd, PrivDir}] ++ Opts).

handle_info({'EXIT', _Port, Reason}, State) ->
    error_logger:info_msg("Port subprocess (~p) exited: ~p~n",
                          [State#state.name, Reason]),
    case (misc:time_to_epoch_float(now()) -
          misc:time_to_epoch_float(State#state.started)) =< 1 of
        true ->
            % Failed right away, so a normal Reason means don't restart.
            ns_log:log(port_0002, "process could not start: ~p",
                       [State#state.params]),
            {stop, normal, State};
        false ->
            % Failed after awhile, so a non-normal Reason means restart.
            ns_log:log(port_0002, "process exited: ~p",
                       [State#state.params]),
            {stop, {port_exited, Reason}, State}
    end.

handle_call(params, _From, #state{params = Params} = State) ->
    {reply, {ok, Params}, State};

handle_call(Something, _From, State) ->
    error_logger:info_msg("Unexpected call: ~p~n", [Something]),
    {reply, error, State}.

handle_cast(Something, State) ->
    error_logger:info_msg("Unexpected cast: ~p~n", [Something]),
    {noreply, State}.

terminate(normal, State) ->
    error_logger:info_msg("Port has terminated ~p:  ~p~n",
                          [State#state.name, normal]),
    ok;
terminate(Reason, State) ->
    error_logger:info_msg("Terminating ~p:  ~p~n", [State#state.name, Reason]),
    true = port_close(State#state.port).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
