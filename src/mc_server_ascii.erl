-module(mc_server_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

process(Sock, {ModName, ApplyArgs}, Line) ->
    [Cmd | CmdArgs] = string:tokens(binary_to_list(Line), " "),
    {ok, ApplyArgs2} = apply(ModName, cmd,
                             [list_to_atom(Cmd), ApplyArgs, Sock, CmdArgs]),
    % TODO: Need error handling here, to send ERROR on unknown cmd.
    % TODO: Does the connection close during other process exit/error?
    {ok, {ModName, ApplyArgs2}}.

session(UpstreamSock, Args) ->
    {ok, Line} = mc_ascii:recv_line(UpstreamSock),
    {ok, Args2} = process(UpstreamSock, Args, Line),
    session(UpstreamSock, Args2).

