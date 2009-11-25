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
    Groups =
        group_by(Keys,
                 fun (Key) ->
                     {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
                     Addr
                 end),
    {NumFwd, Monitors} =
        lists:foldl(fun ({Addr, AddrKeys}, Acc) ->
                        accum(forward(Addr, Out, get, AddrKeys), Acc)
                    end,
                    {0, []}, Groups),
    await_ok(NumFwd),
    mc_ascii:send(Out, <<"END\r\n">>),
    mc_downstream:demonitor(Monitors),
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
    forward_arith(incr, Session, InSock, Out, CmdArgs);
cmd(decr, Session, InSock, Out, CmdArgs) ->
    forward_arith(decr, Session, InSock, Out, CmdArgs);

cmd(delete, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, [Key]) ->
    {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
    {ok, Monitor} = forward(Addr, Out, delete, #mc_entry{key = Key}),
    case await_ok(1) of
        1 -> true;
        _ -> mc_ascii:send(Out, <<"ERROR\r\n">>)
    end,
    mc_downstream:demonitor([Monitor]),
    {ok, Session};

cmd(flush_all, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, CmdArgs) ->
    Addrs = mc_bucket:addrs(Bucket),
    {NumFwd, Monitors} =
        lists:foldl(fun (Addr, Acc) ->
                        % Using undefined Out to swallow the OK
                        % responses from the downstreams.
                        accum(forward(Addr, undefined,
                                      flush_all, CmdArgs), Acc)
                    end,
                    {0, []}, Addrs),
    await_ok(NumFwd),
    mc_ascii:send(Out, <<"OK\r\n">>),
    mc_downstream:demonitor(Monitors),
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
    {ok, Monitor} = forward(Addr, Out, Cmd, Entry),
    case await_ok(1) of
        1 -> true;
        _ -> mc_ascii:send(Out, <<"ERROR\r\n">>)
    end,
    mc_downstream:demonitor([Monitor]),
    {ok, Session}.

forward_arith(Cmd, #session_proxy{bucket = Bucket} = Session,
              _InSock, Out, [Key, Amount]) ->
    {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
    {ok, Monitor} = forward(Addr, Out, Cmd,
                            #mc_entry{key = Key, data = Amount}),
    case await_ok(1) of
        1 -> true;
        _ -> mc_ascii:send(Out, <<"ERROR\r\n">>)
    end,
    mc_downstream:demonitor([Monitor]),
    {ok, Session}.

% ------------------------------------------

forward(Addr, Out, Cmd, CmdArgs) ->
    forward(Addr, Out, Cmd, CmdArgs, undefined).

forward(Addr, Out, Cmd, CmdArgs, ResponseFilter) ->
    Kind = mc_addr:kind(Addr),
    ResponseFun =
        fun (Head, Body) ->
            case ((not is_function(ResponseFilter)) orelse
                  (ResponseFilter(Head, Body))) of
                true  -> send_response(Kind, Out, Head, Body);
                false -> false
            end
        end,
    {ok, Monitor} = mc_downstream:monitor(Addr),
    case mc_downstream:send(Addr, fwd, self(), ResponseFun,
                            kind_to_module(Kind), Cmd, CmdArgs) of
        ok -> {ok, Monitor};
        _  -> {error, Monitor}
    end.

% Accumulate results of forward during a foldl.
accum(A2xForwardResult, {NumOks, Monitors}) ->
    case A2xForwardResult of
        {ok, Monitor} -> {NumOks + 1, [Monitor | Monitors]};
        {_,  Monitor} -> {NumOks, [Monitor | Monitors]}
    end.

send_response(ascii, Out, Head, Body) ->
    % Downstream is ascii.
    (Out =/= undefined) andalso
    ((Head =/= undefined) andalso
     (ok =:= mc_ascii:send(Out, [Head, <<"\r\n">>]))) andalso
    ((Body =:= undefined) orelse
     (ok =:= mc_ascii:send(Out, [Body#mc_entry.data, <<"\r\n">>])));

send_response(binary, Out,
                       #mc_header{statusOrReserved = Status,
                                  opcode = Opcode} = _Head, Body) ->
    % Downstream is binary.
    case Status =:= ?SUCCESS of
        true ->
            case Opcode of
                ?GETKQ -> send_entry_binary(Out, Body);
                ?GETK  -> send_entry_binary(Out, Body);
                ?NOOP  -> mc_ascii:send(Out, <<"END\r\n">>);
                _ -> mc_ascii:send(Out, mc_binary:b2a_code(Opcode, Status))
            end;
        false ->
            mc_ascii:send(Out, mc_binary:b2a_code(Opcode, Status))
    end.

send_entry_binary(Out, #mc_entry{key = Key, data = Data, flag = Flag}) ->
    % TODO: CAS during a gets.
    DataLen = integer_to_list(bin_size(Data)),
    FlagStr = integer_to_list(Flag),
    ok =:= mc_ascii:send(Out, [<<"VALUE ">>, Key,
                               <<" ">>, FlagStr, <<" ">>,
                               DataLen, <<"\r\n">>,
                               Data, <<"\r\n">>]).

kind_to_module(ascii)  -> mc_client_ascii_ac;
kind_to_module(binary) -> mc_client_binary_ac.

bin_size(undefined) -> 0;
bin_size(List) when is_list(List) -> bin_size(iolist_to_binary(List));
bin_size(Binary) -> size(Binary).

await_ok(N) -> await_ok(N, 0).
await_ok(N, Acc) when N > 0 ->
    receive
        {ok, _}    -> await_ok(N - 1, Acc + 1);
        {ok, _, _} -> await_ok(N - 1, Acc + 1);
        {'DOWN', _MonitorRef, _, _, _}  -> await_ok(N - 1, Acc);
        Unexpected -> ?debugVal(Unexpected),
                      exit({error, Unexpected})
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
