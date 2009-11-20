-module(mc_server_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

loop_in(InSock, OutPid, CmdNum, ProcessorModule, Session) ->
    {ok, Cmd, CmdArgs} = recv(InSock),
    {ok, Session2} = apply(ProcessorModule, cmd,
                           [Cmd, Session, InSock, OutPid, CmdNum, CmdArgs]),
    % TODO: Need error handling here, to send ERROR on unknown cmd.
    loop_in(InSock, OutPid, CmdNum + 1, ProcessorModule, Session2).

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

