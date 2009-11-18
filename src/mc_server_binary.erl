-module(mc_server_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

process(Sock, {ModName, ApplyArgs}, Header, Entry) ->
    Cmd = Header#mc_header.opcode,
    {ok, ApplyArgs2} = apply(ModName, cmd,
                             [Cmd, ApplyArgs, Sock, {Header, Entry}]),
    {ok, {ModName, ApplyArgs2}}.

session(UpstreamSock, Args) ->
    {ok, Header, Entry} = mc_binary:recv(UpstreamSock, req),
    {ok, Args2} = process(UpstreamSock, Args, Header, Entry),
    session(UpstreamSock, Args2).

