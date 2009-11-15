-module(mclient_ascii).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-record(msg, {cmd = "",
              key = "",
              flag = 0,
              expire = 0,
              cas = 0,
              data = <<>>}).

cmd(version, _Sock, _RecvCallback, _Msg) ->
    exit({unimplemented});
cmd(get, _Sock, _RecvCallback, _Msg) ->
    exit({unimplemented});
cmd(set, Sock, RecvCallback, Msg) ->
    cmd_update("set", Sock, RecvCallback, Msg);
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

%% @doc send an iolist and receive a single line back.
send_recv(Sock, IoList) ->
    send_recv(Sock, IoList, undefined).

send_recv(Sock, IoList, RecvCallback) ->
    ok = send(Sock, IoList),
    RV = recv_line(Sock),
    if is_function(RecvCallback) -> RecvCallback(RV);
       true -> ok
    end,
    RV.

send(Sock, IoList) ->
    gen_tcp:send(Sock, iolist_to_binary(IoList)).

%% @doc receive binary data of specified number of bytes length.
recv_data(_, 0) -> <<>>;
recv_data(Sock, NumBytes) ->
    case gen_tcp:recv(Sock, NumBytes) of
        {ok, Bin} -> {ok, Bin};
        Err -> Err
    end.

%% @doc receive a binary CRNL terminated line, including the CRNL.
recv_line(Sock) ->
    recv_line(Sock, <<>>).

recv_line(Sock, Acc) ->
    case gen_tcp:recv(Sock, 1) of
        {ok, B} ->
            Acc2 = <<Acc/binary, B/binary>>,
            case suffix(Acc2, 2) of
                <<"\r\n">> -> {ok, Acc2};
                _          -> recv_line(Sock, Acc2)
            end;
        Err -> Err
    end.

%% @doc returns the suffix for a binary, or <<>> if the binary is too short.
suffix(_, 0) -> <<>>;
suffix(Bin, SuffixLen) ->
    case size(Bin) >= SuffixLen of
        true  -> {_, Suffix} = split_binary(Bin, size(Bin) - 2),
                 Suffix;
        false -> <<>>
    end.

% -------------------------------------------------

suffix_test() ->
    ?assertMatch(<<"lo">>, suffix(<<"hello">>, 2)),
    ?assertMatch(<<"lo">>, suffix(<<"lo">>, 2)),
    ?assertMatch(<<>>, suffix(<<"o">>, 2)),
    ?assertMatch(<<>>, suffix(<<>>, 2)),
    ?assertMatch(<<>>, suffix(<<>>, 0)),
    ok.

recv_line_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    (fun () ->
        ok = gen_tcp:send(Sock, "version\r\n"),
        {ok, RB} = recv_line(Sock),
        R = binary_to_list(RB),
        ?assert(starts_with(R, "VERSION ")),
        ?assert(ends_with(R, "\r\n"))
    end)(),

    (fun () ->
        ok = gen_tcp:send(Sock, "not-a-command\r\n"),
        {ok, RB} = recv_line(Sock),
        ?assertMatch(RB, <<"ERROR\r\n">>)
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
        ?assertMatch(RB, <<"ERROR\r\n">>)
    end)(),

    (fun () ->
        {ok, RB} = send_recv(Sock, "get not-a-key-srt\r\n", nil),
        ?assertMatch(RB, <<"END\r\n">>)
    end)(),

    ok = gen_tcp:close(Sock).

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),

    (fun () ->
        {ok, RB} = send_recv(Sock, "flush_all\r\n", nil),
        ?assertMatch(RB, <<"OK\r\n">>),
        {ok, RB1} = send_recv(Sock, "get aaa-st\r\n", nil),
        ?assertMatch(RB1, <<"END\r\n">>)
    end)(),

    (fun () ->
        {ok, RB} = cmd(set, Sock, nil,
                       #msg{key= <<"aaa-st">>,
                            data= <<"AAA">>}),
        ?assertMatch(RB, <<"STORED\r\n">>),
        {ok, RB1} = send_recv(Sock, "get aaa-st\r\n", nil),
        ?assertMatch(RB1, <<"VALUE aaa-st 0 3\r\n">>),
        {ok, RB2} = recv_line(Sock),
        ?assertMatch(RB2, <<"AAA\r\n">>),
        {ok, RB3} = recv_line(Sock),
        ?assertMatch(RB3, <<"END\r\n">>)
    end)(),

    ok = gen_tcp:close(Sock).

starts_with(S, Prefix) ->
    Prefix =:= string:substr(S, 1, string:len(Prefix)).

ends_with(S, Suffix) ->
    Suffix =:= string:substr(S, string:len(S) - string:len(Suffix) + 1,
                                string:len(Suffix)).

