-module(mc_server_ascii_dict).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

cmd(get, Dict, Sock, []) ->
    mc_ascii:send(Sock, <<"END\r\n">>),
    {ok, Dict};
cmd(get, Dict, Sock, [Key | Rest]) ->
    ?debugFmt("mcsad - cmd.get ~p ~p ~p~n", [Dict, Sock, Key]),
    KeyB = iolist_to_binary(Key),
    mc_ascii:send(Sock, <<"VALUE ", KeyB/binary, " 0 3\r\nAAA\r\n">>),
    cmd(get, Dict, Sock, Rest);

cmd(quit, _Dict, _Sock, _Rest) ->
    exit({ok, quit_received}).

process(Sock, {ModName, ApplyArgs}, Line) ->
    [Cmd | CmdArgs] = string:tokens(Line, " "),
    {ok, ApplyArgs2} = apply(ModName, cmd,
                             [list_to_atom(Cmd), ApplyArgs, Sock, CmdArgs]),
    % TODO: Need error handling here, to send ERROR on unknown cmd.
    {ok, {ModName, ApplyArgs2}}.

session(UpstreamSock, Args) ->
    {ok, Line} =  mc_ascii:recv_line(UpstreamSock),
    {ok, Args2} = process(UpstreamSock, Args, Line),
    session(UpstreamSock, Args2).

