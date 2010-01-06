% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

%% Functions to work with memcached binary protocol packets.

send_recv(Sock, RecvCallback, Header, Entry, Success) ->
    {ok, RecvHeader, RecvEntry} =
        send_recv(Sock, RecvCallback, Header, Entry),
    V1 = RecvHeader#mc_header.opcode,
    V1 = Header#mc_header.opcode,
    SR = RecvHeader#mc_header.status,
    case SR =:= ?SUCCESS of
        true  -> {ok, Success};
        false -> {error, RecvHeader, RecvEntry}
    end.

send_recv(Sock, RecvCallback, Header, Entry) ->
    ok = send(Sock, req, Header, Entry),
    {ok, RecvHeader, RecvEntry} = recv(Sock, res),
    case is_function(RecvCallback) of
       true  -> RecvCallback(RecvHeader, RecvEntry);
       false -> ok
    end,
    {ok, RecvHeader, RecvEntry}.

send({OutPid, CmdNum}, Kind, Header, Entry) ->
    OutPid ! {send, CmdNum, encode(Kind, Header, Entry)},
    ok;

send(Sock, Kind, Header, Entry) ->
    send(Sock, encode(Kind, Header, Entry)).

recv(Sock, HeaderKind) ->
    case recv_data(Sock, ?HEADER_LEN) of
        {ok, HeaderBin} ->
            {Header, Entry} = decode_header(HeaderKind, HeaderBin),
            recv_body(Sock, Header, Entry);
        Err -> Err
    end.

recv_prefix(Prefix, Sock, HeaderKind) ->
    PrefixLen = bin_size(Prefix),
    HeaderRestLen = ?HEADER_LEN - PrefixLen,
    case recv_data(Sock, HeaderRestLen) of
        {ok, HeaderRest} ->
            HeaderBin = <<Prefix/binary, HeaderRest/binary>>,
            {Header, Entry} = decode_header(HeaderKind, HeaderBin),
            recv_body(Sock, Header, Entry);
        Err -> Err
    end.

recv_body(Sock, #mc_header{extlen = ExtLen,
                           keylen = KeyLen,
                           bodylen = BodyLen} = Header, Entry) ->
    case BodyLen > 0 of
        true ->
            true = BodyLen >= (ExtLen + KeyLen),
            {ok, Ext} = recv_data(Sock, ExtLen),
            {ok, Key} = recv_data(Sock, KeyLen),
            {ok, Data} = recv_data(Sock, erlang:max(0, BodyLen - (ExtLen + KeyLen))),
            {ok, Header, Entry#mc_entry{ext = Ext, key = Key, data = Data}};
        false ->
            {ok, Header, Entry}
    end.

encode(req, Header, Entry) ->
    encode(?REQ_MAGIC, Header, Entry);
encode(res, Header, Entry) ->
    encode(?RES_MAGIC, Header, Entry);
encode(Magic,
       #mc_header{opcode = Opcode, opaque = Opaque,
                  status = StatusOrReserved},
       #mc_entry{ext = Ext, key = Key, cas = CAS,
                 data = Data, datatype = DataType}) ->
    ExtLen = bin_size(Ext),
    KeyLen = bin_size(Key),
    BodyLen = ExtLen + KeyLen + bin_size(Data),
    [<<Magic:8, Opcode:8, KeyLen:16, ExtLen:8, DataType:8,
       StatusOrReserved:16, BodyLen:32, Opaque:32, CAS:64>>,
     bin(Ext), bin(Key), bin(Data)].

decode_header(req, <<?REQ_MAGIC:8, Opcode:8, KeyLen:16, ExtLen:8,
                     DataType:8, Reserved:16, BodyLen:32,
                     Opaque:32, CAS:64>>) ->
    {#mc_header{opcode = Opcode, status = Reserved, opaque = Opaque,
                keylen = KeyLen, extlen = ExtLen, bodylen = BodyLen},
     #mc_entry{datatype = DataType, cas = CAS}};

decode_header(res, <<?RES_MAGIC:8, Opcode:8, KeyLen:16, ExtLen:8,
                     DataType:8, Status:16, BodyLen:32,
                     Opaque:32, CAS:64>>) ->
    {#mc_header{opcode = Opcode, status = Status, opaque = Opaque,
                keylen = KeyLen, extlen = ExtLen, bodylen = BodyLen},
     #mc_entry{datatype = DataType, cas = CAS}}.

% Convert binary Opcode/Status to ascii result string.
b2a_code(?SET,    ?SUCCESS)    -> <<"STORED\r\n">>;
b2a_code(?NOOP,   ?SUCCESS)    -> <<"END\r\n">>;
b2a_code(?DELETE, ?SUCCESS)    -> <<"DELETED\r\n">>;
b2a_code(?DELETE, ?KEY_ENOENT) -> <<"NOT_FOUND\r\n">>;

b2a_code(_, ?SUCCESS) -> <<"OK\r\n">>;
b2a_code(_, _)        -> <<"ERROR\r\n">>.

bin(undefined)         -> <<>>;
bin(L) when is_list(L) -> iolist_to_binary(L);
bin(X)                 -> <<X/binary>>.

bin_size(undefined)               -> 0;
bin_size(List) when is_list(List) -> bin_size(iolist_to_binary(List));
bin_size(Binary)                  -> size(Binary).

send({OutPid, CmdNum}, Data) when is_pid(OutPid) ->
    OutPid ! {send, CmdNum, Data};

send(undefined, _Data)              -> ok;
send(_Sock, undefined)              -> ok;
send(_Sock, <<>>)                   -> ok;
send(Sock, List) when is_list(List) -> send(Sock, iolist_to_binary(List));
send(Sock, Data)                    -> gen_tcp:send(Sock, Data).

%% @doc Receive binary data of specified number of bytes length.
recv_data(_, 0)           -> {ok, <<>>};
recv_data(Sock, NumBytes) -> gen_tcp:recv(Sock, NumBytes).

% -------------------------------------------------

noop_test()->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, works} = send_recv(Sock, undefined,
                            #mc_header{opcode = ?NOOP}, #mc_entry{}, works),
    ok = gen_tcp:close(Sock).

flush_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    test_flush(Sock),
    ok = gen_tcp:close(Sock).

test_flush(Sock) ->
    {ok, works} = send_recv(Sock, undefined,
                            #mc_header{opcode = ?FLUSH}, #mc_entry{}, works).
