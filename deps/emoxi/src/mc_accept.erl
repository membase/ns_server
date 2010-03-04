-module(mc_accept).

-behaviour(gen_server).

%% API
-export([start_link/2, start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([session/5]).

-record(state, {listener, acceptor, env}).

start_link(PortNum, Env) ->
    start_link(PortNum, "0.0.0.0", Env).
start_link(PortNum, AddrStr, Env) ->
    Name = server_name(PortNum, AddrStr),
    gen_server:start_link({local, Name}, ?MODULE,
                          [PortNum, AddrStr, Env], []).

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% Starting the server...
%
% Example:
%
%   mc_accept:start_link(PortNum, {ProtocolModule, ProcessorModule, ProcessorEnv}).
%
%   mc_accept:start_link(11222, {mc_server_ascii, mc_server_ascii_dict, {}}).
%
% A server ProtocolModule must implement callbacks of...
%
%   loop_in(...)
%   loop_out(...)
%
% A server ProcessorModule must implement callbacks of...
%
%   session(SessionSock, ProcessorEnv, ProtocolModule)
%   cmd(...)
%

init([PortNum, AddrStr, Env]) ->
    case inet_parse:address(AddrStr) of
        {ok, Addr} ->
            case gen_tcp:listen(PortNum, [binary,
                                          {reuseaddr, true},
                                          {packet, raw},
                                          {active, false},
                                          {ip, Addr}]) of
                {ok, Listener} ->
                    {ok, Ref} = prim_inet:async_accept(Listener, -1),
                    {ok, #state{listener = Listener,
                                acceptor = Ref,
                                env = Env}};
                Error   -> ns_log:log(?MODULE, 0002, "listen error: ~p",
                                      [{PortNum, AddrStr, Error}]),
                           {stop, Error}
            end;
        Error -> ns_log:log(?MODULE, 0003, "parse address error: ~p",
                            [AddrStr]),
                 {stop, Error}
    end.

handle_info({inet_async, ListSock, Ref, {ok, CliSocket}},
            #state{listener=ListSock, acceptor=Ref, env=Env} = State) ->
    try
        case set_sockopt(ListSock, CliSocket) of
            ok              -> ok;
            {error, Reason} -> exit({set_sockopt, Reason})
        end,

        start_session(CliSocket, Env),

        %% %% New client connected - spawn a new process using the simple_one_for_one
        %% %% supervisor.
        %% {ok, Pid} = tcp_server_app:start_client(),
        %% gen_tcp:controlling_process(CliSocket, Pid),
        %% %% Instruct the new FSM that it owns the socket.
        %% Module:set_socket(Pid, CliSocket),

        %% Signal the network driver that we are ready to accept another connection
        case prim_inet:async_accept(ListSock, -1) of
            {ok,    NewRef} -> ok;
            {error, NewRef} -> exit({async_accept, inet:format_error(NewRef)})
        end,

        {noreply, State#state{acceptor=NewRef}}
    catch exit:Why ->
            error_logger:error_msg("Error in async accept: ~p.\n", [Why]),
            {stop, Why, State}
    end;

handle_info(Something, State) ->
    error_logger:info_msg("Unhandled message: ~p~n", [Something]),
    {noreply, State}.

%% Taken from prim_inet.  We are merely copying some socket options
%% from the listening socket to the new client socket.
set_sockopt(ListSock, CliSocket) ->
    true = inet_db:register_socket(CliSocket, inet_tcp),
    case prim_inet:getopts(ListSock, [active, nodelay, keepalive, delay_send, priority, tos]) of
        {ok, Opts} ->
            case prim_inet:setopts(CliSocket, Opts) of
                ok    -> ok;
                Error -> gen_tcp:close(CliSocket), Error
            end;
        Error ->
            gen_tcp:close(CliSocket), Error
    end.

% Accept incoming connections.
start_session(NS, {ProtocolModule, ProcessorModule, ProcessorEnv}) ->
    % Ask the processor for a new session object.
    case ProcessorModule:session(NS, ProcessorEnv) of
        {ok, _ProcessorEnv2, ProcessorSession} ->
            % Do spawn_link of a session-handling process.
            Pid = spawn(?MODULE, session,
                        [self(), NS, ProtocolModule,
                         ProcessorModule, ProcessorSession]),
            gen_tcp:controlling_process(NS, Pid);
        Error ->
            ns_log:log(?MODULE, 0001, "could not start session: ~p",
                       [Error]),
            gen_tcp:close(NS)
    end.

% The main entry-point/driver for a session-handling process.
session(Parent, Sock, ProtocolModule, ProcessorModule, ProcessorSession) ->
    % Spawn a linked, protocol-specific output-loop/writer process.
    OutPid = spawn_link(fun() ->
                                Mref2 = erlang:monitor(process, Parent),
                                ProtocolModule:loop_out(Sock)
                        end),
    % Continue with a protocol-specific input-loop to receive messages.
    ProtocolModule:loop_in(Sock, OutPid, 1,
                           ProcessorModule, ProcessorSession).

server_name(PortNum, AddrStr) ->
    list_to_atom("mc_accept-" ++ integer_to_list(PortNum) ++ "_" ++ AddrStr).

