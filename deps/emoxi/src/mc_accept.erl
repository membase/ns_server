-module(mc_accept).

-behaviour(gen_server).

%% API
-export([start_link/2, start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {listener, acceptor, client_sup}).

start_link(PortNum, Env) ->
    start_link(PortNum, "0.0.0.0", Env).
start_link(PortNum, AddrStr, Env) ->
    gen_server:start_link(?MODULE,
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
                    {S, E, M} = Env,
                    {ok, ClientSup} = mc_client_sup:start_link(S, E, M),
                    {ok, Ref} = prim_inet:async_accept(Listener, -1),
                    {ok, #state{listener = Listener,
                                acceptor = Ref,
                                client_sup = ClientSup}};
                Error   -> ns_log:log(?MODULE, 0002, "Could not listen on port ~p (with binding address ~p). " ++
                                                     "Perhaps another process has taken that port already? " ++
                                                     "To address this, you may change port number configurations via the Cluster Settings page, " ++
                                                     "or stop the other listening process and restart this server. (error: ~p on node ~p)",
                                      [{PortNum, AddrStr, Error, node()}]),
                           {stop, Error}
            end;
        Error -> ns_log:log(?MODULE, 0003, "Could not parse address ~p to listen on port ~p",
                            [AddrStr, PortNum]),
                 {stop, Error}
    end.

handle_info({inet_async, ListSock, Ref, {ok, CliSocket}},
            #state{listener=ListSock, acceptor=Ref, client_sup=ClientSup} = State) ->
    try
        case set_sockopt(ListSock, CliSocket) of
            ok              -> ok;
            {error, Reason} -> exit({set_sockopt, Reason})
        end,

        mc_client_sup:start_child(ClientSup, CliSocket),

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
