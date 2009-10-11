-module (mc_connection).

-export([loop/1]).

-define(HEADER_LEN, 24).
-define(REQ_MAGIC, 16#80).
-define(RES_MAGIC, 16#81).

-define(GET,   0).
-define(FLUSH, 16#8).

respond(Socket, OpCode, Extra, Key, Status, Body, Opaque, CAS) ->
    KeyLen = size(Key),
    ExtraLen = size(Extra),
    BodyLen = size(Body),
    gen_tcp:send(Socket, <<?RES_MAGIC, OpCode:8, KeyLen:16,
                          ExtraLen:8, 0:8, Status:16,
                          BodyLen:32, Opaque:32, CAS:64>>),
    gen_tcp:send(Socket, Extra),
    gen_tcp:send(Socket, Key),
    gen_tcp:send(Socket, Body).

process(?FLUSH, <<Delay:32>>, <<>>, <<>>, _CAS) ->
    error_logger:info_msg("Got flush command.~n", []),
    {0, <<>>, <<>>, <<>>, 0};
process(?GET, <<>>, Key, <<>>, _Cas) ->
    error_logger:info_msg("Got GET command for ~p.~n", [Key]),
    {1, <<>>, <<>>, <<"Does not exist">>, 0}.

read_data(_Socket, 0, _ForWhat) -> <<>>;
read_data(Socket, N, ForWhat) ->
    error_logger:info_msg("Reading ~p bytes of ~p~n", [N, ForWhat]),
    {ok, Data} = gen_tcp:recv(Socket, N),
    Data.

process_header(Socket, {ok, <<?REQ_MAGIC:8, OpCode:8, KeyLen:16,
                             ExtraLen:8, 0:8, 0:16,
                             BodyLen:32,
                             Opaque:32,
                             CAS:64>>}) ->
    error_logger:info_msg("Got message of type ~p.~n", [OpCode]),

    Extra = read_data(Socket, ExtraLen, extra),
    Key = read_data(Socket, KeyLen, key),
    Body = read_data(Socket, BodyLen - (KeyLen + ExtraLen), body),

    {Status, NewExtra, NewKey, NewBody, NewCAS} = process(OpCode, Extra,
                                                          Key, Body, CAS),
    respond(Socket, OpCode, NewExtra, NewKey, Status, NewBody, Opaque, NewCAS);
process_header(Socket, Data) ->
    error_logger:info_msg("Got Unhandleable message:  ~p~n", [Data]),
    gen_tcp:close(Socket),
    exit(done).

loop(Socket) ->
    process_header(Socket, gen_tcp:recv(Socket, ?HEADER_LEN)),
    loop(Socket).
