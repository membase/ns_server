-module(mc_client_binary_pc).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_client.hrl").

-import(mc_client_binary, [send/2, send/4, send_recv/5, recv/2, encode/3]).

-compile(export_all).

%% A memcached client that speaks binary protocol,
%% with an "API conversion" interface.

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
    mc_client_binary:cmd(Opcode, Sock, RecvCallback, Entry).

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

% -------------------------------------------------

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

test_flush(Sock) ->
    {ok, works} = send_recv(Sock, nil,
                            #mc_header{opcode = ?FLUSH}, #mc_entry{}, works).

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


