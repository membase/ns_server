% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_client_ascii).

-behavior(mc_client).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-import(mc_ascii, [send/2, send_recv/4, recv_line/1, recv_data/2,
                   split_binary_suffix/2]).

-export([auth/2, cmd/5]).

-compile(export_all).

%% A memcached client that speaks ascii protocol.

auth(_U, _P) ->
    exit(not_implemented).

cmd(version, Sock, RecvCallback, CBData, _Entry) ->
    send_recv(Sock, <<"version\r\n">>, RecvCallback, CBData);

cmd(get, Sock, RecvCallback, CBData, #mc_entry{key = Key}) ->
    ok = send(Sock, [<<"get ">>, Key, <<"\r\n">>]),
    get_recv(Sock, RecvCallback, CBData);
cmd(gets, Sock, RecvCallback, CBData, #mc_entry{key = Key}) ->
    ok = send(Sock, [<<"gets ">>, Key, <<"\r\n">>]),
    get_recv(Sock, RecvCallback, CBData);

cmd(get, Sock, RecvCallback, CBData, Keys) when is_list(Keys) ->
    ok = send(Sock, [<<"get ">>,
                     tl(lists:reverse(
                          lists:foldl(fun (K, Acc) -> [K, <<" ">> | Acc] end,
                                      [], Keys))),
                     <<"\r\n">>]),
    get_recv(Sock, RecvCallback, CBData);
cmd(gets, Sock, RecvCallback, CBData, Keys) when is_list(Keys) ->
    ok = send(Sock, [<<"gets ">>,
                     tl(lists:reverse(
                          lists:foldl(fun (K, Acc) -> [K, <<" ">> | Acc] end,
                                      [], Keys))),
                     <<"\r\n">>]),
    get_recv(Sock, RecvCallback, CBData);

cmd(set, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(<<"set">>, Sock, RecvCallback, CBData, Entry);
cmd(add, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(<<"add">>, Sock, RecvCallback, CBData, Entry);
cmd(replace, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(<<"replace">>, Sock, RecvCallback, CBData, Entry);
cmd(append, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(<<"append">>, Sock, RecvCallback, CBData, Entry);
cmd(prepend, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(<<"prepend">>, Sock, RecvCallback, CBData, Entry);

cmd(cas, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(cas, Sock, RecvCallback, CBData, Entry);

cmd(incr, Sock, RecvCallback, CBData, Entry) ->
    cmd_arith(<<"incr">>, Sock, RecvCallback, CBData, Entry);
cmd(decr, Sock, RecvCallback, CBData, Entry) ->
    cmd_arith(<<"decr">>, Sock, RecvCallback, CBData, Entry);

cmd(delete, Sock, RecvCallback, CBData, #mc_entry{key = Key}) ->
    send_recv(Sock, [<<"delete ">>, Key, <<"\r\n">>], RecvCallback, CBData);

cmd(flush_all, Sock, RecvCallback, CBData, #mc_entry{ext = Delay}) ->
    M = case Delay of
            undefined       -> [<<"flush_all\r\n">>];
            <<DelayInt:32>> -> DelayStr = integer_to_list(DelayInt),
                               [<<"flush_all ">>, DelayStr, <<"\r\n">>]
        end,
    send_recv(Sock, M, RecvCallback, CBData);

cmd(stats, Sock, RecvCallback, CBData, #mc_entry{key = Key}) ->
    M = case Key of
            undefined -> <<"stats\r\n">>;
            _         -> [<<"stats ">>, Key, <<"\r\n">>]
        end,
    ok = send(Sock, M),
    multiline_recv(Sock, RecvCallback, CBData).

% -------------------------------------------------

cmd_update(cas, Sock, RecvCallback, CBData,
           #mc_entry{key = Key, flag = Flag, expire = Expire, data = Data,
                     cas = Cas}) ->
    SFlag = integer_to_list(Flag),
    SExpire = integer_to_list(Expire),
    SDataSize = integer_to_list(size(Data)),
    SCas = integer_to_list(Cas),
    send_recv(Sock, [<<"cas  ">>,
                     Key, <<" ">>,
                     SFlag, <<" ">>,
                     SExpire, <<" ">>,
                     SDataSize, <<" ">>,
                     SCas, <<"\r\n">>,
                     Data, <<"\r\n">>],
              RecvCallback, CBData);

cmd_update(Cmd, Sock, RecvCallback, CBData,
           #mc_entry{key = Key, flag = Flag, expire = Expire, data = Data}) ->
    SFlag = integer_to_list(Flag),
    SExpire = integer_to_list(Expire),
    SDataSize = integer_to_list(size(Data)),
    send_recv(Sock, [Cmd, <<" ">>,
                     Key, <<" ">>,
                     SFlag, <<" ">>,
                     SExpire, <<" ">>,
                     SDataSize, <<"\r\n">>,
                     Data, <<"\r\n">>],
              RecvCallback, CBData).

cmd_arith(Cmd, Sock, RecvCallback, CBData, #mc_entry{key = Key, data = Data}) ->
    send_recv(Sock, [Cmd, <<" ">>,
                     Key, <<" ">>,
                     Data, <<"\r\n">>],
              RecvCallback, CBData).

get_recv(Sock, RecvCallback, CBData) ->
    Line = recv_line(Sock),
    case Line of
        {error, _} = Err -> Err;
        {ok, <<"END">>}  -> Line;
        {ok, <<"VALUE ", Rest/binary>> = LineBin} ->
            Parse = io_lib:fread("~s ~u ~u", binary_to_list(Rest)),
            {ok, [Key, Flag, DataSize], Remaining} = Parse,
            CasIn = string:strip(Remaining),
            Cas = case CasIn of
                      "" -> 0;
                      _  -> list_to_integer(CasIn)
                  end,
            {ok, DataCRNL} = recv_data(Sock, DataSize + 2),
            NCB = case is_function(RecvCallback) of
                      true -> {Data, _} = split_binary_suffix(DataCRNL, 2),
                              RecvCallback(LineBin,
                                           #mc_entry{key = iolist_to_binary(Key),
                                                     flag = Flag,
                                                     data = Data,
                                                     cas = Cas},
                                           CBData);
                      false -> CBData
                  end,
            get_recv(Sock, RecvCallback, NCB)
    end.

multiline_recv(Sock, RecvCallback, CBData) -> % For stats response.
    Line = recv_line(Sock),
    case Line of
        {error, _} = Err  -> Err;
        {ok, <<"END">>}   -> {Line, CBData};
        {ok, <<"OK">>}    -> {Line, CBData}; % From stats detail on|off.
        {ok, <<"ERROR">>} -> {Line, CBData}; % From stats <bad_cmd]>
        {ok, <<"RESET">>} -> {Line, CBData}; % From stats reset.
        {ok, <<"CLIENT_ERROR", _>>} -> {Line, CBData};
        {ok, <<"SERVER_ERROR", _>>} -> {Line, CBData};
        {ok, LineBin}     -> NCB = case is_function(RecvCallback) of
                                       true  -> RecvCallback(LineBin, undefined, CBData);
                                       false -> CBData
                                   end,
                             multiline_recv(Sock, RecvCallback, NCB)
    end.

% -------------------------------------------------

version_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    (fun () ->
        {ok, RB, undefined} = cmd(version, Sock, undefined, undefined, undefined),
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
        {ok, RB, undefined} = send_recv(Sock, "flush_all\r\n", undefined, undefined),
        ?assertMatch(RB, <<"OK">>),
        {ok, RB1, undefined} = send_recv(Sock, <<"get ", Key/binary, "\r\n">>,
                              undefined, undefined),
        ?assertMatch(RB1, <<"END">>)
    end)(),
    (fun () ->
        {ok, RB, undefined} = cmd(set, Sock, undefined, undefined,
                                  #mc_entry{key =  Key,
                                            data = <<"AAA">>}),
        ?assertMatch(RB, <<"STORED">>),
        get_test_match(Sock, Key, <<"AAA">>)
    end)().

get_test_match(Sock, Key, Data) ->
    {ok, RB1, undefined} = send_recv(Sock, <<"get ", Key/binary, "\r\n">>,
                          undefined, undefined),
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
        {ok, RB, undefined} = cmd(delete, Sock, undefined, undefined,
                       #mc_entry{key = <<"aaa">>}),
        ?assertMatch(RB, <<"DELETED">>),
        {ok, RB1, undefined} = send_recv(Sock, "get aaa\r\n", undefined, undefined),
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
                       fun (Line, Entry, undefined) ->
                          ?assertMatch(Line, <<"VALUE aaa 0 3">>),
                          ?assertMatch(Entry,
                                       #mc_entry{key = <<"aaa">>,
                                                 data = <<"AAA">>})
                       end, undefined,
                       [<<"aaa">>, <<"notkey1">>, <<"notkey2">>]),
        ?assertMatch(RB, <<"END">>),
        {ok, RB1} = cmd(get, Sock,
                        fun (_Line, _Entry, undefined) ->
                           ?assert(false) % Not supposed to get here.
                        end, undefined,
                        [<<"notkey0">>, <<"notkey1">>]),
        ?assertMatch(RB1, <<"END">>)
    end)(),
    ok = gen_tcp:close(Sock).

update_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    (fun () ->
        {ok, RB, undefined} = cmd(append, Sock, undefined, undefined,
                                  #mc_entry{key = <<"aaa">>, data = <<"-post">>}),
        ?assertMatch(RB, <<"STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"AAA-post">>),
        {ok, RB1, undefined} = cmd(prepend, Sock, undefined, undefined,
                                   #mc_entry{key = <<"aaa">>, data = <<"pre-">>}),
        ?assertMatch(RB1, <<"STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"pre-AAA-post">>),
        {ok, RB3, undefined} = cmd(add, Sock, undefined, undefined,
                                   #mc_entry{key = <<"aaa">>,
                                             data = <<"already exists">>}),
        ?assertMatch(RB3, <<"NOT_STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"pre-AAA-post">>),
        {ok, RB5, undefined} = cmd(replace, Sock, undefined, undefined,
                                   #mc_entry{key = <<"aaa">>, data = <<"replaced">>}),
        ?assertMatch(RB5, <<"STORED">>),
        get_test_match(Sock, <<"aaa">>, <<"replaced">>),
        {ok, RB7, undefined} = cmd(flush_all, Sock, undefined, undefined, #mc_entry{}),
        ?assertMatch(RB7, <<"OK">>),
        {ok, RBF, undefined} = send_recv(Sock, "get aaa\r\n", undefined, undefined),
        ?assertMatch(RBF, <<"END">>)
    end)(),
    ok = gen_tcp:close(Sock).

starts_with(S, Prefix) ->
    Prefix =:= string:substr(S, 1, string:len(Prefix)).

ends_with(S, Suffix) ->
    Suffix =:= string:substr(S, string:len(S) - string:len(Suffix) + 1,
                                string:len(Suffix)).

stats_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    (fun () ->
             {{ok, RB}, true} = cmd(stats, Sock,
                                    fun (Line, Entry, _X) ->
                                            undefined = Entry,
                                            LineStr = binary_to_list(Line),
                                            starts_with(LineStr, "STAT ")
                                    end, undefined,
                                    #mc_entry{}),
             ?assertMatch(RB, <<"END">>)
     end)(),
    ok = gen_tcp:close(Sock).

