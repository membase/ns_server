-module(mc_server_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-compile(export_all).

process(Sock, Args, Header, Entry) ->
    {ok, Args}.

session(UpstreamSock, Args) ->
    {ok, Header, Entry} = mc_binary:recv(UpstreamSock, req),
    {ok, Args2} = process(UpstreamSock, Args, Header, Entry),
    session(UpstreamSock, Args2).

