% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_server_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

% Note: the connection just closes on any error.

loop_in(InSock, OutPid, CmdNum, Module, Session) ->
    case recv(InSock) of
        {ok, Cmd, CmdArgs} ->
            {ok, Session2} =
                Module:cmd(Cmd, Session, InSock, {OutPid, CmdNum}, CmdArgs),
            loop_in(InSock, OutPid, CmdNum + 1, Module, Session2);
        {error, closed} ->
            OutPid ! stop,
            ok
    end.

loop_in_prefix(Prefix, InSock, OutPid, CmdNum, Module, Session) ->
    case recv_prefix(Prefix, InSock) of
        {ok, Cmd, CmdArgs} ->
            {ok, Session2} =
                Module:cmd(Cmd, Session, InSock, {OutPid, CmdNum}, CmdArgs),
            loop_in(InSock, OutPid, CmdNum + 1, Module, Session2);
        {error, closed} ->
            OutPid ! stop,
            ok
    end.

loop_out(OutSock) ->
    receive
        {send, _CmdNum, Data} ->
            ok = mc_ascii:send(OutSock, Data),
            loop_out(OutSock);
        {flush, From} -> From ! flushed;
        stop -> ok
    end.

recv(InSock) ->
    case mc_ascii:recv_line(InSock) of
        {ok, <<>>} ->
            {ok, unknown, []};
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

