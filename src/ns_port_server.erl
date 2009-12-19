-module(ns_port_server).
-behavior(gen_server).

-export([start_link/3]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

%% Server state
-record(state, {port, name}).

start_link(Name, Cmd, Args) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Cmd, Args}, []).

init({Name, Cmd, Args}) ->
    {ok, Pwd} = file:get_cwd(),
    PrivDir = filename:join(Pwd, "priv"),
    FullPath = filename:join(PrivDir, Cmd),
    error_logger:info_msg("Starting ~p in ~p with ~p~n", [FullPath, PrivDir, Args]),
    process_flag(trap_exit, true),
    Port = open_port({spawn_executable, FullPath},
                     [{args, Args},
                     {cd, PrivDir}]),
    {ok, #state{port = Port, name = Name}}.

handle_info({'EXIT', _Port, Reason}, State) ->
    error_logger:info_msg("Port subprocess (~p) exited: ~p~n",
                          [State#state.name, Reason]),
    {stop, {port_terminated, Reason}, State}.

handle_call(Something, _From, State) ->
    error_logger:info_msg("Unexpected call: ~p~n", [Something]),
    {reply, "What?", State}.

handle_cast(Something, State) ->
    error_logger:info_msg("Unexpected cast: ~p~n", [Something]),
    {noreply, State}.

terminate({port_terminated, Reason}, State) ->
    error_logger:info_msg("Port has terminated ~p:  ~p~n", [State#state.name, Reason]),
    ok;
terminate(Reason, State) ->
    error_logger:info_msg("Terminating ~p:  ~p~n", [State#state.name, Reason]),
    port_close(State#state.port).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
