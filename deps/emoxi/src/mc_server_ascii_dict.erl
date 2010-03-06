% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_server_ascii_dict).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

% Note: this simple memcached ascii protocol server
% has an independent dict per session.

-record(session_dict, {cas = 0, tbl = dict:new()}).

session(_Sock, Env) ->
    {ok, Env, #session_dict{}}.

cmd(version, Dict, _InSock, Out, []) ->
    mc_ascii:send(Out, <<"VERSION mc_server_ascii_dict\r\n">>),
    {ok, Dict};

cmd(get, Dict, _InSock, Out, []) ->
    mc_ascii:send(Out, <<"END\r\n">>),
    {ok, Dict};
cmd(get, Dict, InSock, Out, [Key | Rest]) ->
    case dict:find(Key, Dict#session_dict.tbl) of
        {ok, #mc_entry{flag = Flag, data = Data}} ->
            FlagStr = integer_to_list(Flag),
            DataLen = integer_to_list(mc_binary:bin_size(Data)),
            mc_ascii:send(Out, [<<"VALUE ">>, Key,
                                " ", FlagStr,
                                " ", DataLen, <<"\r\n">>,
                                <<Data/binary>>, <<"\r\n">>]);
        _ -> ok
    end,
    cmd(get, Dict, InSock, Out, Rest);

cmd(set, Dict, InSock, Out, [Key, FlagIn, ExpireIn, DataLenIn]) ->
    Flag = list_to_integer(FlagIn),
    Expire = list_to_integer(ExpireIn),
    DataLen = list_to_integer(DataLenIn),
    {ok, DataCRNL} = mc_ascii:recv_data(InSock, DataLen + 2),
    {Data, _} = mc_ascii:split_binary_suffix(DataCRNL, 2),
    Cas2 = Dict#session_dict.cas + 1,
    Entry = #mc_entry{key = Key, cas = Cas2, data = Data,
                      flag = Flag, expire = Expire},
    Dict2 = Dict#session_dict{cas = Cas2,
                              tbl = dict:store(Key, Entry,
                                               Dict#session_dict.tbl)},
    mc_ascii:send(Out, <<"STORED\r\n">>),
    {ok, Dict2};

cmd(delete, Dict, _InSock, Out, [Key]) ->
    Dict2 = case dict:find(Key, Dict#session_dict.tbl) of
                {ok, _} ->
                    mc_ascii:send(Out, <<"DELETED\r\n">>),
                    Dict#session_dict{tbl = dict:erase(Key,
                                                       Dict#session_dict.tbl)};
                _ ->
                    mc_ascii:send(Out, <<"NOT_FOUND\r\n">>),
                    Dict
            end,
    {ok, Dict2};

cmd(flush_all, Dict, _InSock, Out, []) ->
    mc_ascii:send(Out, <<"OK\r\n">>),
    {ok, Dict#session_dict{tbl = dict:new()}};

cmd(quit, _Dict, _InSock, _Out, _Rest) ->
    exit({ok, quit_received});

cmd(_UnknownCmd, Dict, _InSock, Out, []) ->
    mc_ascii:send(Out, <<"ERROR\r\n">>),
    {ok, Dict}.

% ------------------------------------------

% For testing...
%
main()        -> main(11211).
main(PortNum) -> mc_accept:start(PortNum,
                                 {mc_server_ascii,
                                  mc_server_ascii_dict, {}}).

