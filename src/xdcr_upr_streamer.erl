%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc
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
-module(xdcr_upr_streamer).

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("xdcr_upr_streamer.hrl").

%% if we're waiting for data and have unacked stuff we'll ack all
%% unacked stuff we have after this many milliseconds. This allows
%% messages larger than buffer size to be handled where dcp-server is
%% only willing to send them when sent-but-unacked data size is 0.
-define(FORCED_ACK_TIMEOUT, 200).

-export([stream_vbucket/8, get_failover_log/2]).

-export([test/0]).

-export([encode_req/1, encode_res/1, decode_packet/1, read_message_loop/2]).

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

encode_res(Packet) ->
    encode_req(Packet#dcp_packet{vbucket = Packet#dcp_packet.status}).

decode_packet(<<Magic:8, Opcode:8, KeyLen:16,
                ExtLen:8, DT:8, VB:16,
                BodyLen:32,
                Opaque:32,
                Cas:64, Rest/binary>> = FullBinary) ->
    case Rest of
        <<Body:BodyLen/binary, RestRest/binary>> ->
            <<Ext:ExtLen/binary, KB/binary>> = Body,
            <<Key0:KeyLen/binary, TrueBody0/binary>> = KB,
            Key = binary:copy(Key0),
            TrueBody = binary:copy(TrueBody0),
            case Magic of
                ?REQ_MAGIC ->
                    {req,
                     #dcp_packet{opcode = Opcode,
                                 datatype = DT,
                                 vbucket = VB,
                                 opaque = Opaque,
                                 cas = Cas,
                                 ext = Ext,
                                 key = Key,
                                 body = TrueBody},
                     RestRest,
                     ?HEADER_LEN + BodyLen};
                ?RES_MAGIC ->
                    {res,
                     #dcp_packet{opcode = Opcode,
                                 datatype = DT,
                                 status = VB,
                                 opaque = Opaque,
                                 cas = Cas,
                                 ext = Ext,
                                 key = Key,
                                 body = TrueBody},
                     RestRest,
                     ?HEADER_LEN + BodyLen}
            end;
        _ ->
            FullBinary
    end;
decode_packet(FullBinary) ->
    FullBinary.

build_stream_request_packet(Vb, Opaque,
                            StartSeqno, EndSeqno, VBUUID,
                            SnapshotStart, SnapshotEnd) ->
    Extra = <<0:64, StartSeqno:64, EndSeqno:64, VBUUID:64,
              SnapshotStart:64, SnapshotEnd:64>>,
    #dcp_packet{opcode = ?DCP_STREAM_REQ,
                vbucket = Vb,
                opaque = Opaque,
                ext = Extra}.

unpack_failover_log_loop(<<>>, Acc) ->
    Acc;
unpack_failover_log_loop(<<U:64/big, S:64/big, Rest/binary>>, Acc) ->
    Acc2 = [{U, S} | Acc],
    unpack_failover_log_loop(Rest, Acc2).

unpack_failover_log(Body) ->
    unpack_failover_log_loop(Body, []).

read_message_loop(Socket, Data) ->
    case decode_packet(Data) of
        Data ->
            {ok, MoreData} = gen_tcp:recv(Socket, 0),
            read_message_loop(Socket, <<Data/binary, MoreData/binary>>);
        {_Type, _Packet, _RestData, _} = Ok ->
            Ok
    end.

find_high_seqno(Socket, Vb) ->
    StatsKey = iolist_to_binary(io_lib:format("vbucket-seqno ~B", [Vb])),
    SeqnoKey = iolist_to_binary(io_lib:format("vb_~B:high_seqno", [Vb])),
    ok = gen_tcp:send(Socket,
                      encode_req(#dcp_packet{opcode = ?STAT,
                                             key = StatsKey})),
    stats_loop(Socket,
               fun (K, V, Acc) ->
                       if
                           K =:= SeqnoKey ->
                               list_to_integer(binary_to_list(V));
                           true ->
                               Acc
                       end
               end, undefined, <<>>).

start(Socket, Vb, FailoverId, StartSeqno0, SnapshotStart0, SnapshotEnd0, Callback, Acc, Parent) ->
    EndSeqno = find_high_seqno(Socket, Vb),

    {StartSeqno, SnapshotStart, SnapshotEnd} =
        case EndSeqno < SnapshotStart0 of
            true ->
                %% we actually need to rollback, but if we just pass
                %% EndSeqno that is lower than SnapshotStart, ep-engine
                %% will return an ERANGE error
                ?log_debug("high seqno ~B is lower than snapthot start seqno ~B",
                           [EndSeqno, SnapshotStart0]),
                {EndSeqno, EndSeqno, EndSeqno};
            false ->
                {StartSeqno0, SnapshotStart0, SnapshotEnd0}
        end,

    do_start(Socket, Vb, FailoverId,
             StartSeqno, EndSeqno, SnapshotStart, SnapshotEnd,
             Callback, Acc, Parent, false).

do_start(Socket, Vb, FailoverId,
         StartSeqno, EndSeqno, SnapshotStart, SnapshotEnd,
         Callback, Acc, Parent, HadRollback) ->
    Opaque = 16#fafafafa,

    SReq = build_stream_request_packet(Vb, Opaque, StartSeqno, EndSeqno,
                                       FailoverId, SnapshotStart, SnapshotEnd),
    ok = gen_tcp:send(Socket, encode_req(SReq)),

    %% NOTE: Opaque is already bound
    {res, #dcp_packet{opaque = Opaque} = Packet, Data0, _} = read_message_loop(Socket, <<>>),

    case Packet of
        #dcp_packet{status = ?SUCCESS, body = FailoverLogBin} ->
            FailoverLog = unpack_failover_log(FailoverLogBin),
            {Data2, ActualSnapshotEnd} =
            case read_message_loop(Socket, Data0) of
                {_, #dcp_packet{opcode = ?DCP_SNAPSHOT_MARKER, ext = Ext}, Data1, _} ->
                    <<ActualSnapshotStart:64, ActualSnapshotEnd0:64, _Flags:32, _/binary>> = Ext,

                    SnapshotStart = ActualSnapshotStart,
                    {Data1, ActualSnapshotEnd0};
                {_, EndPacket = #dcp_packet{opcode = ?DCP_STREAM_END}, <<>>, _} ->
                    ?log_debug("Got stream end without snapshot marker"),
                    %% it's only possible if all those values are same
                    %%
                    %% * immediate end stream is only possible if
                    %% StartSeqno = EndSeqno
                    %%
                    %% * if StartSeqno != SnapshotStart then
                    %% StartSeqno != SnapshotEnd, then given that
                    %% StartSeqno = EndSeqno and given that EndSeqno
                    %% is latest seqno, then we'd have rollback and
                    %% not success followed by end stream
                    SnapshotEnd = SnapshotStart = StartSeqno = EndSeqno,

                    %% we fake snapshot marker here, and we "unput"
                    %% end stream packet to handle it normally
                    {iolist_to_binary(encode_req(EndPacket)), SnapshotEnd}
            end,

            {FailoverUUID, _} = lists:last(FailoverLog),
            Parent ! {failover_id, FailoverUUID,
                      StartSeqno, EndSeqno, SnapshotStart, ActualSnapshotEnd},
            proc_lib:init_ack({ok, self()}),
            socket_loop_enter(Socket, Callback, Acc, Data2, Parent);
        #dcp_packet{status = ?ROLLBACK, body = <<RollbackSeq:64>>} ->
            ?log_debug("handling rollback to ~B", [RollbackSeq]),
            ?log_debug("Request was: ~p", [{Vb, Opaque, StartSeqno, EndSeqno,
                                            FailoverId, SnapshotStart, SnapshotEnd}]),
            %% in case of xdcr we cannot rewind the destination. So we
            %% just "formally" rollback our start point to resume
            %% streaming at "better than nothing" position
            {had_rollback, false} = {had_rollback, HadRollback},
            do_start(Socket, Vb, FailoverId,
                     RollbackSeq, EndSeqno, RollbackSeq, RollbackSeq,
                     Callback, Acc, Parent, true)
    end.

stream_vbucket(Bucket, Vb, FailoverId,
               StartSeqno, SnapshotStart, SnapshotEnd, Callback, Acc) ->
    true = is_list(Bucket),
    Parent = self(),
    {ok, Child} =
        proc_lib:start_link(erlang, apply,
                            [fun stream_vbucket_inner/9,
                             [Bucket, Vb, FailoverId,
                              StartSeqno, SnapshotStart, SnapshotEnd,
                              Callback, Acc, Parent]]),

    enter_consumer_loop(Child, Callback, Acc).

stream_vbucket_inner(Bucket, Vb, FailoverId,
                     StartSeqno, SnapshotStart, SnapshotEnd,
                     Callback, Acc, Parent) ->
    {ok, S} = xdcr_upr_sockets_pool:take_socket(Bucket),
    case start(S, Vb, FailoverId, StartSeqno,
               SnapshotStart, SnapshotEnd, Callback, Acc, Parent) of
        ok ->
            ok = xdcr_upr_sockets_pool:put_socket(Bucket, S);
        stop ->
            ?log_debug("Got stop. Dropping socket on the floor")
    end.


scan_for_nops(Data, Pos) ->
    case Data of
        <<_:Pos/binary, Hdr:(?HEADER_LEN)/binary, _Rest/binary>> ->
            <<Magic:8, Opcode:8, _:16,
              _:8, _:8, _:16,
              BodySize:32,
              Opaque:32,
              _:64>> = Hdr,
            case Magic =:= ?REQ_MAGIC andalso Opcode =:= ?DCP_NOP of
                true ->
                    {body_size, 0} = {body_size, BodySize},
                    {Opaque, Pos + ?HEADER_LEN};
                false ->
                    NewPos = Pos + ?HEADER_LEN + BodySize,
                    case NewPos > erlang:size(Data) of
                        true ->
                            Pos;
                        _ ->
                            scan_for_nops(Data, NewPos)
                    end
            end;
        _ ->
            Pos
    end.

nops_loop(Socket, Data, Pos) ->
    case scan_for_nops(Data, Pos) of
        {Opaque, NewPos} ->
            respond_nop(Socket, Opaque),
            nops_loop(Socket, Data, NewPos);
        NewPos ->
            NewPos
    end.

respond_nop(Socket, Opaque) ->
    Packet = #dcp_packet{opcode = ?DCP_NOP,
                         opaque = Opaque},
    ok = gen_tcp:send(Socket, encode_res(Packet)).

socket_loop_enter(Socket, Callback, Acc, Data, Consumer) ->
    case Data of
        <<>> ->
            ok;
        _ ->
            self() ! {tcp, Socket, Data}
    end,
    inet:setopts(Socket, [{active, true}]),
    socket_loop(Socket, Callback, Acc, <<>>, Consumer).

socket_loop(Socket, Callback, Acc, Data, Consumer) ->
    Msg = receive
              XMsg ->
                  XMsg
          end,
    case Msg of
        {tcp, _Socket, NewData0} ->
            NewData = case Data of
                          <<>> ->
                              NewData0;
                          _ ->
                              <<Data/binary, NewData0/binary>>
                      end,
            SplitPos = nops_loop(Socket, NewData, 0),
            <<ScannedData:SplitPos/binary, UnscannedData/binary>> = NewData,
            case SplitPos =/= 0 of
                true ->
                    Consumer ! ScannedData;
                _ ->
                    ok
            end,
            socket_loop(Socket, Callback, Acc, UnscannedData, Consumer);
        {tcp_closed, MustSocket} ->
            {tcp_closed_socket, Socket} = {tcp_closed_socket, MustSocket},
            erlang:error(premature_socket_closure);
        ConsumedBytes when is_integer(ConsumedBytes) ->
            ok = gen_tcp:send(Socket, encode_req(#dcp_packet{opcode = ?DCP_WINDOW_UPDATE,
                                                             ext = <<ConsumedBytes:32/big>>})),
            socket_loop(Socket, Callback, Acc, Data, Consumer);
        done ->
            ok = gen_tcp:send(Socket, encode_req(#dcp_packet{opcode = ?DCP_WINDOW_UPDATE,
                                                             ext = <<(?XDCR_DCP_BUFFER_SIZE):32/big>>}));
        stop ->
            stop
    end.

enter_consumer_loop(Child, Callback, Acc) ->
    receive
        {failover_id, _FailoverUUID, StartSeqno, _, SnapshotStart, SnapshotEnd} = Evt ->
            {ok, Acc2} = Callback(Evt, Acc),
            consumer_loop_recv(Child, Callback, Acc2, 0,
                               SnapshotStart, SnapshotEnd, StartSeqno, <<>>)
    end.

consumer_loop_recv(Child, Callback, Acc, ConsumedSoFar0,
                   SnapshotStart, SnapshotEnd, LastSeenSeqno,
                   PrevData) ->
    ConsumedSoFar =
        case ConsumedSoFar0 >= ?XDCR_DCP_BUFFER_SIZE div 3 of
            true ->
                Child ! ConsumedSoFar0,
                0;
            _ ->
                ConsumedSoFar0
        end,
    case ConsumedSoFar =/= 0 of
        true ->
            receive
                Msg ->
                    consumer_loop_have_msg(Child, Callback, Acc, ConsumedSoFar,
                                           SnapshotStart, SnapshotEnd, LastSeenSeqno,
                                           PrevData, Msg)
            after ?FORCED_ACK_TIMEOUT ->
                    Child ! ConsumedSoFar,
                    consumer_loop_recv(Child, Callback, Acc, 0,
                                       SnapshotStart, SnapshotEnd, LastSeenSeqno,
                                       PrevData)
            end;
        _ ->
            receive
                Msg ->
                    consumer_loop_have_msg(Child, Callback, Acc, ConsumedSoFar,
                                           SnapshotStart, SnapshotEnd, LastSeenSeqno,
                                           PrevData, Msg)
            end
    end.

consumer_loop_have_msg(Child, Callback, Acc, ConsumedSoFar,
                       SnapshotStart, SnapshotEnd, LastSeenSeqno,
                       PrevData, Msg) ->
    case Msg of
        MoreData when is_binary(MoreData) ->
            NewData = case PrevData of
                          <<>> -> MoreData;
                          _ -> <<PrevData/binary, MoreData/binary>>
                      end,
            consume_stuff_loop(Child, Callback, Acc, ConsumedSoFar,
                               SnapshotStart, SnapshotEnd, LastSeenSeqno,
                               NewData);
        {'EXIT', _From, Reason} = ExitMsg ->
            ?log_debug("Got exit signal: ~p", [ExitMsg]),
            exit(Reason);
        %% this is handling please_stop message for xdc_vbucket_rep
        %% changes reader loop efficiently, i.e. without selective
        %% receive
        %%
        %% TODO: there's great chance that having to process all
        %% buffered dcp mutations prior to handling this makes pausing
        %% too slow in practice
        OtherMsg ->
            case Callback(OtherMsg, Acc) of
                {ok, Acc2} ->
                    consumer_loop_recv(Child, Callback, Acc2, ConsumedSoFar,
                                       SnapshotStart, SnapshotEnd, LastSeenSeqno, PrevData);
                {stop, RV} ->
                    consumer_loop_exit(Child, stop, []),
                    RV
            end
    end.

consumer_loop_exit(Child, DoneOrStop, Data) ->
    Child ! DoneOrStop,
    misc:wait_for_process(Child, infinity),
    case DoneOrStop of
        done ->
            <<>> = Data,
            receive
                MoreData when is_binary(MoreData) ->
                    erlang:error({unexpected_data_after_done, MoreData})
            after 0 ->
                    ok
            end;
        stop ->
            consume_aborted_stuff()
    end.

consume_aborted_stuff() ->
    receive
        MoreData when is_binary(MoreData) ->
            consume_aborted_stuff()
    after 0 ->
            ok
    end.

consume_stuff_loop(Child, Callback, Acc, ConsumedSoFar,
                   SnapshotStart, SnapshotEnd, LastSeenSeqno,
                   Data) ->
    case decode_packet(Data) of
        {_Type, Packet, RestData, PacketSize} ->
            case Packet of
                #dcp_packet{opcode = ?DCP_MUTATION,
                            datatype = DT,
                            cas = CAS,
                            ext = Ext,
                            key = Key,
                            body = Body} ->
                    <<Seq:64, RevSeqno:64, Flags:32, Expiration:32, _/binary>> = Ext,
                    Rev = {RevSeqno, <<CAS:64, Expiration:32, Flags:32>>},
                    Doc = #dcp_mutation{id = Key,
                                        local_seq = Seq,
                                        rev = Rev,
                                        body = Body,
                                        datatype = DT,
                                        deleted = false,
                                        snapshot_start_seq = SnapshotStart,
                                        snapshot_end_seq = SnapshotEnd},
                    consume_stuff_call_callback(Doc,
                                                Child, Callback, Acc, ConsumedSoFar + PacketSize,
                                                SnapshotStart, SnapshotEnd, Seq,
                                                RestData);
                #dcp_packet{opcode = ?DCP_SNAPSHOT_MARKER, ext = Ext} ->
                    <<NewSnapshotStart:64, NewSnapshotEnd:64, _/binary>> = Ext,
                    consume_stuff_loop(Child, Callback, Acc, ConsumedSoFar + PacketSize,
                                       NewSnapshotStart, NewSnapshotEnd, LastSeenSeqno,
                                       RestData);
                #dcp_packet{opcode = ?DCP_DELETION,
                            cas = CAS,
                            ext = Ext,
                            key = Key} ->
                    <<Seq:64, RevSeqno:64, _/binary>> = Ext,
                    %% NOTE: as of now dcp doesn't expose flags of deleted
                    %% docs
                    Rev = {RevSeqno, <<CAS:64, 0:32, 0:32>>},
                    Doc = #dcp_mutation{id = Key,
                                        local_seq = Seq,
                                        rev = Rev,
                                        body = <<>>,
                                        datatype = 0,
                                        deleted = true,
                                        snapshot_start_seq = SnapshotStart,
                                        snapshot_end_seq = SnapshotEnd},
                    consume_stuff_call_callback(Doc,
                                                Child, Callback, Acc, ConsumedSoFar + PacketSize,
                                                SnapshotStart, SnapshotEnd, Seq,
                                                RestData);
                #dcp_packet{opcode = ?DCP_STREAM_END} ->
                    {stop, Acc2} = Callback({stream_end,
                                             SnapshotStart, SnapshotEnd, LastSeenSeqno}, Acc),
                    consumer_loop_exit(Child, done, RestData),
                    Acc2;
                #dcp_packet{opcode = ?DCP_NOP} ->
                    consume_stuff_loop(Child, Callback, Acc, ConsumedSoFar,
                                       SnapshotStart, SnapshotEnd, LastSeenSeqno,
                                       RestData)
            end;
        Data ->
            consumer_loop_recv(Child, Callback, Acc, ConsumedSoFar,
                               SnapshotStart, SnapshotEnd, LastSeenSeqno,
                               Data)
    end.

-compile({inline, [consume_stuff_call_callback/9]}).

consume_stuff_call_callback(Doc, Child, Callback, Acc, ConsumedSoFar,
                            SnapshotStart, SnapshotEnd, Seq,
                            RestData) ->
    erlang:put(last_doc, Doc),
    case Callback(Doc, Acc) of
        {ok, Acc2} ->
            consume_stuff_loop(Child, Callback, Acc2, ConsumedSoFar,
                               SnapshotStart, SnapshotEnd, Seq,
                               RestData);
        {stop, Acc2} ->
            consumer_loop_exit(Child, stop, []),
            Acc2
    end.

stream_loop(Socket, Callback, Acc, Data0) ->
    {_, Packet, Data1, _} = read_message_loop(Socket, Data0),
    case Callback(Packet, Acc) of
        {ok, Acc2} ->
            stream_loop(Socket, Callback, Acc2, Data1);
        {stop, RV} ->
            RV
    end.

stats_loop(S, Cb, InitAcc, Data) ->
    Cb2 = fun (Packet, Acc) ->
                  #dcp_packet{status = ?SUCCESS,
                              key = Key,
                              body = Value} = Packet,
                  case Key of
                      <<>> ->
                          {stop, Acc};
                      _ ->
                          {ok, Cb(Key, Value, Acc)}
                  end
          end,
    stream_loop(S, Cb2, InitAcc, Data).

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
              {ok, S} = xdcr_upr_sockets_pool:take_socket(Bucket),
              RV = do_get_failover_log(S, VB),
              ok = xdcr_upr_sockets_pool:put_socket(Bucket, S),
              RV
      end).


test() ->
    Cb = fun (Packet, Acc) ->
                 ?log_debug("packet: ~p", [Packet]),
                 case Packet of
                     {failover_id, _FUUID, _, _, _, _} ->
                         {ok, Acc};
                     {stream_end, _, _, _} = Msg ->
                         ?log_debug("StreamEnd: ~p", [Msg]),
                         {stop, lists:reverse(Acc)};
                     _ ->
                         %% NewAcc = [Packet|Acc],
                         NewAcc = Acc,
                         case length(NewAcc) >= 10 of
                             true ->
                                 {stop, {aborted, NewAcc}};
                             _ ->
                                 {ok, NewAcc}
                         end
                 end
         end,
    stream_vbucket("default", 0, 16#123123, 0, 1, 2, Cb, []).
