% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(mc_accept).

-include_lib("eunit/include/eunit.hrl").

-export([start/2, start/3,
         start_link/2, start_link/3,
         init/3, session/4]).

% Starting the server...
%
% Example:
%
%   mc_accept:start(PortNum, {ProtocolModule, ProcessorModule, ProcessorEnv}).
%
%   mc_accept:start(11222, {mc_server_ascii, mc_server_ascii_dict, {}}).
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
start(PortNum, Env) ->
    start(PortNum, "0.0.0.0", Env).
start(PortNum, AddrStr, Env) ->
    {ok, spawn(?MODULE, init, [PortNum, AddrStr, Env])}.

start_link(PortNum, Env) ->
    start_link(PortNum, "0.0.0.0", Env).
start_link(PortNum, AddrStr, Env) ->
    {ok, spawn_link(?MODULE, init, [PortNum, AddrStr, Env])}.

% Note: this cannot be a gen_server, since our accept_loop
% has its own receive blocking implementation.

init(PortNum, AddrStr, Env) ->
    {ok, Addr} = inet_parse:address(AddrStr),
    {ok, LS} = gen_tcp:listen(PortNum, [binary,
                                        {reuseaddr, true},
                                        {packet, raw},
                                        {active, false},
                                        {ip, Addr}]),
    accept_loop(LS, Env).

% Accept incoming connections.
accept_loop(LS, {ProtocolModule, ProcessorModule, ProcessorEnv}) ->
    eat_exit_sessions(),
    {ok, NS} = gen_tcp:accept(LS),
    % Ask the processor for a new session object.
    case ProcessorModule:session(NS, ProcessorEnv) of
        {ok, ProcessorEnv2, ProcessorSession} ->
            % We use spawn_link with trap_exit, so that if our supervisor
            % kills us (such as due to a reconfiguration), we propagate
            % the kill to our session children.  But, a dying session
            % child will not take down us or propagate back.
            process_flag(trap_exit, true),
            % Do spawn_link of a session-handling process.
            Pid = spawn_link(?MODULE, session,
                             [NS, ProtocolModule,
                              ProcessorModule, ProcessorSession]),
            gen_tcp:controlling_process(NS, Pid),
            accept_loop(LS, {ProtocolModule, ProcessorModule, ProcessorEnv2});
        _Error ->
            ns_log:log(?MODULE, 1, "could not start session"),
            gen_tcp:close(NS),
            accept_loop(LS, {ProtocolModule, ProcessorModule, ProcessorEnv})
    end.

eat_exit_sessions() ->
    % We do a quick non-blocking receive to eat any EXIT notifications.
    receive
        {'EXIT', _ChildPid, _Reason} ->
            % ?debugVal({exit_session, ChildPid, Reason}),
            eat_exit_sessions()
    after 0 ->
        ok
    end.

% The main entry-point/driver for a session-handling process.
session(Sock, ProtocolModule, ProcessorModule, ProcessorSession) ->
    % Spawn a linked, protocol-specific output-loop/writer process.
    OutPid = spawn_link(ProtocolModule, loop_out, [Sock]),
    % Continue with a protocol-specific input-loop to receive messages.
    ProtocolModule:loop_in(Sock, OutPid, 1,
                           ProcessorModule, ProcessorSession).

