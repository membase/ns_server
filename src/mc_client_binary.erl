-module(mc_client_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_client.hrl").

-compile(export_all).

% cmd(version, Sock, RecvCallback, Entry) ->
%     send_recv(Sock, RecvCallback, #mc_header{opcode = ?VERSION}, Entry);

cmd(get, Sock, RecvCallback, #mc_entry{keys = Keys}) ->
    ok = send(Sock,
              lists:map(fun (K) ->
                            encode(req, #mc_header{opcode = ?GETKQ},
                                        #mc_entry{key = K})
                        end,
                        Keys)),
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
%     send_recv(Sock, RecvCallback, Entry, ?INCREMENT);
% cmd(decr, Sock, RecvCallback, Entry) ->
%     send_recv(Sock, RecvCallback, Entry, ?DECREMENT);

cmd(delete, Sock, RecvCallback, Entry) ->
    send_recv(Sock, RecvCallback, #mc_header{opcode = ?DELETE}, Entry);

cmd(flush_all, Sock, RecvCallback, Entry) ->
    send_recv(Sock, RecvCallback, #mc_header{opcode = ?FLUSH}, Entry);

cmd(Opcode, Sock, RecvCallback, Entry) ->
    % Dispatch to cmd_binary() in case the caller was
    % using a binary protocol opcode.
    cmd_binary(Opcode, Sock, RecvCallback, Entry).

% -------------------------------------------------

cmd_update(Sock, RecvCallback,
           #mc_entry{flag = Flag, expire = Expire} = Entry, Opcode) ->
    Ext = <<Flag:32, Expire:32>>,
    send_recv(Sock, RecvCallback,
              #mc_header{opcode = Opcode}, Entry#mc_entry{ext = Ext}).

get_recv(Sock, RecvCallback) ->
    case recv(Sock, res) of
        {error, _} = Err -> Err;
        {ok, _Entry, #mc_header{opcode = ?NOOP}} ->
            {ok, <<"END">>};
        {ok, Entry, #mc_header{opcode = ?GETKQ} = Header} ->
            if is_function(RecvCallback) -> RecvCallback(Header, Entry);
               true -> ok
            end,
            get_recv(Sock, RecvCallback)
    end.

send_recv(Sock, RecvCallback, Header, Entry) ->
    ok = send(Sock, req, Header, Entry),
    {ok, RecvHeader, RecvEntry} = recv(Sock, res),
    if is_function(RecvCallback) -> RecvCallback(RecvHeader, RecvEntry);
       true -> ok
    end,
    {ok, RecvHeader, RecvEntry}.

send(Sock, Kind, Header, Entry) ->
    send(Sock, encode(Kind, Header, Entry)).

recv(Sock, HeaderKind) ->
    {ok, HeaderBin} = recv_data(Sock, ?HEADER_LEN),
    {Header, Entry} = decode_header(HeaderKind, HeaderBin),
    recv_body(Sock, Header, Entry).

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

recv_body(Sock, #mc_header{extlen = ExtLen,
                           keylen = KeyLen,
                           bodylen = BodyLen} = Header, Entry)
    when BodyLen >= (ExtLen + KeyLen) ->
    {ok, Ext} = recv_data(Sock, ExtLen),
    {ok, Key} = recv_data(Sock, KeyLen),
    {ok, Data} = recv_data(Sock, BodyLen - (ExtLen + KeyLen)),
    {ok, Header, Entry#mc_entry{ext = Ext, key = Key, data = Data}}.

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

cmd_binary(?GET, _Sock, _RecvCallback, _Entry) ->
    exit(todo);

cmd_binary(?SET, Sock, RecvCallback, Entry) ->
    cmd(set, Sock, RecvCallback, Entry);

cmd_binary(?ADD, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?REPLACE, _Sock, _RecvCallback, _Entry) ->
    exit(todo);

cmd_binary(?DELETE, Sock, RecvCallback, Entry) ->
    cmd(delete, Sock, RecvCallback, Entry);

cmd_binary(?INCREMENT, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?DECREMENT, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?QUIT, _Sock, _RecvCallback, _Entry) ->
    exit(todo);

cmd_binary(?FLUSH, Sock, RecvCallback, Entry) ->
    cmd(flush_all, Sock, RecvCallback, Entry);

cmd_binary(?GETQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);

cmd_binary(?NOOP, _Sock, RecvCallback, _Entry) ->
    % Assuming NOOP used to uncork GETKQ's.
    if is_function(RecvCallback) -> RecvCallback({ok, <<"END">>},
                                                 #mc_entry{});
       true -> ok
    end;

cmd_binary(?VERSION, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?GETK, _Sock, _RecvCallback, _Entry) ->
    exit(todo);

cmd_binary(?GETKQ, Sock, RecvCallback, #mc_entry{keys = Keys}) ->
    cmd(get, Sock, RecvCallback, #mc_entry{keys = Keys});

cmd_binary(?APPEND, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?PREPEND, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?STAT, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?SETQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?ADDQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?REPLACEQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?DELETEQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?INCREMENTQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?DECREMENTQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?QUITQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?FLUSHQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?APPENDQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?PREPENDQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RGET, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RSET, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RSETQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RAPPEND, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RAPPENDQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RPREPEND, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RPREPENDQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RDELETE, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RDELETEQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RINCR, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RINCRQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RDECR, _Sock, _RecvCallback, _Entry) ->
    exit(todo);
cmd_binary(?RDECRQ, _Sock, _RecvCallback, _Entry) ->
    exit(todo);

cmd_binary(Cmd, _Sock, _RecvCallback, _Entry) ->
    exit({unimplemented, Cmd}).

% -------------------------------------------------

send_recv_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    (fun () ->
        {ok, H, _E} = send_recv(Sock, nil,
                                #mc_header{opcode = ?NOOP}, #mc_entry{}),
        ?assertMatch(#mc_header{opcode = ?NOOP}, H)
    end)(),

    ok = gen_tcp:close(Sock).
