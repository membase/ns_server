-module (mc_connection).

-export([loop/2]).

-include("mc_constants.hrl").

bin_size(undefined) -> 0;
bin_size(List) when is_list(List) -> bin_size(list_to_binary(List));
bin_size(Binary) -> size(Binary).

xmit(_Socket, undefined) -> ok;
xmit(Socket, List) when is_list(List) -> xmit(Socket, list_to_binary(List));
xmit(Socket, Data) -> gen_tcp:send(Socket, Data).

respond(Socket, OpCode, Opaque, Res) ->
    KeyLen = bin_size(Res#mc_response.key),
    ExtraLen = bin_size(Res#mc_response.extra),
    BodyLen = bin_size(Res#mc_response.body) + (KeyLen + ExtraLen),
    Status = Res#mc_response.status,
    CAS = Res#mc_response.cas,
    gen_tcp:send(Socket, <<?RES_MAGIC, OpCode:8, KeyLen:16,
                          ExtraLen:8, 0:8, Status:16,
                          BodyLen:32, Opaque:32, CAS:64>>),
    ok = xmit(Socket, Res#mc_response.extra),
    ok = xmit(Socket, Res#mc_response.key),
    ok = xmit(Socket, Res#mc_response.body).

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
    Res = gen_server:call(StorageServer, {OpCode, Extra, Key, Body, CAS}),

    respond(Socket, OpCode, Opaque, Res).

loop(Socket, Handler) ->
    process_message(Socket, Handler, gen_tcp:recv(Socket, ?HEADER_LEN)),
    loop(Socket, Handler).
