-module(mclient_ascii).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mclient.hrl").

-compile(export_all).

cmd(version, Sock, RecvCallback, _Msg) ->
    send_recv(Sock, <<"version\r\n">>,
              RecvCallback);

cmd(get, Sock, RecvCallback, #msg{keys=Keys}) ->
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

cmd(delete, Sock, RecvCallback, #msg{key=Key}) ->
    send_recv(Sock, [<<"delete ">>, Key, <<"\r\n">>],
              RecvCallback);

cmd(flush_all, Sock, RecvCallback, _Msg) ->
    send_recv(Sock, [<<"flush_all\r\n">>],
              RecvCallback);

% -------------------------------------------------

%% For binary upstream talking to downstream ascii server.
%% The RecvCallback functions will receive ascii-oriented parameters.

cmd(?GET, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd(?SET, Sock, RecvCallback, Msg) ->
    cmd(set, Sock, RecvCallback, Msg);

cmd(?ADD, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?REPLACE, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd(?DELETE, Sock, RecvCallback, Msg) ->
    cmd(delete, Sock, RecvCallback, Msg);

cmd(?INCREMENT, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?DECREMENT, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?QUIT, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd(?FLUSH, Sock, RecvCallback, Msg) ->
    cmd(flush_all, Sock, RecvCallback, Msg);

cmd(?GETQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd(?NOOP, _Sock, RecvCallback, _Msg) ->
    % Assuming NOOP used to uncork GETKQ's.
    if is_function(RecvCallback) -> RecvCallback({ok, <<"END">>},
                                                 #msg{});
       true -> ok
    end;

cmd(?VERSION, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?GETK, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

cmd(?GETKQ, Sock, RecvCallback, #msg{keys=Keys}) ->
    cmd(get, Sock, RecvCallback, #msg{keys=Keys});

cmd(?APPEND, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?PREPEND, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?STAT, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?SETQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?ADDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?REPLACEQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?DELETEQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?INCREMENTQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?DECREMENTQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?QUITQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?FLUSHQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?APPENDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?PREPENDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RGET, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RSET, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RSETQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RAPPEND, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RAPPENDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RPREPEND, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RPREPENDQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RDELETE, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RDELETEQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RINCR, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RINCRQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RDECR, _Sock, _RecvCallback, _Msg) ->
    exit(todo);
cmd(?RDECRQ, _Sock, _RecvCallback, _Msg) ->
    exit(todo);

% -------------------------------------------------

cmd(Cmd, _, _, _) ->
    exit({unimplemented, Cmd}).

cmd_update(Cmd, Sock, RecvCallback,
           #msg{key=Key, flag=Flag, expire=Expire, data=Data}) ->
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

get_recv(Sock, RecvCallback) ->
    Line = recv_line(Sock),
    case Line of
        {error, _}=Err -> Err;
        {ok, <<"END">>} -> Line;
        {ok, <<"VALUE ", Rest/binary>>} ->
            Parse = io_lib:fread("~s ~u ~u", binary_to_list(Rest)),
            {ok, [Key, Flag, DataSize], _} = Parse,
            {ok, Data} = recv_data(Sock, DataSize + 2),
            if is_function(RecvCallback) -> RecvCallback(Line,
                                                         #msg{key=Key,
                                                              flag=Flag,
                                                              data=Data});
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
    if is_function(RecvCallback) -> RecvCallback(RV, #msg{});
       true -> ok
    end,
    RV.

send(Sock, IoList) ->
    gen_tcp:send(Sock, iolist_to_binary(IoList)).

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
                       #msg{key= Key,
                            data= <<"AAA">>}),
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
                       #msg{key= <<"aaa">>}),
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

        {ok, RB} = cmd(get, Sock, nil,
                       #msg{keys= [<<"aaa">>, <<"notkey1">>, <<"notkey2">>]}),
        ?assertMatch(RB, <<"END">>),

        {ok, RB1} = cmd(get, Sock, nil,
                        #msg{keys= [<<"notkey0">>, <<"notkey1">>, <<"notkey2">>]}),
        ?assertMatch(RB1, <<"END">>)
    end)(),

    ok = gen_tcp:close(Sock).

update_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),

    (fun () ->
        {ok, RB} = cmd(append, Sock, nil,
                       #msg{key= <<"aaa">>, data= <<"-post">>}),
        ?assertMatch(RB, <<"STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"AAA-post">>),

        {ok, RB1} = cmd(prepend, Sock, nil,
                       #msg{key= <<"aaa">>, data= <<"pre-">>}),
        ?assertMatch(RB1, <<"STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"pre-AAA-post">>),

        {ok, RB3} = cmd(add, Sock, nil,
                        #msg{key= <<"aaa">>, data= <<"already exists">>}),
        ?assertMatch(RB3, <<"NOT_STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"pre-AAA-post">>),

        {ok, RB5} = cmd(replace, Sock, nil,
                        #msg{key= <<"aaa">>, data= <<"replaced">>}),
        ?assertMatch(RB5, <<"STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"replaced">>),

        {ok, RB7} = cmd(flush_all, Sock, nil, #msg{}),
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

