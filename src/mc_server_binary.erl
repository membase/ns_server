% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_server_binary).

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
            ok = mc_binary:send(OutSock, Data),
            loop_out(OutSock);
        stop -> ok
    end.

recv(InSock) ->
    case mc_binary:recv(InSock, req) of
        {ok, Header, Entry} ->
            {ok, Header#mc_header.opcode, {Header, Entry}};
        Err -> Err
    end.

recv_prefix(Prefix, InSock) ->
    case mc_binary:recv_prefix(Prefix, InSock, req) of
        {ok, Header, Entry} ->
            {ok, Header#mc_header.opcode, {Header, Entry}};
        Err -> Err
    end.

