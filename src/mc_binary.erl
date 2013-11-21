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

-export([bin/1, recv/2, recv/3, send/4, encode/3, quick_stats/4,
         quick_stats/5, quick_stats_append/3,
         mass_get_last_closed_checkpoint/3,
         decode_packet/1]).

-define(RECV_TIMEOUT, ns_config:get_timeout_fast(memcached_recv, 120000)).
-define(QUICK_STATS_RECV_TIMEOUT, ns_config:get_timeout_fast(memcached_stats_recv, 180000)).

%% Functions to work with memcached binary protocol packets.

recv_with_data(Sock, Len, TimeoutRef, Data) ->
    DataSize = erlang:size(Data),
    case DataSize >= Len of
        true ->
            RV = binary_part(Data, 0, Len),
            Rest = binary_part(Data, Len, DataSize-Len),
            {ok, RV, Rest};
        false ->
            ok = inet:setopts(Sock, [{active, once}]),
            receive
                {tcp, Sock, NewData} ->
                    recv_with_data(Sock, Len, TimeoutRef, <<Data/binary, NewData/binary>>);
                {tcp_closed, Sock} ->
                    {error, closed};
                TimeoutRef ->
                    {error, timeout}
            end
    end.

quick_stats_recv(Sock, Data, TimeoutRef) ->
    {ok, Hdr, Rest} = recv_with_data(Sock, ?HEADER_LEN, TimeoutRef, Data),
    {Header, Entry} = decode_header(res, Hdr),
    #mc_header{extlen = ExtLen,
               keylen = KeyLen,
               bodylen = BodyLen} = Header,
    case BodyLen > 0 of
        true ->
            true = BodyLen >= (ExtLen + KeyLen),
            {ok, Ext, Rest2} = recv_with_data(Sock, ExtLen, TimeoutRef, Rest),
            {ok, Key, Rest3} = recv_with_data(Sock, KeyLen, TimeoutRef, Rest2),
            RealBodyLen = erlang:max(0, BodyLen - (ExtLen + KeyLen)),
            {ok, BodyData, Rest4} = recv_with_data(Sock, RealBodyLen, TimeoutRef, Rest3),
            {ok, Header, Entry#mc_entry{ext = Ext, key = Key, data = BodyData}, Rest4};
        false ->
            {ok, Header, Entry, Rest}
    end.

%% assumes active option is false
mass_get_last_closed_checkpoint(Socket, VBuckets, Timeout) ->
    ok = inet:setopts(Socket, [{active, true}]),
    Ref = make_ref(),
    MaybeTimer = case Timeout of
                     infinity ->
                         [];
                     _ ->
                         erlang:send_after(Timeout, self(), Ref)
                 end,
    try
        ok = prim_inet:send(
               Socket,
               [encode(?REQ_MAGIC,
                       #mc_header{opcode=?CMD_LAST_CLOSED_CHECKPOINT,
                                  vbucket=VB},
                       #mc_entry{})
                || VB <- VBuckets]),
        lists:reverse(mass_get_last_closed_checkpoint_loop(Socket, VBuckets, Ref, <<>>, []))
    after
        inet:setopts(Socket, [{active, false}]),
        case MaybeTimer of
            [] ->
                [];
            T ->
                erlang:cancel_timer(T)
        end,
        receive
            Ref -> ok
        after 0 -> ok
        end
    end.

mass_get_last_closed_checkpoint_loop(_Socket, [], _Ref, <<>>, Acc) ->
    Acc;
mass_get_last_closed_checkpoint_loop(Socket, [ThisVBucket | RestVBuckets], Ref, PrevData, Acc) ->
    {ok, Header, Entry, Rest} = quick_stats_recv(Socket, PrevData, Ref),
    Checkpoint =
        case Header of
            #mc_header{status=?SUCCESS} ->
                #mc_entry{data = <<CheckpointV:64>>} = Entry,
                CheckpointV;
            _ ->
                0
        end,
    NewAcc = [{ThisVBucket, Checkpoint} | Acc],
    mass_get_last_closed_checkpoint_loop(Socket, RestVBuckets, Ref, Rest, NewAcc).

quick_stats_append(K, V, Acc) ->
    [{K, V} | Acc].

quick_stats(Sock, Key, CB, CBState) ->
    quick_stats(Sock, Key, CB, CBState, ?QUICK_STATS_RECV_TIMEOUT).

%% quick_stats is like mc_client_binary:stats but with own buffering
%% of stuff and thus much faster. Note: we don't expect any request
%% pipelining here
quick_stats(Sock, Key, CB, CBState, Timeout) ->
    Req = encode(req, #mc_header{opcode=?STAT}, #mc_entry{key=Key}),
    Ref = make_ref(),
    MaybeTimer = case Timeout of
                     infinity ->
                         [];
                     _ ->
                         erlang:send_after(Timeout, self(), Ref)
                 end,
    try
        send(Sock, Req),
        quick_stats_loop(Sock, CB, CBState, Ref, <<>>)
    after
        case MaybeTimer of
            [] ->
                [];
            T ->
                erlang:cancel_timer(T)
        end,
        receive
            Ref -> ok
        after 0 -> ok
        end
    end.

quick_stats_loop(Sock, CB, CBState, TimeoutRef, Data) ->
    {ok, Header, Entry, Rest} = quick_stats_recv(Sock, Data, TimeoutRef),
    #mc_header{keylen = RKeyLen} = Header,
    case RKeyLen =:= 0 of
        true ->
            <<>> = Rest,
            {ok, CBState};
        false ->
            NewState = CB(Entry#mc_entry.key, Entry#mc_entry.data, CBState),
            quick_stats_loop(Sock, CB, NewState, TimeoutRef, Rest)
    end.

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

decode_header(<<?REQ_MAGIC:8, _Rest/binary>> = Header) ->
    decode_header(req, Header);
decode_header(<<?RES_MAGIC:8, _Rest/binary>> = Header) ->
    decode_header(res, Header).

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

decode_packet(<<HeaderBin:?HEADER_LEN/binary, Body/binary>>) ->
    {#mc_header{extlen = ExtLen, keylen = KeyLen} = Header, Entry} =
        decode_header(HeaderBin),
    <<Ext:ExtLen/binary, Key:KeyLen/binary, Data/binary>> = Body,
    {Header, Entry#mc_entry{ext = Ext, key = Key, data = Data}}.

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
