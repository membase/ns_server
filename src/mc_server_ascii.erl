-module(mc_server_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

loop_in(InSock, OutPid, CmdNum, Module, Session) ->
    {ok, Cmd, CmdArgs} = recv(InSock),
    {ok, Session2} =
        Module:cmd(Cmd, Session, InSock, {OutPid, CmdNum}, CmdArgs),
    % TODO: Need protocol-specific error handling here,
    %       such as to send ERROR on unknown cmd.  Currently,
    %       the connection just closes.
    loop_in(InSock, OutPid, CmdNum + 1, Module, Session2).

loop_in_prefix(Prefix, InSock, OutPid, CmdNum, Module, Session) ->
    {ok, Cmd, CmdArgs} = recv_prefix(Prefix, InSock),
    {ok, Session2} =
        Module:cmd(Cmd, Session, InSock, {OutPid, CmdNum}, CmdArgs),
    % TODO: Need protocol-specific error handling here,
    %       such as to send ERROR on unknown cmd.  Currently,
    %       the connection just closes.
    loop_in(InSock, OutPid, CmdNum + 1, Module, Session2).

loop_out(OutSock) ->
    receive
        {send, _CmdNum, Data} ->
            ok = mc_ascii:send(OutSock, Data),
            loop_out(OutSock)
    end.

recv(InSock) ->
    {ok, Line} = mc_ascii:recv_line(InSock),
    [CmdName | CmdArgs] = string:tokens(binary_to_list(Line), " "),
    {ok, list_to_atom(CmdName), CmdArgs}.

recv_prefix(Prefix, InSock) ->
    {ok, LineBody} = mc_ascii:recv_line(InSock),
    Line = <<Prefix/binary, LineBody/binary>>,
    [CmdName | CmdArgs] = string:tokens(binary_to_list(Line), " "),
    {ok, list_to_atom(CmdName), CmdArgs}.

