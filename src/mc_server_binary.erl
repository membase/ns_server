-module(mc_server_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

loop_in(InSock, OutPid, CmdNum, Module, Session) ->
    {ok, Cmd, CmdArgs} = recv(InSock),
    ?debugVal({loop_in, Cmd, CmdArgs}),
    {ok, Session2} = apply(Module, cmd,
                           [Cmd, Session, InSock, {OutPid, CmdNum}, CmdArgs]),
    % TODO: Need protocol-specific error handling here,
    %       such as to send ERROR on unknown cmd.  Currently,
    %       the connection just closes.
    loop_in(InSock, OutPid, CmdNum + 1, Module, Session2).

loop_out(OutSock) ->
    receive
        {send, _CmdNum, Data} ->
            ok = mc_binary:send(OutSock, Data),
            loop_out(OutSock)
    end.

recv(InSock) ->
    {ok, Header, Entry} = mc_binary:recv(InSock, req),
    {ok, Header#mc_header.opcode, {Header, Entry}}.

