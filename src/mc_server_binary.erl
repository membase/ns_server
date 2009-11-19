-module(mc_server_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

process(InSock, OutPid, {ModName, SessData}, {Header, _Entry} = HeaderEntry) ->
    Cmd = Header#mc_header.opcode,
    {ok, SessData2} = apply(ModName, cmd,
                            [Cmd, SessData,
                             InSock, OutPid, HeaderEntry]),
    % TODO: Need error handling here, to send UNKNOWN_COMMAND status.
    {ok, {ModName, SessData2}}.

session(UpstreamSock, Args) ->
    OutPid = spawn_link(?MODULE, loop_out, [UpstreamSock]),
    loop_in(UpstreamSock, OutPid, Args).

loop_in(InSock, OutPid, Args) ->
    {ok, Header, Entry} = mc_binary:recv(InSock, req),
    {ok, Args2} = process(InSock, OutPid, Args, {Header, Entry}),
    loop_in(InSock, OutPid, Args2).

loop_out(OutSock) ->
    receive
        {send, Data} ->
            ok = mc_binary:send(OutSock, Data),
            loop_out(OutSock)
    end.
