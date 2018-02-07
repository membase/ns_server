%% @author Couchbase <info@couchbase.com>
%% @copyright 2014-2015 Couchbase, Inc.
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
-module(xdcr_dcp_streamer).

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("xdcr_dcp_streamer.hrl").

-export([get_failover_log/2]).

encode_req(#dcp_packet{opcode = Opcode,
                       datatype = DT,
                       vbucket = VB,
                       opaque = Opaque,
                       cas = Cas,
                       ext = Ext,
                       key = Key,
                       body = Body}) ->
    KeyLen = erlang:size(Key),
    {key, true} = {key, KeyLen < 16#10000},
    ExtLen = erlang:size(Ext),
    {ext, true} = {ext, ExtLen < 16#100},
    BodyLen = KeyLen + ExtLen + erlang:size(Body),
    [<<(?REQ_MAGIC):8, Opcode:8, KeyLen:16,
       ExtLen:8, DT:8, VB:16,
       BodyLen:32,
       Opaque:32,
       Cas:64>>,
     Ext,
     Key,
     Body].

try_decode_packet(<<Magic:8, Opcode:8, KeyLen:16,
                    ExtLen:8, DT:8, VB:16,
                    BodyLen:32,
                    Opaque:32,
                    Cas:64, Rest/binary>>) ->
    case byte_size(Rest) >= BodyLen of
        true ->
            decode_packet(Magic, Opcode, KeyLen, ExtLen, DT, VB,
                          BodyLen, Opaque, Cas, Rest);
        false ->
            {need_more_data, ?HEADER_LEN + BodyLen}
    end;
try_decode_packet(_) ->
    {need_more_data, ?HEADER_LEN}.

decode_packet(Magic, Opcode, KeyLen, ExtLen, DT, VB,
              BodyLen, Opaque, Cas,
              Data) ->
    <<Body:BodyLen/binary, Rest/binary>> = Data,
    <<Ext:ExtLen/binary, KB/binary>> = Body,
    <<Key0:KeyLen/binary, TrueBody0/binary>> = KB,
    Key = binary:copy(Key0),
    TrueBody = binary:copy(TrueBody0),

    case Magic of
        ?REQ_MAGIC ->
            {ok, {req,
                  #dcp_packet{opcode = Opcode,
                              datatype = DT,
                              vbucket = VB,
                              opaque = Opaque,
                              cas = Cas,
                              ext = Ext,
                              key = Key,
                              body = TrueBody},
                  Rest,
                  ?HEADER_LEN + BodyLen}};
        ?RES_MAGIC ->
            {ok, {res,
                  #dcp_packet{opcode = Opcode,
                              datatype = DT,
                              status = VB,
                              opaque = Opaque,
                              cas = Cas,
                              ext = Ext,
                              key = Key,
                              body = TrueBody},
                  Rest,
                  ?HEADER_LEN + BodyLen}}
    end.

unpack_failover_log_loop(<<>>, Acc) ->
    Acc;
unpack_failover_log_loop(<<U:64/big, S:64/big, Rest/binary>>, Acc) ->
    Acc2 = [{U, S} | Acc],
    unpack_failover_log_loop(Rest, Acc2).

unpack_failover_log(Body) ->
    unpack_failover_log_loop(Body, []).

read_message_loop(Socket, Data) ->
    do_read_message_loop(Socket, Data, byte_size(Data), 0).

do_read_message_loop(Socket, Data, Len, NeedLen) ->
    case Len >= NeedLen of
        true ->
            case try_decode_packet(Data) of
                {ok, Packet} ->
                    Packet;
                {need_more_data, NewNeedLen} ->
                    do_read_message_loop_recv_more(Socket, Data, Len, NewNeedLen)
            end;
        false ->
            do_read_message_loop_recv_more(Socket, Data, Len, NeedLen)
    end.

do_read_message_loop_recv_more(Socket, Data, Len, NeedLen) ->
    {ok, MoreData} = gen_tcp:recv(Socket, 0),
    do_read_message_loop(Socket, <<Data/binary, MoreData/binary>>,
                         Len + byte_size(MoreData), NeedLen).

do_get_failover_log(Socket, VB) ->
    ok = gen_tcp:send(Socket,
                      encode_req(#dcp_packet{opcode = ?DCP_GET_FAILOVER_LOG,
                                             vbucket = VB})),

    {res, Packet, <<>>, _} = read_message_loop(Socket, <<>>),
    case Packet#dcp_packet.status of
        ?SUCCESS ->
            unpack_failover_log(Packet#dcp_packet.body);
        OtherError ->
            {memcached_error, mc_client_binary:map_status(OtherError)}
    end.

get_failover_log(Bucket, VB) ->
    misc:executing_on_new_process(
      fun () ->
              {ok, S} = xdcr_dcp_sockets_pool:take_socket(Bucket),
              RV = do_get_failover_log(S, VB),
              ok = xdcr_dcp_sockets_pool:put_socket(Bucket, S),
              RV
      end).
