-module(mc_client_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_client.hrl").

-compile(export_all).

% cmd(version, Sock, RecvCallback, Entry) ->
%     send_recv(Sock, RecvCallback, #mc_header{opcode = ?VERSION}, Entry, <<"OK">>);

cmd(get, Sock, RecvCallback, #mc_entry{keys = Keys}) ->
    ok = send(Sock,
              lists:map(fun (K) -> encode(req,
                                          #mc_header{opcode = ?GETKQ},
                                          #mc_entry{key = K})
                        end,
                        Keys)),
    ok = send(Sock, req, #mc_header{opcode = ?NOOP}, #mc_entry{}),
    get_recv(Sock, RecvCallback);

cmd(set, Sock, RecvCallback, Entry) ->
    cmd_update(Sock, RecvCallback, Entry, ?SET);
cmd(add, Sock, RecvCallback, Entry) ->
    cmd_update(Sock, RecvCallback, Entry, ?ADD);
cmd(replace, Sock, RecvCallback, Entry) ->
    cmd_update(Sock, RecvCallback, Entry, ?REPLACE);

% cmd(append, Sock, RecvCallback, Entry) ->
%     cmd_update(Sock, RecvCallback, Entry, ?APPEND);
% cmd(prepend, Sock, RecvCallback, Entry) ->
%     cmd_update(Sock, RecvCallback, Entry, ?PREPEND);

% cmd(incr, Sock, RecvCallback, Entry) ->
%     send_recv(Sock, RecvCallback, Entry, ?INCREMENT, <<"OK">>);
% cmd(decr, Sock, RecvCallback, Entry) ->
%     send_recv(Sock, RecvCallback, Entry, ?DECREMENT, <<"OK">>);

cmd(delete, Sock, RecvCallback, Entry) ->
    send_recv(Sock, RecvCallback, #mc_header{opcode = ?DELETE}, Entry,
              <<"DELETED">>);

cmd(flush_all, Sock, RecvCallback, Entry) ->
    send_recv(Sock, RecvCallback, #mc_header{opcode = ?FLUSH}, Entry, <<"OK">>);

cmd(Opcode, Sock, RecvCallback, Entry) ->
    % Dispatch to cmd_binary() in case the caller was
    % using a binary protocol opcode.
    cmd_binary(Opcode, Sock, RecvCallback, Entry).

% -------------------------------------------------

cmd_update(Sock, RecvCallback,
           #mc_entry{flag = Flag, expire = Expire} = Entry, Opcode) ->
    Ext = <<Flag:32, Expire:32>>,
    send_recv(Sock, RecvCallback,
              #mc_header{opcode = Opcode}, Entry#mc_entry{ext = Ext},
              <<"STORED">>).

get_recv(Sock, RecvCallback) ->
    case recv(Sock, res) of
        {error, _} = Err -> Err;
        {ok, #mc_header{opcode = ?NOOP}, _Entry} ->
            {ok, <<"END">>};
        {ok, #mc_header{opcode = ?GETKQ} = Header, Entry} ->
            case is_function(RecvCallback) of
               true  -> RecvCallback(Header, Entry);
               false -> ok
            end,
            get_recv(Sock, RecvCallback)
    end.

send_recv(Sock, RecvCallback, Header, Entry, Success) ->
    {ok, RecvHeader, _RecvEntry} = send_recv(Sock, RecvCallback, Header, Entry),
    V1 = RecvHeader#mc_header.opcode,
    V1 = Header#mc_header.opcode,
    V2 = RecvHeader#mc_header.statusOrReserved,
    V2 = ?SUCCESS,
    {ok, Success}.

send_recv(Sock, RecvCallback, Header, Entry) ->
    ok = send(Sock, req, Header, Entry),
    {ok, RecvHeader, RecvEntry} = recv(Sock, res),
    case is_function(RecvCallback) of
       true  -> RecvCallback(RecvHeader, RecvEntry);
       false -> ok
    end,
    {ok, RecvHeader, RecvEntry}.

send(Sock, Kind, Header, Entry) ->
    send(Sock, encode(Kind, Header, Entry)).

recv(Sock, HeaderKind) ->
    {ok, HeaderBin} = recv_data(Sock, ?HEADER_LEN),
    {Header, Entry} = decode_header(HeaderKind, HeaderBin),
    recv_body(Sock, Header, Entry).

recv_body(Sock, #mc_header{extlen = ExtLen,
                           keylen = KeyLen,
                           bodylen = BodyLen} = Header, Entry)
    when BodyLen >= (ExtLen + KeyLen) ->
    {ok, Ext} = recv_data(Sock, ExtLen),
    {ok, Key} = recv_data(Sock, KeyLen),
    {ok, Data} = recv_data(Sock, BodyLen - (ExtLen + KeyLen)),
    {ok, Header, Entry#mc_entry{ext = Ext, key = Key, data = Data}}.

encode(req, Header, Entry) ->
    encode(?REQ_MAGIC, Header, Entry);
encode(res, Header, Entry) ->
    encode(?RES_MAGIC, Header, Entry);
encode(Magic,
       #mc_header{opcode = Opcode, opaque = Opaque,
                  statusOrReserved = StatusOrReserved},
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
    {#mc_header{opcode = Opcode, statusOrReserved = Reserved, opaque = Opaque,
                keylen = KeyLen, extlen = ExtLen, bodylen = BodyLen},
     #mc_entry{datatype = DataType, cas = CAS}};

decode_header(res, <<?RES_MAGIC:8, Opcode:8, KeyLen:16, ExtLen:8,
                     DataType:8, Status:16, BodyLen:32,
                     Opaque:32, CAS:64>>) ->
    {#mc_header{opcode = Opcode, statusOrReserved = Status, opaque = Opaque,
                keylen = KeyLen, extlen = ExtLen, bodylen = BodyLen},
     #mc_entry{datatype = DataType, cas = CAS}}.

bin(undefined) -> <<>>;
bin(X)         -> <<X/binary>>.

bin_size(undefined) -> 0;
bin_size(List) when is_list(List) -> bin_size(iolist_to_binary(List));
bin_size(Binary) -> size(Binary).

send(_Sock, undefined) -> ok;
send(_Sock, <<>>) -> ok;
send(Sock, List) when is_list(List) -> send(Sock, iolist_to_binary(List));
send(Sock, Data) -> gen_tcp:send(Sock, Data).

%% @doc Receive binary data of specified number of bytes length.
recv_data(_, 0)           -> {ok, <<>>};
recv_data(Sock, NumBytes) -> gen_tcp:recv(Sock, NumBytes).

% -------------------------------------------------

%% For binary upstream talking to binary downstream server.

cmd_binary(Opcode, Sock, RecvCallback, Entry) ->
    case is_quiet(Opcode) of
        true  -> cmd_binary_quiet(Opcode, Sock, RecvCallback, Entry);
        false -> cmd_binary_vocal(Opcode, Sock, RecvCallback, Entry)
    end.

cmd_binary_quiet(Opcode, Sock, _RecvCallback, Entry) ->
    send(Sock, req, #mc_header{opcode = Opcode}, Entry).

cmd_binary_vocal(Opcode, Sock, RecvCallback, Entry) ->
    send(Sock, req, #mc_header{opcode = Opcode}, Entry),
    cmd_binary_vocal_recv(Opcode, Sock, RecvCallback, Entry).

cmd_binary_vocal_recv(Opcode, Sock, RecvCallback, Entry) ->
    {ok, RecvHeader, RecvEntry} = recv(Sock, res),
    case is_function(RecvCallback) of
       true  -> RecvCallback(RecvHeader, RecvEntry);
       false -> ok
    end,
    case Opcode =:= RecvHeader#mc_header.opcode of
        true  -> S = RecvHeader#mc_header.statusOrReserved,
                 S = ?SUCCESS,
                 {ok, RecvHeader, RecvEntry};
        false -> cmd_binary_vocal_recv(Opcode, Sock, RecvCallback, Entry)
    end.

% -------------------------------------------------

is_quiet(?GETQ) -> true;
is_quiet(?GETKQ) -> true;
is_quiet(?SETQ) -> true;
is_quiet(?ADDQ) -> true;
is_quiet(?REPLACEQ) -> true;
is_quiet(?DELETEQ) -> true;
is_quiet(?INCREMENTQ) -> true;
is_quiet(?DECREMENTQ) -> true;
is_quiet(?QUITQ) -> true;
is_quiet(?FLUSHQ) -> true;
is_quiet(?APPENDQ) -> true;
is_quiet(?PREPENDQ) -> true;
is_quiet(?RSETQ) -> true;
is_quiet(?RAPPENDQ) -> true;
is_quiet(?RPREPENDQ) -> true;
is_quiet(?RDELETEQ) -> true;
is_quiet(?RINCRQ) -> true;
is_quiet(?RDECRQ) -> true;
is_quiet(_) -> false.

% -------------------------------------------------

send_recv_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    (fun () ->
        {ok, works} = send_recv(Sock, nil,
                                #mc_header{opcode = ?NOOP}, #mc_entry{},
                                works)
    end)(),
    test_flush(Sock),
    ok = gen_tcp:close(Sock).

test_flush(Sock) ->
    {ok, works} = send_recv(Sock, nil,
                            #mc_header{opcode = ?FLUSH}, #mc_entry{}, works).

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    ok = gen_tcp:close(Sock).

set_test_sock(Sock, Key) ->
    test_flush(Sock),
    (fun () ->
        {ok, RB} = cmd(set, Sock, nil,
                       #mc_entry{key = Key, data = <<"AAA">>}),
        ?assertMatch(RB, <<"STORED">>),
        get_test_match(Sock, Key, <<"AAA">>)
    end)().

get_test_match(Sock, Key, Data) ->
    D = ets:new(test, [set]),
    ets:insert(D, {nvals, 0}),
    {ok, RB} = cmd(get, Sock,
                   fun (_H, E) ->
                       ets:update_counter(D, nvals, 1),
                       ?assertMatch(Key, E#mc_entry.key),
                       ?assertMatch(Data, E#mc_entry.data)
                   end,
                   #mc_entry{keys = [Key]}),
    ?assertMatch(RB, <<"END">>),
    ?assertMatch([{nvals, 1}], ets:lookup(D, nvals)).

get_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    (fun () ->
        D = ets:new(test, [set]),
        ets:insert(D, {nvals, 0}),
        {ok, RB} = cmd(get, Sock,
                       fun (_H, _E) -> ?assert(false) % Should not get here.
                       end,
                       #mc_entry{keys = [<<"ccc">>, <<"bbb">>]}),
        ?assertMatch(RB, <<"END">>),
        ?assertMatch([{nvals, 0}], ets:lookup(D, nvals))
    end)(),
    (fun () ->
        D = ets:new(test, [set]),
        ets:insert(D, {nvals, 0}),
        {ok, RB} = cmd(get, Sock,
                       fun (_H, E) ->
                           ets:update_counter(D, nvals, 1),
                           ?assertMatch(<<"aaa">>, E#mc_entry.key),
                           ?assertMatch(<<"AAA">>, E#mc_entry.data)
                       end,
                       #mc_entry{keys = [<<"aaa">>, <<"bbb">>]}),
        ?assertMatch(RB, <<"END">>),
        ?assertMatch([{nvals, 1}], ets:lookup(D, nvals))
    end)(),
    (fun () ->
        D = ets:new(test, [set]),
        ets:insert(D, {nvals, 0}),
        {ok, RB} = cmd(get, Sock,
                       fun (_H, E) ->
                           ets:update_counter(D, nvals, 1),
                           ?assertMatch(<<"aaa">>, E#mc_entry.key),
                           ?assertMatch(<<"AAA">>, E#mc_entry.data)
                       end,
                       #mc_entry{keys = [<<"aaa">>, <<"aaa">>, <<"bbb">>]}),
        ?assertMatch(RB, <<"END">>),
        ?assertMatch([{nvals, 2}], ets:lookup(D, nvals))
    end)(),
    ok = gen_tcp:close(Sock).

delete_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    get_test_match(Sock, <<"aaa">>, <<"AAA">>),
    (fun () ->
        D = ets:new(test, [set]),
        ets:insert(D, {nvals, 0}),
        {ok, RB} = cmd(delete, Sock,
                       fun (H, _E) ->
                           ets:update_counter(D, nvals, 1),
                           ?assertMatch(?DELETE, H#mc_header.opcode)
                       end,
                       #mc_entry{key = <<"aaa">>}),
        ?assertMatch(RB, <<"DELETED">>),
        ?assertMatch([{nvals, 1}], ets:lookup(D, nvals))
    end)(),
    (fun () ->
        {ok, RB} = cmd(get, Sock,
                       fun (_H, _E) -> ?assert(false) % Should not get here.
                       end,
                       #mc_entry{keys = [<<"aaa">>, <<"bbb">>]}),
        ?assertMatch(RB, <<"END">>)
    end)(),
    ok = gen_tcp:close(Sock).


