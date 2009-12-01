-module(mc_server_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

loop_in(InSock, OutPid, CmdNum, Module, Session) ->
    case recv(InSock) of
        {ok, Cmd, CmdArgs} ->
            {ok, Session2} =
                Module:cmd(Cmd, Session, InSock, {OutPid, CmdNum}, CmdArgs),
            % TODO: Need protocol-specific error handling here,
            %       such as to send ERROR on unknown cmd.  Currently,
            %       the connection just closes.
            loop_in(InSock, OutPid, CmdNum + 1, Module, Session2);
        {error, closed} -> ok
    end.

loop_in_prefix(Prefix, InSock, OutPid, CmdNum, Module, Session) ->
    case recv_prefix(Prefix, InSock) of
        {ok, Cmd, CmdArgs} ->
            {ok, Session2} =
                Module:cmd(Cmd, Session, InSock, {OutPid, CmdNum}, CmdArgs),
            % TODO: Need protocol-specific error handling here,
            %       such as to send ERROR on unknown cmd.  Currently,
            %       the connection just closes.
            loop_in(InSock, OutPid, CmdNum + 1, Module, Session2);
        {error, closed} -> ok
    end.

loop_out(OutSock) ->
    receive
        {send, _CmdNum, Data} ->
            ok = mc_ascii:send(OutSock, Data),
            loop_out(OutSock)
    end.

recv(InSock) ->
    case mc_ascii:recv_line(InSock) of
        {ok, Line} ->
            [CmdName | CmdArgs] = string:tokens(binary_to_list(Line), " "),
            {ok, list_to_atom(CmdName), CmdArgs};
        Err -> Err
    end.

recv_prefix(Prefix, InSock) ->
    case mc_ascii:recv_line(InSock) of
        {ok, LineBody} ->
            Line = <<Prefix/binary, LineBody/binary>>,
            [CmdName | CmdArgs] = string:tokens(binary_to_list(Line), " "),
            {ok, list_to_atom(CmdName), CmdArgs};
        Err -> Err
    end.

