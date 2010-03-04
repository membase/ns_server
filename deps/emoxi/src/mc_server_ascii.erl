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
            ok
    end.

loop_in_prefix(Prefix, InSock, OutPid, CmdNum, Module, Session) ->
    case recv_prefix(Prefix, InSock) of
        {ok, Cmd, CmdArgs} ->
            {ok, Session2} =
                Module:cmd(Cmd, Session, InSock, {OutPid, CmdNum}, CmdArgs),
            loop_in(InSock, OutPid, CmdNum + 1, Module, Session2);
        {error, closed} ->
            ok
    end.

loop_out(OutSock) ->
    receive
        {send, _CmdNum, Data} ->
            case mc_ascii:send(OutSock, Data) of
                ok -> loop_out(OutSock);
                {error, closed} -> ok;
                E ->
                    error_logger:info_msg("Unexpected error in send: ~p~n", [E])
            end;
        {flush, From} -> From ! flushed;
        Other ->
            error_logger:info_msg("Unhandled message:  ~p~n", [Other]),
            exit({unhandled, ?MODULE, loop_out, Other})
    end.

recv(InSock) ->
    case mc_ascii:recv_line(InSock) of
        {ok, <<>>} ->
            {ok, unknown, []};
        {ok, Line} ->
            [CmdName | CmdArgs] = string:tokens(binary_to_list(Line), " "),
            case catch(list_to_existing_atom(CmdName)) of
                {'EXIT', {badarg, _}} -> {ok, CmdName, CmdArgs};
                CmdAtom               -> {ok, CmdAtom, CmdArgs}
            end;
        Err -> Err
    end.

recv_prefix(Prefix, InSock) ->
    case mc_ascii:recv_line(InSock) of
        {ok, LineBody} ->
            Line = <<Prefix/binary, LineBody/binary>>,
            [CmdName | CmdArgs] = string:tokens(binary_to_list(Line), " "),
            case catch(list_to_existing_atom(CmdName)) of
                {'EXIT', {badarg, _}} -> {ok, CmdName, CmdArgs};
                CmdAtom               -> {ok, CmdAtom, CmdArgs}
            end;
        Err -> Err
    end.

