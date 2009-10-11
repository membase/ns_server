-module (mc_connection).

-export([loop/2]).

-include("mc_constants.hrl").

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

% Read-data special cases a 0 size to just return an empty binary.
read_data(_Socket, 0, _ForWhat) -> <<>>;
read_data(Socket, N, ForWhat) ->
    error_logger:info_msg("Reading ~p bytes of ~p~n", [N, ForWhat]),
    {ok, Data} = gen_tcp:recv(Socket, N),
    Data.

process_message(Socket, StorageServer, {ok, <<?REQ_MAGIC:8, OpCode:8, KeyLen:16,
                                            ExtraLen:8, 0:8, 0:16,
                                            BodyLen:32,
                                            Opaque:32,
                                            CAS:64>>}) ->
    error_logger:info_msg("Got message of type ~p to give to ~p.~n",
                          [OpCode, StorageServer]),

    Extra = read_data(Socket, ExtraLen, extra),
    Key = read_data(Socket, KeyLen, key),
    Body = read_data(Socket, BodyLen - (KeyLen + ExtraLen), body),

    % Hand the request off to the server.
    {Status, NewExtra, NewKey, NewBody,
     NewCAS} = gen_server:call(StorageServer, {OpCode, Extra, Key, Body, CAS}),

    respond(Socket, OpCode, NewExtra, NewKey, Status, NewBody, Opaque, NewCAS);
process_message(Socket, _Handler, Data) ->
    error_logger:info_msg("Got Unhandleable message:  ~p~n", [Data]),
    gen_tcp:close(Socket),
    exit(done).

loop(Socket, Handler) ->
    process_message(Socket, Handler, gen_tcp:recv(Socket, ?HEADER_LEN)),
    loop(Socket, Handler).
