-module(mc_server_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-compile(export_all).

process(Sock, Args, Line) ->
    {ok, Args}.

session(UpstreamSock, Args) ->
    {ok, Line} =  mc_ascii:recv_line(UpstreamSock),
    {ok, Args2} = process(UpstreamSock, Args, Line),
    session(UpstreamSock, Args).

