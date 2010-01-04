-module(mc_client_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-import(mc_binary, [send/2, send/4, send_recv/5, recv/2]).

-compile(export_all).

%% A memcached client that speaks binary protocol.

cmd(send_list, Sock, RecvCallback, HEList) ->
    send_list(Sock, RecvCallback, HEList, undefined);

cmd(Opcode, Sock, RecvCallback, HE) ->
    case is_quiet(Opcode) of
        true  -> cmd_binary_quiet(Opcode, Sock, RecvCallback, HE);
        false -> cmd_binary_vocal(Opcode, Sock, RecvCallback, HE)
    end.

cmd_binary_quiet(Opcode, Sock, _RecvCallback, {Header, Entry}) ->
    ok = send(Sock, req,
              Header#mc_header{opcode = Opcode}, ext(Opcode, Entry)),
    {ok, quiet}.

cmd_binary_vocal(?STAT = Opcode, Sock, RecvCallback, {Header, Entry}) ->
    ok = send(Sock, req, Header#mc_header{opcode = Opcode}, Entry),
    stats_recv(Sock, RecvCallback);

cmd_binary_vocal(Opcode, Sock, RecvCallback, {Header, Entry}) ->
    ok = send(Sock, req,
              Header#mc_header{opcode = Opcode}, ext(Opcode, Entry)),
    cmd_binary_vocal_recv(Opcode, Sock, RecvCallback).

cmd_binary_vocal_recv(Opcode, Sock, RecvCallback) ->
    {ok, RecvHeader, RecvEntry} = recv(Sock, res),
    case is_function(RecvCallback) of
       true  -> RecvCallback(RecvHeader, RecvEntry);
       false -> ok
    end,
    case Opcode =:= RecvHeader#mc_header.opcode of
        true  -> {ok, RecvHeader, RecvEntry};
        false -> cmd_binary_vocal_recv(Opcode, Sock, RecvCallback)
    end.

% -------------------------------------------------

stats_recv(Sock, RecvCallback) ->
    {ok, #mc_header{opcode = ROpcode,
                    keylen = RKeyLen} = RecvHeader,
         RecvEntry} = recv(Sock, res),
    case ?STAT =:= ROpcode andalso 0 =:= RKeyLen of
        true  -> {ok, RecvHeader, RecvEntry};
        false -> case is_function(RecvCallback) of
                     true  -> RecvCallback(RecvHeader, RecvEntry);
                     false -> ok
                 end,
                 stats_recv(Sock, RecvCallback)
    end.

% -------------------------------------------------

send_list(_Sock, _RecvCallback, [], LastResult) -> LastResult;
send_list(Sock, RecvCallback,
          [{#mc_header{opcode = Opcode}, _E} = HE | HERest],
          _LastResult) ->
    LastResult = cmd(Opcode, Sock, RecvCallback, HE),
    send_list(Sock, RecvCallback, HERest, LastResult).

% -------------------------------------------------

auth(_Sock, undefined) -> ok;

auth(Sock, {"PLAIN", {AuthName, AuthPswd}}) ->
    auth(Sock, {"PLAIN", {<<>>, AuthName, AuthPswd}});

auth(Sock, {"PLAIN", {ForName, AuthName, AuthPswd}}) ->
    BinForName  = mc_binary:bin(ForName),
    BinAuthName = mc_binary:bin(AuthName),
    BinAuthPswd = mc_binary:bin(AuthPswd),
    case mc_client_binary:cmd(?CMD_SASL_AUTH, Sock, undefined,
                              {#mc_header{},
                               #mc_entry{key = "PLAIN",
                                         data = <<BinForName/binary, 0:8,
                                                  BinAuthName/binary, 0:8,
                                                  BinAuthPswd/binary>>
                                        }}) of

        {ok, H, _E} -> case H#mc_header.status == ?SUCCESS of
                           true -> ok;
                           false -> {error, eauth_status, H#mc_header.status}
                       end;
        _Error      -> {error, eauth_cmd}
    end;

auth(_Sock, _UnknownMech) -> {error, emech_unsupported}.

% -------------------------------------------------

is_quiet(?GETQ)       -> true;
is_quiet(?GETKQ)      -> true;
is_quiet(?SETQ)       -> true;
is_quiet(?ADDQ)       -> true;
is_quiet(?REPLACEQ)   -> true;
is_quiet(?DELETEQ)    -> true;
is_quiet(?INCREMENTQ) -> true;
is_quiet(?DECREMENTQ) -> true;
is_quiet(?QUITQ)      -> true;
is_quiet(?FLUSHQ)     -> true;
is_quiet(?APPENDQ)    -> true;
is_quiet(?PREPENDQ)   -> true;
is_quiet(?RSETQ)      -> true;
is_quiet(?RAPPENDQ)   -> true;
is_quiet(?RPREPENDQ)  -> true;
is_quiet(?RDELETEQ)   -> true;
is_quiet(?RINCRQ)     -> true;
is_quiet(?RDECRQ)     -> true;
is_quiet(_)           -> false.

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
ext(_, Entry) -> Entry.

ext_flag_expire(#mc_entry{ext = Ext, flag = Flag, expire = Expire} = Entry) ->
    case Ext of
        undefined -> Entry#mc_entry{ext = <<Flag:32, Expire:32>>};
        _         -> Entry
    end.

ext_arith(#mc_entry{ext = Ext, data = Data, expire = Expire} = Entry) ->
    case Ext of
        undefined ->
            Ext2 = case Data of
                       <<>>      -> <<1:64, 0:64, Expire:32>>;
                       undefined -> <<1:64, 0:64, Expire:32>>;
                       _         -> <<Data:64, 0:64, Expire:32>>
                   end,
            Entry#mc_entry{ext = Ext2, data = undefined};
        _ -> Entry
    end.

% -------------------------------------------------

blank_he() ->
    {#mc_header{}, #mc_entry{}}.

noop_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, _H, _E} = cmd(?NOOP, Sock, undefined, blank_he()),
    ok = gen_tcp:close(Sock).

flush_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    ok = gen_tcp:close(Sock).

flush_test_sock(Sock) ->
    {ok, _H, _E} = cmd(?FLUSH, Sock, undefined, blank_he()).

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    ok = gen_tcp:close(Sock).

set_test_sock(Sock, Key) ->
    flush_test_sock(Sock),
    (fun () ->
        {ok, _H, _E} = cmd(?SET, Sock, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = <<"AAA">>}}),
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
                      {#mc_header{}, #mc_entry{key = Key}}),
    ?assertMatch(Key, E#mc_entry.key),
    ?assertMatch(Data, E#mc_entry.data),
    ?assertMatch([{nvals, 1}], ets:lookup(D, nvals)).

get_miss_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    {ok, H, _E} = cmd(?GET, Sock,
                       fun (_H, _E) -> ok
                       end,
                       {#mc_header{}, #mc_entry{key = <<"not_a_key">>}}),
    ?assert(H#mc_header.status =/= ?SUCCESS),
    ok = gen_tcp:close(Sock).

getk_miss_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    {ok, H, _E} = cmd(?GETK, Sock,
                       fun (_H, _E) -> ok
                       end,
                       {#mc_header{}, #mc_entry{key = <<"not_a_key">>}}),
    ?assert(H#mc_header.status =/= ?SUCCESS),
    ok = gen_tcp:close(Sock).

arith_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    Key = <<"a">>,
    (fun () ->
        {ok, _H, _E} = cmd(?SET, Sock, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = <<"1">>}}),
        get_test_match(Sock, Key, <<"1">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E} = cmd(?INCREMENT, Sock, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 1}}),
        get_test_match(Sock, Key, <<"2">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E} = cmd(?INCREMENT, Sock, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 1}}),
        get_test_match(Sock, Key, <<"3">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E} = cmd(?INCREMENT, Sock, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 10}}),
        get_test_match(Sock, Key, <<"13">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E} = cmd(?DECREMENT, Sock, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 1}}),
        get_test_match(Sock, Key, <<"12">>),
        ok
    end)(),
    ok = gen_tcp:close(Sock).

stats_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    D = ets:new(test, [set]),
    ets:insert(D, {nvals, 0}),
    {ok, _H, _E} = cmd(?STAT, Sock,
                      fun (_MH, _ME) ->
                              ets:update_counter(D, nvals, 1)
                      end,
                      {#mc_header{}, #mc_entry{}}),
    [{nvals, X}] = ets:lookup(D, nvals),
    ?assert(X > 0),
    ok = gen_tcp:close(Sock).

