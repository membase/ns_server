-module(mc_server_ascii_proxy).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

% Note: this simple memcached ascii protocol server
% has an independent dict per session.

-record(session_proxy, {bucket}).

session(_Sock, Pool, _ProtocolModule) ->
    {ok, Bucket} = mc_pool:get_bucket(Pool, "default"),
    {ok, Pool, #session_proxy{bucket = Bucket}}.

% ------------------------------------------

cmd(get, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, Keys) ->
    ?debugVal(Session),
    Groups =
        group_by(Keys,
                 fun (Key) ->
                         {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
                         Addr
                 end),
    NumFwd = lists:foldl(fun ({Addr, AddrKeys}, Acc) ->
                             case a2x_forward(Addr, Out, get, AddrKeys) of
                                 true  -> Acc + 1;
                                 false -> Acc
                             end
                         end,
                         0, Groups),
    await_ok(NumFwd),
    mc_ascii:send(Out, <<"END\r\n">>),
    lists:map(fun ({Addr, _}) -> mc_downstream:demonitor(Addr) end,
              Groups),
    {ok, Session};

cmd(set, Session, InSock, Out, CmdArgs) ->
    forward_update(set, Session, InSock, Out, CmdArgs);
cmd(add, Session, InSock, Out, CmdArgs) ->
    forward_update(add, Session, InSock, Out, CmdArgs);
cmd(replace, Session, InSock, Out, CmdArgs) ->
    forward_update(replace, Session, InSock, Out, CmdArgs);
cmd(append, Session, InSock, Out, CmdArgs) ->
    forward_update(append, Session, InSock, Out, CmdArgs);
cmd(prepend, Session, InSock, Out, CmdArgs) ->
    forward_update(prepend, Session, InSock, Out, CmdArgs);

cmd(incr, Session, InSock, Out, CmdArgs) ->
    forward_update(incr, Session, InSock, Out, CmdArgs);
cmd(decr, Session, InSock, Out, CmdArgs) ->
    forward_update(decr, Session, InSock, Out, CmdArgs);

cmd(delete, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, [Key]) ->
    {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
    ok = a2x_forward(Addr, Out, delete, #mc_entry{key = Key}),
    case await_ok(1) of
        1 -> true;
        _ -> mc_ascii:send(Out, <<"ERROR\r\n">>)
    end,
    mc_downstream:demonitor(Addr),
    {ok, Session};

cmd(flush_all, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, CmdArgs) ->
    Addrs = mc_bucket:addrs(Bucket),
    NumFwd =
        lists:foldl(fun (Addr, Acc) ->
                        case a2x_forward(Addr, Out, flush_all, CmdArgs) of
                            true  -> Acc + 1;
                            false -> Acc
                        end
                    end,
                    0, Addrs),
    await_ok(NumFwd),
    mc_ascii:send(Out, <<"OK\r\n">>),
    lists:map(fun (Addr) -> mc_downstream:demonitor(Addr) end,
              Addrs),
    {ok, Session};

cmd(quit, _Session, _InSock, _Out, _Rest) ->
    exit({ok, quit_received}).

% ------------------------------------------

forward_update(Cmd, #session_proxy{bucket = Bucket} = Session,
               InSock, Out, [Key, FlagIn, ExpireIn, DataLenIn]) ->
    Flag = list_to_integer(FlagIn),
    Expire = list_to_integer(ExpireIn),
    DataLen = list_to_integer(DataLenIn),
    {ok, DataCRNL} = mc_ascii:recv_data(InSock, DataLen + 2),
    {Data, _} = mc_ascii:split_binary_suffix(DataCRNL, 2),
    {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
    Entry = #mc_entry{key = Key, flag = Flag, expire = Expire, data = Data},
    ok = a2x_forward(Addr, Out, Cmd, Entry),
    case await_ok(1) of
        1 -> true;
        _ -> mc_ascii:send(Out, <<"ERROR\r\n">>)
    end,
    mc_downstream:demonitor(Addr),
    {ok, Session}.

forward_arith(Cmd, #session_proxy{bucket = Bucket} = Session,
              _InSock, Out, [Key, AmountIn]) ->
    Amount = list_to_integer(AmountIn),
    {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
    ok = a2x_forward(Addr, Out, Cmd, #mc_entry{key = Key, data = Amount}),
    case await_ok(1) of
        1 -> true;
        _ -> mc_ascii:send(Out, <<"ERROR\r\n">>)
    end,
    mc_downstream:demonitor(Addr),
    {ok, Session}.

% ------------------------------------------

a2x_forward(Addr, Out, Cmd, CmdArgs) ->
    a2x_forward(Addr, Out, Cmd, CmdArgs, undefined, undefined).

a2x_forward(Addr, Out, Cmd, CmdArgs, ResponseFilter, NotifyData) ->
    Kind = mc_downstream:kind(Addr),
    ResponseFun =
        fun (Head, Body) ->
            case ((ResponseFilter =:= undefined) orelse
                  (ResponseFilter(Head, Body))) of
                true  -> a2x_send_response_from(Kind, Out, Head, Body);
                false -> true
            end
        end,
    ok = mc_downstream:monitor(Addr),
    ok = mc_downstream:send(Addr, fwd, self(), NotifyData, ResponseFun,
                            kind_to_module(Kind), Cmd, CmdArgs),
    ok.

a2x_send_response_from(ascii, Out, Head, Body) ->
    % Downstream is ascii.
    Out =/= undefined andalso
    (Head =/= undefined andalso
     mc_ascii:send(Out, [Head, <<"\r\n">>])) andalso
    (Body =:= undefined orelse
     mc_ascii:send(Out, [Body#mc_entry.data, <<"\r\n">>]));

a2x_send_response_from(binary, Out,
                       #mc_header{statusOrReserved = Status,
                                  opcode = Opcode} = _Head, Body) ->
    % Downstream is binary.
    case Status =:= ?SUCCESS of
        true ->
            case Opcode of
                ?GETKQ -> a2x_send_entry_from_binary(Out, Body);
                ?GETK  -> a2x_send_entry_from_binary(Out, Body);
                ?NOOP  -> mc_ascii:send(Out, <<"END\r\n">>);
                _ -> mc_ascii:send(Out, binary_success(Opcode))
            end;
        false ->
            mc_ascii:send(Out, [<<"ERROR ">>,
                                Body#mc_entry.data,
                                <<"\r\n">>])
    end.

a2x_send_entry_from_binary(Out, #mc_entry{key = Key, data = Data}) ->
    DataLen = integer_to_list(bin_size(Data)),
    ok =:= mc_ascii:send(Out, [<<"VALUE ">>, Key,
                               <<" 0 ">>, % TODO: Flag and Cas.
                               DataLen, <<"\r\n">>,
                               Data, <<"\r\n">>]).

kind_to_module(ascii)  -> mc_client_ascii;
kind_to_module(binary) -> mc_client_binary.

bin_size(undefined) -> 0;
bin_size(List) when is_list(List) -> bin_size(iolist_to_binary(List));
bin_size(Binary) -> size(Binary).

binary_success(?SET)    -> <<"STORED\r\n">>;
binary_success(?NOOP)   -> <<"END\r\n">>;
binary_success(?DELETE) -> <<"DELETED\r\n">>;
binary_success(_)       -> <<"OK\r\n">>.

await_ok(N) -> await_ok(N, 0).
await_ok(N, Acc) when N > 0 ->
    receive
        {ok, _, _} ->
            await_ok(N - 1, Acc + 1);
        {'DOWN', _MonitorRef, _, _, _} ->
            await_ok(N - 1, Acc)
    end;
await_ok(_, Acc) -> Acc.

group_by(Keys, KeyFunc) ->
    group_by(Keys, KeyFunc, dict:new()).

group_by([Key | Rest], KeyFunc, Dict) ->
    G = KeyFunc(Key),
    group_by(Rest, KeyFunc,
             dict:update(G, fun (V) -> [Key | V] end, [Key], Dict));
group_by([], _KeyFunc, Dict) ->
    lists:map(fun ({G, Val}) -> {G, lists:reverse(Val)} end,
              dict:to_list(Dict)).

% ------------------------------------------

% For testing...
%
main()        -> main(11333).
main(PortNum) -> mc_accept:start(PortNum,
                                 {mc_server_ascii,
                                  mc_server_ascii_proxy,
                                  mc_pool:create()}).

element2({_X, Y}) -> Y.

group_by_edge_test() ->
    ?assertMatch([],
                 group_by([],
                          fun element2/1)),
    ?assertMatch([{1, [{a, 1}]}],
                 group_by([{a, 1}],
                          fun element2/1)),
    ok.

group_by_simple_test() ->
    ?assertMatch([{1, [{a, 1}, {b, 1}]}],
                 group_by([{a, 1}, {b, 1}],
                          fun element2/1)),
    ?assertMatch([{2, [{c, 2}]},
                  {1, [{a, 1}, {b, 1}]}],
                 group_by([{a, 1}, {b, 1}, {c, 2}],
                          fun element2/1)),
    ?assertMatch([{2, [{c, 2}]},
                  {1, [{a, 1}, {b, 1}]}],
                 group_by([{a, 1}, {c, 2}, {b, 1}],
                          fun element2/1)),
    ?assertMatch([{2, [{c, 2}]},
                  {1, [{a, 1}, {b, 1}]}],
                 group_by([{c, 2}, {a, 1}, {b, 1}],
                          fun element2/1)),
    ok.
