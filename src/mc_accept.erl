-module(mc_accept).

-include_lib("eunit/include/eunit.hrl").

-export([start/2, start_link/2, init/2, session/2]).

% Starting the server...
%
% Example:
%
%   mc_accept:start(PortNum, {ProtocolModule, ProcessorEnv}).
%
%   mc_accept:start(11222, {mc_server_ascii, {mc_server_ascii_dict, {}}}).
%
% A server ProtocolModule must implement callbacks of...
%
%   loop_in(...)
%   loop_out(...)
%
% A server ProcessorModule must implement callbacks of...
%
%   session(SessionSock, ProcessorEnv)
%   cmd(...)
%
start(PortNum, Env) ->
    {ok, spawn(?MODULE, init, [PortNum, Env])}.

start_link(PortNum, Env) ->
    {ok, spawn_link(?MODULE, init, [PortNum, Env])}.

init(PortNum, Env) ->
    {ok, LS} = gen_tcp:listen(PortNum, [binary,
                                        {reuseaddr, true},
                                        {packet, raw},
                                        {active, false}]),
    accept_loop(LS, Env).

% Accept incoming connections.
accept_loop(LS, Env) ->
    {ok, NS} = gen_tcp:accept(LS),
    ?debugFmt("accept ~p~n", [NS]),
    Pid = spawn(?MODULE, session, [NS, Env]),
    gen_tcp:controlling_process(NS, Pid),
    accept_loop(LS, Env).

% The main entry point/driver for a session process.
session(Sock, {ProtocolModule, {ProcessorModule, ProcessorEnv}}) ->
    % Ask the processor for a new Session object.
    Session = apply(ProcessorModule, session, [Sock, ProcessorEnv]),
    % Spawn a protocol-specific paired output/writer process.
    OutPid = spawn_link(ProtocolModule, loop_out, [Sock]),
    % Continue with a protocol-specific input-loop to receive messages.
    apply(ProtocolModule, loop_in,
          [Sock, OutPid, 1, ProcessorModule, Session]).

