-module(mc_client_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-import(mc_binary, [send/2, send/4, send_recv/5, recv/2]).

-compile(export_all).

%% A memcached client that speaks binary protocol.

cmd(Opcode, Sock, RecvCallback, Entry) ->
    case is_quiet(Opcode) of
        true  -> cmd_binary_quiet(Opcode, Sock, RecvCallback, Entry);
        false -> cmd_binary_vocal(Opcode, Sock, RecvCallback, Entry)
    end.

cmd_binary_quiet(Opcode, Sock, _RecvCallback, Entry) ->
    ok = send(Sock, req, #mc_header{opcode = Opcode},
              Entry#mc_entry{ext = ext(Opcode, Entry)}).

cmd_binary_vocal(Opcode, Sock, RecvCallback, Entry) ->
    ok = send(Sock, req, #mc_header{opcode = Opcode},
              Entry#mc_entry{ext = ext(Opcode, Entry)}),
    cmd_binary_vocal_recv(Opcode, Sock, RecvCallback).

cmd_binary_vocal_recv(Opcode, Sock, RecvCallback) ->
    {ok, RecvHeader, RecvEntry} = recv(Sock, res),
    case is_function(RecvCallback) of
       true  -> RecvCallback(RecvHeader, RecvEntry);
       false -> ok
    end,
    case Opcode =:= RecvHeader#mc_header.opcode of
        true  -> S = RecvHeader#mc_header.statusOrReserved,
                 case S =:= ?SUCCESS of
                     true  -> {ok, RecvHeader, RecvEntry};
                     false -> {error, RecvHeader, RecvEntry}
                 end;
        false -> cmd_binary_vocal_recv(Opcode, Sock, RecvCallback)
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

ext(?SET,        Entry) -> ext_flag_expire(Entry);
ext(?SETQ,       Entry) -> ext_flag_expire(Entry);
ext(?ADD,        Entry) -> ext_flag_expire(Entry);
ext(?ADDQ,       Entry) -> ext_flag_expire(Entry);
ext(?REPLACE,    Entry) -> ext_flag_expire(Entry);
ext(?REPLACEQ,   Entry) -> ext_flag_expire(Entry);
ext(?INCREMENT,  Entry) -> ext_arith(Entry);
ext(?INCREMENTQ, Entry) -> ext_arith(Entry);
ext(?DECREMENT,  Entry) -> ext_arith(Entry);
ext(?DECREMENTQ, Entry) -> ext_arith(Entry);
ext(_, _) -> undefined.

ext_flag_expire(#mc_entry{flag = Flag, expire = Expire}) ->
    <<Flag:32, Expire:32>>.

ext_arith(#mc_entry{data = Data, expire = Expire}) ->
    <<Data:64, 0:64, Expire:32>>.

% -------------------------------------------------

noop_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, _H, _E} = cmd(?NOOP, Sock, undefined, #mc_entry{}),
    ok = gen_tcp:close(Sock).

flush_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    ok = gen_tcp:close(Sock).

flush_test_sock(Sock) ->
    {ok, _H, _E} = cmd(?FLUSH, Sock, undefined, #mc_entry{}).

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    ok = gen_tcp:close(Sock).

set_test_sock(Sock, Key) ->
    flush_test_sock(Sock),
    (fun () ->
        {ok, _H, _E} = cmd(?SET, Sock, undefined,
                           #mc_entry{key = Key, data = <<"AAA">>}),
        get_test_match(Sock, Key, <<"AAA">>)
    end)().

get_test_match(Sock, Key, Data) ->
    D = ets:new(test, [set]),
    ets:insert(D, {nvals, 0}),
    {ok, _H, E} = cmd(?GETK, Sock,
                      fun (_H, E) ->
                              ets:update_counter(D, nvals, 1),
                              ?assertMatch(Key, E#mc_entry.key),
                              ?assertMatch(Data, E#mc_entry.data)
                      end,
                      #mc_entry{key = Key}),
    ?assertMatch(Key, E#mc_entry.key),
    ?assertMatch(Data, E#mc_entry.data),
    ?assertMatch([{nvals, 1}], ets:lookup(D, nvals)).

