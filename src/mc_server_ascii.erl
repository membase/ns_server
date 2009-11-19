-module(mc_server_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

process(InSock, OutPid, {ModName, ApplyArgs}, Line) ->
    [Cmd | CmdArgs] = string:tokens(binary_to_list(Line), " "),
    {ok, ApplyArgs2} = apply(ModName, cmd,
                             [list_to_atom(Cmd), ApplyArgs,
                              InSock, OutPid, CmdArgs]),
    % TODO: Need error handling here, to send ERROR on unknown cmd.
    % TODO: Does the connection close during other process exit/error?
    {ok, {ModName, ApplyArgs2}}.

session(UpstreamSock, Args) ->
    OutPid = spawn_link(?MODULE, loop_out, [UpstreamSock]),
    loop_in(UpstreamSock, OutPid, Args).

loop_in(InSock, OutPid, Args) ->
    {ok, Line} = mc_ascii:recv_line(InSock),
    {ok, Args2} = process(InSock, OutPid, Args, Line),
    loop_in(InSock, OutPid, Args2).

loop_out(OutSock) ->
    receive
        {send, Data} ->
            ok = mc_ascii:send(OutSock, Data),
            loop_out(OutSock)
    end.
