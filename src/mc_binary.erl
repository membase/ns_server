%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(mc_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-export([bin/1, recv/2, recv/3, send/4, encode/3]).

-define(FLUSH_TIMEOUT, 15000).
-define(RECV_TIMEOUT, 15000).

%% Functions to work with memcached binary protocol packets.

send({OutPid, CmdNum}, Kind, Header, Entry) ->
    OutPid ! {send, CmdNum, encode(Kind, Header, Entry)},
    ok;

send(Sock, Kind, Header, Entry) ->
    send(Sock, encode(Kind, Header, Entry)).

recv(Sock, HeaderKind) ->
    recv(Sock, HeaderKind, undefined).

recv(Sock, HeaderKind, undefined) ->
    recv(Sock, HeaderKind, ?RECV_TIMEOUT);

recv(Sock, HeaderKind, Timeout) ->
    case recv_data(Sock, ?HEADER_LEN, Timeout) of
        {ok, HeaderBin} ->
            {Header, Entry} = decode_header(HeaderKind, HeaderBin),
            recv_body(Sock, Header, Entry, Timeout);
        Err -> Err
    end.

recv_body(Sock, #mc_header{extlen = ExtLen,
                           keylen = KeyLen,
                           bodylen = BodyLen} = Header, Entry, Timeout) ->
    case BodyLen > 0 of
        true ->
            true = BodyLen >= (ExtLen + KeyLen),
            {ok, Ext} = recv_data(Sock, ExtLen, Timeout),
            {ok, Key} = recv_data(Sock, KeyLen, Timeout),
            {ok, Data} = recv_data(Sock,
                                   erlang:max(0, BodyLen - (ExtLen + KeyLen)),
                                   Timeout),
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
                  vbucket = VBucket},
       #mc_entry{ext = Ext, key = Key, cas = CAS,
                 data = Data, datatype = DataType}) ->
    ExtLen = bin_size(Ext),
    KeyLen = bin_size(Key),
    BodyLen = ExtLen + KeyLen + bin_size(Data),
    [<<Magic:8, Opcode:8, KeyLen:16, ExtLen:8, DataType:8,
       VBucket:16, BodyLen:32, Opaque:32, CAS:64>>,
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

bin(undefined) -> <<>>;
bin(X)         -> iolist_to_binary(X).

bin_size(undefined) -> 0;
bin_size(X)         -> iolist_size(X).

send({OutPid, CmdNum}, Data) when is_pid(OutPid) ->
    OutPid ! {send, CmdNum, Data};

send(undefined, _Data)              -> ok;
send(_Sock, <<>>)                   -> ok;
send(Sock, List) when is_list(List) -> send(Sock, iolist_to_binary(List));
send(Sock, Data)                    -> prim_inet:send(Sock, Data).

%% @doc Receive binary data of specified number of bytes length.
recv_data(_, 0, _)                 -> {ok, <<>>};
recv_data(Sock, NumBytes, Timeout) -> prim_inet:recv(Sock, NumBytes, Timeout).
