-module(mc_server_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

process(InSock, OutPid, CmdNum, {ModName, SessData}, Line) ->
    [Cmd | CmdArgs] = string:tokens(binary_to_list(Line), " "),
    {ok, SessData2} = apply(ModName, cmd,
                            [list_to_atom(Cmd), SessData,
                             InSock, OutPid, CmdNum, CmdArgs]),
    % TODO: Need error handling here, to send ERROR on unknown cmd.
    % TODO: Does the connection close during other process exit/error?
    {ok, {ModName, SessData2}}.

session(UpstreamSock, Args) ->
    OutPid = spawn_link(?MODULE, loop_out, [UpstreamSock]),
    loop_in(UpstreamSock, OutPid, 1, Args).

loop_in(InSock, OutPid, CmdNum, Args) ->
    {ok, Line} = mc_ascii:recv_line(InSock),
    {ok, Args2} = process(InSock, OutPid, CmdNum, Args, Line),
    loop_in(InSock, OutPid, CmdNum + 1, Args2).

loop_out(OutSock) ->
    receive
        {send, _CmdNum, Data} ->
            ok = mc_ascii:send(OutSock, Data),
            loop_out(OutSock)
    end.
