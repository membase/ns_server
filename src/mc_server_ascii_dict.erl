-module(mc_server_ascii_dict).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

% Note: this simple memcached ascii protocol server
% has an independent dict per session.

-record(mc_session_dict, {cas = 0, tbl = dict:new()}).

create_dict() ->
    #mc_session_dict{}.

cmd(get, Dict, Sock, []) ->
    mc_ascii:send(Sock, <<"END\r\n">>),
    {ok, Dict};
cmd(get, Dict, Sock, [Key | Rest]) ->
    case dict:find(Key, Dict#mc_session_dict.tbl) of
        {ok, #mc_entry{flag = Flag, data = Data}} ->
            FlagStr = integer_to_list(Flag),
            DataLen = integer_to_list(bin_size(Data)),
            mc_ascii:send(Sock, [<<"VALUE ">>, Key,
                                 " ", FlagStr,
                                 " ", DataLen, <<"\r\n">>,
                                 <<Data/binary>>, <<"\r\n">>]);
        _ -> ok
    end,
    cmd(get, Dict, Sock, Rest);

cmd(set, Dict, Sock, [Key, FlagIn, ExpireIn, DataLenIn]) ->
    Flag = list_to_integer(FlagIn),
    Expire = list_to_integer(ExpireIn),
    DataLen = list_to_integer(DataLenIn),
    {ok, DataCRNL} = mc_ascii:recv_data(Sock, DataLen + 2),
    {Data, _} = mc_ascii:split_binary_suffix(DataCRNL, 2),
    Cas2 = Dict#mc_session_dict.cas + 1,
    Entry = #mc_entry{key = Key, cas = Cas2, data = Data,
                      flag = Flag, expire = Expire},
    Dict2 = Dict#mc_session_dict{cas = Cas2,
                                 tbl = dict:store(Key, Entry,
                                                  Dict#mc_session_dict.tbl)},
    mc_ascii:send(Sock, <<"STORED\r\n">>),
    {ok, Dict2};

cmd(quit, _Dict, _Sock, _Rest) ->
    exit({ok, quit_received}).

bin_size(undefined) -> 0;
bin_size(List) when is_list(List) -> bin_size(iolist_to_binary(List));
bin_size(Binary) -> size(Binary).

% ------------------------------------------

% For testing...
%
main() ->
    mc_main:start(11222,
                  {mc_server_ascii, session,
                   {mc_server_ascii_dict, create_dict()}}).

