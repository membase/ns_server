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

-define(BUFFER_SIZE, 1048576).

-export([stream_vbucket/8, get_failover_log/2]).

-export([test/0]).

-export([encode_req/1, encode_res/1, decode_packet/1]).

encode_req(#upr_packet{opcode = Opcode,
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
    encode_req(Packet#upr_packet{vbucket = Packet#upr_packet.status}).

decode_packet(<<Magic:8, Opcode:8, KeyLen:16,
                ExtLen:8, DT:8, VB:16,
                BodyLen:32,
                Opaque:32,
                Cas:64, Rest/binary>> = FullBinary) ->
    case Rest of
        <<Body:BodyLen/binary, RestRest/binary>> ->
            build_decoded_packet(Magic, Opcode,
                                 KeyLen, ExtLen,
                                 DT, VB, Opaque,
                                 Cas, Body, RestRest);
        _ ->
            FullBinary
    end;
decode_packet(FullBinary) ->
    FullBinary.

build_decoded_packet(Magic, Opcode, KeyLen, ExtLen, DT, VB, Opaque, Cas, Body, RestRest) ->
    <<Ext:ExtLen/binary, KB/binary>> = Body,
    <<Key:KeyLen/binary, TrueBody/binary>> = KB,
    case Magic of
        ?REQ_MAGIC ->
            {req,
             #upr_packet{opcode = Opcode,
                         datatype = DT,
                         vbucket = VB,
                         opaque = Opaque,
                         cas = Cas,
                         ext = Ext,
                         key = Key,
                         body = TrueBody},
             RestRest};
        ?RES_MAGIC ->
            {res,
             #upr_packet{opcode = Opcode,
                         datatype = DT,
                         status = VB,
                         opaque = Opaque,
                         cas = Cas,
                         ext = Ext,
                         key = Key,
                         body = TrueBody},
             RestRest}
    end.

build_stream_request_packet(Vb, Opaque, StartSeqno, EndSeqno, VBUUID, VBUUIDSeqno) ->
    Extra = <<0:64, StartSeqno:64, EndSeqno:64, VBUUID:64, VBUUIDSeqno:64>>,
    #upr_packet{opcode = ?UPR_STREAM_REQ,
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
        {_Type, _Packet, _RestData} = Ok ->
            Ok
    end.

find_high_seqno(Socket, Vb) ->
    StatsKey = iolist_to_binary(io_lib:format("vbucket-seqno ~B", [Vb])),
    SeqnoKey = iolist_to_binary(io_lib:format("vb_~B:high_seqno", [Vb])),
    UUIDKey = iolist_to_binary(io_lib:format("vb_~B:uuid", [Vb])),
    ok = gen_tcp:send(Socket,
                      encode_req(#upr_packet{opcode = ?STAT,
                                             key = StatsKey})),
    stats_loop(Socket,
               fun (K, V, {UAcc, SAcc}) ->
                       if
                           K =:= SeqnoKey ->
                               {UAcc, list_to_integer(binary_to_list(V))};
                           K =:= UUIDKey ->
                               {list_to_integer(binary_to_list(V)), SAcc};
                           true ->
                               {UAcc, SAcc}
                       end
               end, {[], []}, <<>>).

start(Socket, Vb, FailoverId, FailoverSeqno, LastSnapshotSeqno, StartSeqno, Callback, Acc, Parent) ->
    {VBUUID, HighSeqno} = find_high_seqno(Socket, Vb),
    %% NOTE: this is workaround of lack of protocol support in
    %% UPR. This check is in fact raceful (time of stats vs. time of stream_req) in StartSeqno path
    RealStartSeqno = case LastSnapshotSeqno =/= StartSeqno andalso VBUUID =/= FailoverId of
                         true ->
                             ?log_debug("rolling back to last full snapshot: ~B", [LastSnapshotSeqno]),
                             case HighSeqno < LastSnapshotSeqno of
                                 true ->
                                     %% Otherwise ep-engine refuses instead of doing rollback
                                     ?log_debug("LastSnapshotSeqno is higher then high seqno. Lowering to ~B", [HighSeqno]),
                                     HighSeqno;
                                 _ ->
                                     LastSnapshotSeqno
                             end;
                         _ ->
                             StartSeqno
                     end,
    %% note: due to "lowering..." above we will otherwise get last
    %% snapshot seqno > start seqno which is nonsense
    UsedLastSnapshotSeqno = erlang:min(LastSnapshotSeqno, RealStartSeqno),
    do_start(Socket, Vb, FailoverId, FailoverSeqno, RealStartSeqno, HighSeqno, Callback, Acc, Parent, false, UsedLastSnapshotSeqno).

%% right now logs are spammed if some linked process
%% dies. This prevents spamming. We'll need to find some
%% better way of doing it eventually.
%%
%% Trick below is to fool dialyzer :)
set_sensitive_flag() ->
    erlang:process_flag(list_to_atom("sensitive"), true).

do_start(Socket, Vb, FailoverId, FailoverSeqno, RealStartSeqno, HighSeqno, Callback, Acc, Parent, HadRollback, LastSnapshotSeqno) ->
    Opaque = 16#fafafafa,
    SReq = build_stream_request_packet(Vb, Opaque, RealStartSeqno, HighSeqno, FailoverId, FailoverSeqno),
    ok = gen_tcp:send(Socket, encode_req(SReq)),

    %% NOTE: Opaque is already bound
    {res, #upr_packet{opaque = Opaque} = Packet, Data0} = read_message_loop(Socket, <<>>),

    case Packet of
        #upr_packet{status = ?SUCCESS, body = FailoverLogBin} ->
            FailoverLog = unpack_failover_log(FailoverLogBin),
            ?log_debug("FailoverLog: ~p", [FailoverLog]),
            Parent ! {failover_id, lists:last(FailoverLog), LastSnapshotSeqno, RealStartSeqno, HighSeqno},
            set_sensitive_flag(),
            inet:setopts(Socket, [{active, once}]),
            proc_lib:init_ack({ok, self()}),
            socket_loop(Socket, Callback, Acc, Data0, 0, Parent, 0);
        #upr_packet{status = ?ROLLBACK, body = <<RollbackSeq:64>>} ->
            ?log_debug("handling rollback to ~B", [RollbackSeq]),
            %% in case of xdcr we cannot rewind the destination. So we
            %% just "formally" rollback our start point to resume
            %% streaming at "better than nothing" position
            {had_rollback, false} = {had_rollback, HadRollback},
            do_start(Socket, Vb, FailoverId, FailoverSeqno, RollbackSeq, HighSeqno, Callback, Acc, Parent, true, RollbackSeq)
    end.

stream_vbucket(Bucket, Vb, FailoverId, FailoverSeqno, LastSnapshotSeqno, StartSeqno, Callback, Acc) ->
    true = is_list(Bucket),
    Parent = self(),
    set_sensitive_flag(),
    {ok, Child} =
        proc_lib:start_link(erlang, apply, [fun stream_vbucket_inner/9,
                                            [Bucket, Vb, FailoverId, FailoverSeqno,
                                             LastSnapshotSeqno, StartSeqno, Callback, Acc, Parent]]),

    enter_consumer_loop(Child, Callback, Acc).

stream_vbucket_inner(Bucket, Vb, FailoverId, FailoverSeqno, LastSnapshotSeqno, StartSeqno, Callback, Acc, Parent) ->
    {ok, S} = xdcr_upr_sockets_pool:take_socket(Bucket),
    case start(S, Vb, FailoverId, FailoverSeqno, LastSnapshotSeqno, StartSeqno, Callback, Acc, Parent) of
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
            case Magic =:= ?REQ_MAGIC andalso Opcode =:= ?UPR_NOP of
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
    Packet = #upr_packet{opcode = ?UPR_NOP,
                         opaque = Opaque},
    ok = gen_tcp:send(Socket, encode_res(Packet)).

socket_loop(Socket, Callback, Acc, Data, ScannedPos, Consumer, SentToConsumer) ->
    %% ?log_debug("socket_loop: ~p", [{ScannedPos, SentToConsumer}]),
    Msg = receive
              XMsg ->
                  XMsg
          end,
    %% ?log_debug("Data: ~p, ScannedPos: ~p, Msg: ~p", [Data, ScannedPos, Msg]),
    case Msg of
        ConsumedBytes when is_integer(ConsumedBytes) ->
            %% TODO: send window update msg when ep-engine side is ready
            NewSentToConsumer = SentToConsumer - ConsumedBytes,
            {true, NewSentToConsumer, ConsumedBytes} = {(NewSentToConsumer >= 0), NewSentToConsumer, ConsumedBytes},
            if
                NewSentToConsumer < (?BUFFER_SIZE div 3) andalso SentToConsumer >= (?BUFFER_SIZE div 3) ->
                    %% ?log_debug("Enabled in-flow"),
                    inet:setopts(Socket, [{active, once}]);
                true ->
                    ok
            end,
            socket_loop(Socket, Callback, Acc, Data, ScannedPos, Consumer, NewSentToConsumer);
        {tcp_closed, MustSocket} ->
            {tcp_closed_socket, Socket} = {tcp_closed_socket, MustSocket},
            erlang:error(premature_socket_closure);
        {tcp, MustSocket, NewData0} ->
            {tcp_socket, Socket} = {tcp_socket, MustSocket},
            NewData = <<Data/binary, NewData0/binary>>,
            SplitPos = nops_loop(Socket, NewData, ScannedPos),
            <<ScannedData:SplitPos/binary, UnscannedData/binary>> = NewData,
            Consumer ! ScannedData,
            NewSentToConsumer = SentToConsumer + erlang:size(ScannedData),
            if
                NewSentToConsumer > (2 * ?BUFFER_SIZE div 3) andalso SentToConsumer =< (2 * ?BUFFER_SIZE div 3) ->
                    ?log_debug("Disabled in-flow"),
                    inet:setopts(Socket, [{active, false}]);
                true ->
                    %% timer:sleep(100),
                    inet:setopts(Socket, [{active, once}])
            end,
            socket_loop(Socket, Callback, Acc, UnscannedData, 0, Consumer, NewSentToConsumer);
        done ->
            {<<>>, 0} = {Data, ScannedPos},
            ok;
        stop ->
            stop
    end.

enter_consumer_loop(Child, Callback, Acc) ->
    receive
        {failover_id, _FailoverId, LastSnapshotSeqno, _, _} = Evt ->
            {number, true} = {number, is_integer(LastSnapshotSeqno)},
            {ok, Acc2} = Callback(Evt, Acc),
            consumer_loop(Child, Callback, Acc2, 0, LastSnapshotSeqno, undefined)
    end.

consumer_loop(Child, Callback, Acc, ConsumedSoFar0, LastSnapshotSeqno, LastSeenSeqno) ->
    %% ?log_debug("consumer: ~p", [{ConsumedSoFar0, LastSnapshotSeqno, LastSeenSeqno}]),
    ConsumedSoFar =
        case ConsumedSoFar0 > ?BUFFER_SIZE div 3 of
            true ->
                Child ! ConsumedSoFar0,
                0;
            _ ->
                ConsumedSoFar0
        end,
    receive
        MoreData when is_binary(MoreData) ->
            case consume_stuff(Callback, Acc, MoreData, LastSnapshotSeqno, LastSeenSeqno) of
                {DoneOrStop, RV} when DoneOrStop =:= done orelse DoneOrStop =:= stop ->
                    consumer_loop_exit(Child, DoneOrStop),
                    RV;
                {Acc2, NewLastSnaspshotSeqno, NewLastSeenSeqno} ->
                    ConsumedMore = ConsumedSoFar + erlang:size(MoreData),
                    consumer_loop(Child, Callback, Acc2, ConsumedMore,
                                  NewLastSnaspshotSeqno, NewLastSeenSeqno)
            end;
        %% this is handling please_stop message for xdc_vbucket_rep
        %% changes reader loop efficiently, i.e. without selective
        %% receive
        OtherMsg ->
            case Callback(OtherMsg, Acc) of
                {ok, Acc2} ->
                    consumer_loop(Child, Callback, Acc2, ConsumedSoFar, LastSnapshotSeqno, LastSeenSeqno);
                {stop, RV} ->
                    consumer_loop_exit(Child, stop),
                    RV
            end
    end.

consumer_loop_exit(Child, DoneOrStop) ->
    Child ! DoneOrStop,
    misc:wait_for_process(Child, infinity),
    case DoneOrStop of
        done ->
            receive
                EvenMoreData when is_binary(EvenMoreData) ->
                    erlang:error({unexpected_stuff_after_stream_end, erlang:size(EvenMoreData)})
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

consume_stuff(_Callback, Acc, <<>>, LastSnapshotSeqno, LastSeenSeqno) ->
    {Acc, LastSnapshotSeqno, LastSeenSeqno};
consume_stuff(Callback, Acc, MoreData, LastSnapshotSeqno, LastSeenSeqno) ->
    case decode_packet(MoreData) of
        {Type, Packet, RestData} ->
            case do_callback(Type, Packet, Callback, Acc, LastSnapshotSeqno, LastSeenSeqno) of
                {normal_stop, {MustBeStop, RV}} ->
                    stop = MustBeStop,
                    <<>> = RestData,
                    {done, RV};
                {stop, RV} ->
                    {stop, RV};
                {ok, Acc2, NewLastSnaspshotSeqno, NewLastSeenSeqno} ->
                    consume_stuff(Callback, Acc2, RestData,
                                  NewLastSnaspshotSeqno, NewLastSeenSeqno)
            end
    end.

do_callback(Type, Packet, Callback, Acc, LastSnapshotSeqno, LastSeenSeqno) ->
    %% ?log_debug("Got packet: ~p", [Packet]),
    case Packet of
        #upr_packet{opcode = ?UPR_MUTATION,
                    cas = CAS,
                    ext = Ext,
                    key = Key,
                    body = Body} ->
            <<Seq:64, RevSeqno:64, Flags:32, Expiration:32, _/binary>> = Ext,
            Rev = {RevSeqno, <<CAS:64, Expiration:32, Flags:32>>},
            Doc = #upr_mutation{id = Key,
                                local_seq = Seq,
                                rev = Rev,
                                body = Body,
                                deleted = false,
                                last_snapshot_seq = LastSnapshotSeqno},
            call_callback(Callback, Acc, Doc);
        #upr_packet{opcode = ?UPR_SNAPSHOT_MARKER} ->
            case LastSeenSeqno of
                undefined ->
                    ?log_debug("madness. We're getting snapshot marker without seeing any data. LastSnapshotSeqno = ~B", [LastSnapshotSeqno]),
                    {ok, Acc, LastSnapshotSeqno, LastSeenSeqno};
                _ ->
                    true = is_integer(LastSeenSeqno),
                    {ok, Acc, LastSeenSeqno, LastSeenSeqno}
            end;
        #upr_packet{opcode = ?UPR_DELETION,
                    cas = CAS,
                    ext = Ext,
                    key = Key} ->
            <<Seq:64, RevSeqno:64, _/binary>> = Ext,
            %% NOTE: as of now upr doesn't expose flags of deleted
            %% docs
            Rev = {RevSeqno, <<CAS:64, 0:32, 0:32>>},
            Doc = #upr_mutation{id = Key,
                                local_seq = Seq,
                                rev = Rev,
                                body = <<>>,
                                deleted = true,
                                last_snapshot_seq = LastSnapshotSeqno},
            call_callback(Callback, Acc, Doc);
        #upr_packet{opcode = ?UPR_STREAM_END} ->
            {normal_stop, Callback({stream_end, LastSnapshotSeqno, LastSeenSeqno}, Acc)};
        #upr_packet{opcode = OtherCode} ->
            case OtherCode of
                ?UPR_NOP ->
                    ok;
                ?UPR_WINDOW_UPDATE ->
                    {window, res} = {window, Type},
                    ok;
                ?UPR_FLOW_CONTROL_SETUP ->
                    {setup, res} = {setup, Type},
                    ok
            end,
            {ok, Acc, LastSnapshotSeqno, LastSeenSeqno}
    end.

call_callback(Callback, Acc, #upr_mutation{local_seq = Seq, last_snapshot_seq = LastSnapshotSeqno} = Doc) ->
    %% that's for debugging
    erlang:put(last_doc, Doc),
    %% ?log_debug("mutation: ~p", [Doc]),
    case Callback(Doc, Acc) of
        {ok, Acc2} ->
            {ok, Acc2, LastSnapshotSeqno, Seq};
        {stop, Acc2} ->
            {stop, Acc2}
    end.

stream_loop(Socket, Callback, Acc, Data0) ->
    {_, Packet, Data1} = read_message_loop(Socket, Data0),
    case Callback(Packet, Acc) of
        {ok, Acc2} ->
            stream_loop(Socket, Callback, Acc2, Data1);
        {stop, RV} ->
            RV
    end.

stats_loop(S, Cb, InitAcc, Data) ->
    Cb2 = fun (Packet, Acc) ->
                  #upr_packet{status = ?SUCCESS,
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
                      encode_req(#upr_packet{opcode = ?UPR_GET_FAILOVER_LOG,
                                             vbucket = VB})),

    {res, Packet, <<>>} = read_message_loop(Socket, <<>>),
    case Packet#upr_packet.status of
        ?SUCCESS ->
            unpack_failover_log(Packet#upr_packet.body);
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
                     {failover_id, _FID, _, _, _} ->
                         {ok, Acc};
                     {stream_end, _, _} = Msg ->
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
