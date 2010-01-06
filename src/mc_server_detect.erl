% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_server_detect).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

loop_in(InSock, OutPid, CmdNum, _Module, Session) ->
    {ok, B} = gen_tcp:recv(InSock, 1),
    detect(B, InSock, OutPid, CmdNum, Session).

detect(<<?REQ_MAGIC>> = B, InSock, OutPid, CmdNum,
       {detecting, ProcessorEnv}) ->
    switch(mc_server_binary,
           mc_server_binary_proxy, ProcessorEnv,
           B, InSock, OutPid, CmdNum);

detect(B, InSock, OutPid, CmdNum,
       {detecting, ProcessorEnv}) ->
    switch(mc_server_ascii,
           mc_server_ascii_proxy, ProcessorEnv,
           B, InSock, OutPid, CmdNum).

switch(ProtocolModule, ProcessorModule, ProcessorEnv,
       B, InSock, OutPid, CmdNum) ->
    {ok, ProcessorEnv, ProcessorSession} =
        ProcessorModule:session(InSock, ProcessorEnv),
    OutPid ! {switch, ProtocolModule},
    ProtocolModule:loop_in_prefix(B, InSock, OutPid, CmdNum,
                                  ProcessorModule, ProcessorSession).

loop_out(OutSock) ->
    receive
        {switch, ProtocolModule} ->
            ProtocolModule:loop_out(OutSock);
        stop -> ok
    end.

session(_Sock, ProcessorEnv) ->
    {ok, ProcessorEnv, {detecting, ProcessorEnv}}.

