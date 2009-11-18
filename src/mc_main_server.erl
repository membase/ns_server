-module (mc_main_server).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-compile(export_all).

process_ascii(Sock, Args, Line) ->
    {ok, Args}.

process_binary(Sock, Args, Header, Entry) ->
    {ok, Args}.

session_ascii(UpstreamSock, Args) ->
    process_ascii(UpstreamSock, Args, gen_tcp:recv(UpstreamSock, ?HEADER_LEN)),
    session_ascii(UpstreamSock, Args).

session_binary(UpstreamSock, Args) ->
    {ok, Header, Entry} = mc_binary:recv(UpstreamSock, req),
    {ok, Args2} = process_binary(UpstreamSock, Args, Header, Entry),
    session_binary(UpstreamSock, Args2).

