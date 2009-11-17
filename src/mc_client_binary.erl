-module(mc_client_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_client.hrl").

-import(mc_binary, [send/2, send/4, send_recv/5, recv/2, encode/3]).

-compile(export_all).

%% A memcached client that speaks binary protocol.

cmd(Opcode, Sock, RecvCallback, Entry) ->
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

