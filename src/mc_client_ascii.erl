-module(mc_client_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_client.hrl").

-compile(export_all).

cmd(version, Sock, RecvCallback, _Msg) ->
    send_recv(Sock, <<"version\r\n">>, RecvCallback);

cmd(get, Sock, RecvCallback, #mc_msg{keys = Keys}) ->
    ok = send(Sock, [<<"get ">>,
                     lists:map(fun (K) -> [K, <<" ">>] end,
                               Keys),
                     <<"\r\n">>]),
    get_recv(Sock, RecvCallback);

cmd(set, Sock, RecvCallback, Msg) ->
    cmd_update(<<"set">>, Sock, RecvCallback, Msg);
cmd(add, Sock, RecvCallback, Msg) ->
    cmd_update(<<"add">>, Sock, RecvCallback, Msg);
cmd(replace, Sock, RecvCallback, Msg) ->
    cmd_update(<<"replace">>, Sock, RecvCallback, Msg);
cmd(append, Sock, RecvCallback, Msg) ->
    cmd_update(<<"append">>, Sock, RecvCallback, Msg);
cmd(prepend, Sock, RecvCallback, Msg) ->
    cmd_update(<<"prepend">>, Sock, RecvCallback, Msg);

cmd(incr, Sock, RecvCallback, Msg) ->
    cmd_arith(<<"incr">>, Sock, RecvCallback, Msg);
cmd(decr, Sock, RecvCallback, Msg) ->
    cmd_arith(<<"decr">>, Sock, RecvCallback, Msg);

cmd(delete, Sock, RecvCallback, #mc_msg{key = Key}) ->
    send_recv(Sock, [<<"delete ">>, Key, <<"\r\n">>], RecvCallback);

cmd(flush_all, Sock, RecvCallback, _Msg) ->
    send_recv(Sock, [<<"flush_all\r\n">>], RecvCallback);

cmd(Cmd, Sock, RecvCallback, Msg) ->
    % Dispatch to cmd_binary() in case the caller was
    % using a binary protocol opcode.
    cmd_binary(Cmd, Sock, RecvCallback, Msg).

% -------------------------------------------------

cmd_update(Cmd, Sock, RecvCallback,
           #mc_msg{key = Key, flag = Flag, expire = Expire, data = Data}) ->
    SFlag = integer_to_list(Flag),
    SExpire = integer_to_list(Expire),
    SDataSize = integer_to_list(size(Data)),
    send_recv(Sock, [Cmd, <<" ">>,
                     Key, <<" ">>,
                     SFlag, <<" ">>,
                     SExpire, <<" ">>,
                     SDataSize, <<"\r\n">>,
                     Data, <<"\r\n">>],
              RecvCallback).

cmd_arith(Cmd, Sock, RecvCallback, #mc_msg{key = Key, data = Data}) ->
    send_recv(Sock, [Cmd, <<" ">>,
                     Key, <<" ">>,
                     Data, <<"\r\n">>],
              RecvCallback).

get_recv(Sock, RecvCallback) ->
    Line = recv_line(Sock),
    case Line of
        {error, _} = Err -> Err;
        {ok, <<"END">>} -> Line;
        {ok, <<"VALUE ", Rest/binary>>} ->
            Parse = io_lib:fread("~s ~u ~u", binary_to_list(Rest)),
            {ok, [Key, Flag, DataSize], _} = Parse,
            {ok, DataCRNL} = recv_data(Sock, DataSize + 2),
            if is_function(RecvCallback) ->
                    {Data, _} = split_binary_suffix(DataCRNL, 2),
                    RecvCallback(Line,
                                 #mc_msg{key = iolist_to_binary(Key),
                                         flag = Flag,
                                         data = Data});
               true -> ok
            end,
            get_recv(Sock, RecvCallback)
    end.

%% @doc Send an iolist and receive a single line back.
send_recv(Sock, IoList) ->
    send_recv(Sock, IoList, undefined).

send_recv(Sock, IoList, RecvCallback) ->
    ok = send(Sock, IoList),
    RV = recv_line(Sock),
    if is_function(RecvCallback) -> RecvCallback(RV, #mc_msg{});
       true -> ok
    end,
    RV.

send(_Sock, undefined) -> ok;
send(_Sock, <<>>) -> ok;
send(Sock, List) when is_list(List) -> send(Sock, iolist_to_binary(List));
send(Sock, Data) -> gen_tcp:send(Sock, Data).

%% @doc Receive binary data of specified number of bytes length.
recv_data(_, 0) -> {ok, <<>>};
recv_data(Sock, NumBytes) ->
    case gen_tcp:recv(Sock, NumBytes) of
        {ok, Bin} -> {ok, Bin};
        Err -> Err
    end.

%% @doc Receive a binary CRNL terminated line, not including the CRNL.
recv_line(Sock) ->
    recv_line(Sock, <<>>).

recv_line(Sock, Acc) ->
    case gen_tcp:recv(Sock, 1) of
        {ok, B} ->
            Acc2 = <<Acc/binary, B/binary>>,
            {Line, Suffix} = split_binary_suffix(Acc2, 2),
            case Suffix of
                <<"\r\n">> -> {ok, Line};
                _          -> recv_line(Sock, Acc2)
            end;
        Err -> Err
    end.

%% @doc Returns the {body, suffix} binary parts for a binary;
%%      Returns {body, <<>>} if the binary is too short.
%%
split_binary_suffix(Bin, 0) -> {Bin, <<>>};
split_binary_suffix(Bin, SuffixLen) ->
    case size(Bin) >= SuffixLen of
        true  -> split_binary(Bin, size(Bin) - SuffixLen);
        false -> {Bin, <<>>}
    end.

% -------------------------------------------------

%% For binary upstream talking to downstream ascii server.
%% The RecvCallback function will receive ascii-oriented parameters.

cmd_binary(?GET, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd_binary(?SET, Sock, RecvCallback, Msg) ->
    cmd(set, Sock, RecvCallback, Msg);

cmd_binary(?ADD, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?REPLACE, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd_binary(?DELETE, Sock, RecvCallback, Msg) ->
    cmd(delete, Sock, RecvCallback, Msg);

cmd_binary(?INCREMENT, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?DECREMENT, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?QUIT, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd_binary(?FLUSH, Sock, RecvCallback, Msg) ->
    cmd(flush_all, Sock, RecvCallback, Msg);

cmd_binary(?GETQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd_binary(?NOOP, _Sock, RecvCallback, _Msg) ->
    % Assuming NOOP used to uncork GETKQ's.
    if is_function(RecvCallback) -> RecvCallback({ok, <<"END">>},
                                                 #mc_msg{});
       true -> ok
    end;

cmd_binary(?VERSION, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?GETK, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd_binary(?GETKQ, Sock, RecvCallback, #mc_msg{keys = Keys}) ->
    cmd(get, Sock, RecvCallback, #mc_msg{keys = Keys});

cmd_binary(?APPEND, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?PREPEND, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?STAT, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?SETQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?ADDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?REPLACEQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?DELETEQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?INCREMENTQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?DECREMENTQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?QUITQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?FLUSHQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?APPENDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?PREPENDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RGET, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RSET, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RSETQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RAPPEND, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RAPPENDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RPREPEND, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RPREPENDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RDELETE, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RDELETEQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RINCR, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RINCRQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RDECR, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd_binary(?RDECRQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd_binary(Cmd, _Sock, _RecvCallback, _Msg) ->
    exit({unimplemented, Cmd}).

% -------------------------------------------------

suffix_test() ->
    ?assertMatch({<<"hel">>, <<"lo">>}, split_binary_suffix(<<"hello">>, 2)),
    ?assertMatch({<<"hello">>, <<>>}, split_binary_suffix(<<"hello">>, 0)),
    ?assertMatch({<<>>, <<"lo">>}, split_binary_suffix(<<"lo">>, 2)),
    ?assertMatch({<<"o">>, <<>>}, split_binary_suffix(<<"o">>, 2)),
    ?assertMatch({<<>>, <<>>}, split_binary_suffix(<<>>, 2)),
    ?assertMatch({<<>>, <<>>}, split_binary_suffix(<<>>, 0)),
    ok.

recv_line_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    (fun () ->
        ok = gen_tcp:send(Sock, "version\r\n"),
        {ok, RB} = recv_line(Sock),
        R = binary_to_list(RB),
        ?assert(starts_with(R, "VERSION "))
    end)(),

    (fun () ->
        ok = gen_tcp:send(Sock, "not-a-command\r\n"),
        {ok, RB} = recv_line(Sock),
        ?assertMatch(RB, <<"ERROR">>)
    end)(),

    ok = gen_tcp:close(Sock).

recv_data_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),

    (fun () ->
        ok = gen_tcp:send(Sock, "not-a-command\r\n"),
        ExpectB = <<"ERROR\r\n">>,
        {ok, RB} = recv_data(Sock, size(ExpectB)),
        ?assertMatch(RB, ExpectB)
    end)(),

    (fun () ->
        ok = gen_tcp:send(Sock, "get not-a-key\r\n"),
        ExpectB = <<"END\r\n">>,
        {ok, RB} = recv_data(Sock, size(ExpectB)),
        ?assertMatch(RB, ExpectB)
    end)(),

    ok = gen_tcp:close(Sock).

send_recv_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),

    (fun () ->
        {ok, RB} = send_recv(Sock, "not-a-command-srt\r\n", nil),
        ?assertMatch(RB, <<"ERROR">>)
    end)(),

    (fun () ->
        {ok, RB} = send_recv(Sock, "get not-a-key-srt\r\n", nil),
        ?assertMatch(RB, <<"END">>)
    end)(),

    ok = gen_tcp:close(Sock).

version_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    (fun () ->
        {ok, RB} = cmd(version, Sock, nil, nil),
        R = binary_to_list(RB),
        ?assert(starts_with(R, "VERSION "))
    end)(),

    ok = gen_tcp:close(Sock).

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    ok = gen_tcp:close(Sock).

set_test_sock(Sock, Key) ->
    (fun () ->
        {ok, RB} = send_recv(Sock, "flush_all\r\n", nil),
        ?assertMatch(RB, <<"OK">>),
        {ok, RB1} = send_recv(Sock, <<"get ", Key/binary, "\r\n">>, nil),
        ?assertMatch(RB1, <<"END">>)
    end)(),

    (fun () ->
        {ok, RB} = cmd(set, Sock, nil,
                       #mc_msg{key =  Key,
                               data = <<"AAA">>}),
        ?assertMatch(RB, <<"STORED">>),

        get_test_match(Sock, Key, <<"AAA">>)
    end)().

get_test_match(Sock, Key, Data) ->
    {ok, RB1} = send_recv(Sock, <<"get ", Key/binary, "\r\n">>, nil),
    DataSize = integer_to_list(size(Data)),
    Expect = iolist_to_binary(["VALUE ", Key, " 0 ", DataSize]),
    ?assertMatch(RB1, Expect),
    {ok, RB2} = recv_line(Sock),
    ?assertMatch(RB2, Data),
    {ok, RB3} = recv_line(Sock),
    ?assertMatch(RB3, <<"END">>).

delete_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),

    (fun () ->
        {ok, RB} = cmd(delete, Sock, nil,
                       #mc_msg{key = <<"aaa">>}),
        ?assertMatch(RB, <<"DELETED">>),

        {ok, RB1} = send_recv(Sock, "get aaa\r\n", nil),
        ?assertMatch(RB1, <<"END">>)
    end)(),

    ok = gen_tcp:close(Sock).

get_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),

    (fun () ->
        get_test_match(Sock, <<"aaa">>, <<"AAA">>),

        {ok, RB} = cmd(get, Sock,
                       fun (Line, Msg) ->
                          ?assertMatch(Line, {ok, <<"VALUE aaa 0 3">>}),
                          ?assertMatch(Msg,
                                       #mc_msg{key = <<"aaa">>, data = <<"AAA">>})
                       end,
                       #mc_msg{keys = [<<"aaa">>, <<"notkey1">>, <<"notkey2">>]}),
        ?assertMatch(RB, <<"END">>),

        {ok, RB1} = cmd(get, Sock,
                        fun (_Line, _Msg) ->
                           ?assert(false) % Not supposed to get here.
                        end,
                        #mc_msg{keys = [<<"notkey0">>, <<"notkey1">>]}),
        ?assertMatch(RB1, <<"END">>)
    end)(),

    ok = gen_tcp:close(Sock).

update_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),

    (fun () ->
        {ok, RB} = cmd(append, Sock, nil,
                       #mc_msg{key = <<"aaa">>, data = <<"-post">>}),
        ?assertMatch(RB, <<"STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"AAA-post">>),

        {ok, RB1} = cmd(prepend, Sock, nil,
                       #mc_msg{key = <<"aaa">>, data = <<"pre-">>}),
        ?assertMatch(RB1, <<"STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"pre-AAA-post">>),

        {ok, RB3} = cmd(add, Sock, nil,
                        #mc_msg{key = <<"aaa">>, data = <<"already exists">>}),
        ?assertMatch(RB3, <<"NOT_STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"pre-AAA-post">>),

        {ok, RB5} = cmd(replace, Sock, nil,
                        #mc_msg{key = <<"aaa">>, data = <<"replaced">>}),
        ?assertMatch(RB5, <<"STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"replaced">>),

        {ok, RB7} = cmd(flush_all, Sock, nil, #mc_msg{}),
        ?assertMatch(RB7, <<"OK">>),

        {ok, RBF} = send_recv(Sock, "get aaa\r\n", nil),
        ?assertMatch(RBF, <<"END">>)

    end)(),

    ok = gen_tcp:close(Sock).

starts_with(S, Prefix) ->
    Prefix =:= string:substr(S, 1, string:len(Prefix)).

ends_with(S, Suffix) ->
    Suffix =:= string:substr(S, string:len(S) - string:len(Suffix) + 1,
                                string:len(Suffix)).

