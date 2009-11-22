-module(mc_server_ascii_dict).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

% Note: this simple memcached ascii protocol server
% has an independent dict per session.

-record(session_dict, {cas = 0, tbl = dict:new()}).

session(_Sock, Env, _ProtocolModule) ->
    {ok, Env, #session_dict{}}.

cmd(get, Dict, _InSock, Out, []) ->
    mc_ascii:send(Out, <<"END\r\n">>),
    {ok, Dict};
cmd(get, Dict, InSock, Out, [Key | Rest]) ->
    case dict:find(Key, Dict#session_dict.tbl) of
        {ok, #mc_entry{flag = Flag, data = Data}} ->
            FlagStr = integer_to_list(Flag),
            DataLen = integer_to_list(bin_size(Data)),
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

cmd(quit, _Dict, _InSock, _Out, _Rest) ->
    exit({ok, quit_received}).

bin_size(undefined) -> 0;
bin_size(List) when is_list(List) -> bin_size(iolist_to_binary(List));
bin_size(Binary) -> size(Binary).

% ------------------------------------------

% For testing...
%
main() ->
    mc_accept:start(11222, {mc_server_ascii, mc_server_ascii_dict, {}}).

