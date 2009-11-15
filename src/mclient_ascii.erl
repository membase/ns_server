-module(mclient_ascii).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

% cmd(get, Sock, RecvCB, Args) ->
%   ok;
% cmd(version, Sock, RecvCB, Args) ->
%   ok.

%% @doc receive binary data of specified number of bytes length.
recv_data(_, 0) -> <<>>;
recv_data(Sock, NumBytes) ->
    case gen_tcp:recv(Sock, NumBytes) of
        {ok, Bin} -> {ok, Bin};
        Err -> Err
    end.

%% @doc receive a binary \r\n terminated line, including the \r\n.
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

    ok = gen_tcp:send(Sock, "version\r\n"),
    {ok, R1B} = recv_line(Sock),
    R1 = binary_to_list(R1B),
    ?assert(starts_with(R1, "VERSION ")),
    ?assert(ends_with(R1, "\r\n")),

    ok = gen_tcp:send(Sock, "not-a-command\r\n"),
    {ok, R2B} = recv_line(Sock),
    ?assertMatch(R2B, <<"ERROR\r\n">>),

    ok = gen_tcp:close(Sock).

recv_data_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),

    ok = gen_tcp:send(Sock, "not-a-command\r\n"),
    ExpectB = <<"ERROR\r\n">>,
    {ok, RB} = recv_data(Sock, size(ExpectB)),
    ?assertMatch(RB, ExpectB),

    ok = gen_tcp:close(Sock).

starts_with(S, Prefix) ->
    Prefix =:= string:substr(S, 1, string:len(Prefix)).

ends_with(S, Suffix) ->
    Suffix =:= string:substr(S, string:len(S) - string:len(Suffix) + 1,
                                string:len(Suffix)).

