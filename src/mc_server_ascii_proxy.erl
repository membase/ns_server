-module(mc_server_ascii_proxy).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-import(mc_downstream, [accum/2, await_ok/1, group_by/2]).

-import(mc_replication, [send/7]).

-compile(export_all).

-record(session_proxy, {bucket}).

session(_Sock, Pool) ->
    {ok, Bucket} = mc_pool:get_bucket(Pool, "default"),
    {ok, Pool, #session_proxy{bucket = Bucket}}.

% ------------------------------------------

cmd(get, Session, InSock, Out, Keys) ->
    forward_get(get, Session, InSock, Out, Keys);
cmd(gets, Session, InSock, Out, Keys) ->
    forward_get(gets, Session, InSock, Out, Keys);

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

cmd(cas, Session, InSock, Out, CmdArgs) ->
    forward_update(cas, Session, InSock, Out, CmdArgs);

cmd(incr, Session, InSock, Out, CmdArgs) ->
    forward_arith(incr, Session, InSock, Out, CmdArgs);
cmd(decr, Session, InSock, Out, CmdArgs) ->
    forward_arith(decr, Session, InSock, Out, CmdArgs);

cmd(delete, Session, InSock, _Out, [Key, "noreply"]) ->
    cmd(delete, Session, InSock, undefined, [Key]);

cmd(delete, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, [Key]) ->
    {Key, Addrs, _Config} = mc_bucket:choose_addrs(Bucket, Key),
    {value, MinOk} =
        {value, undefined}, % ns_config:search(Config, replica_w),
    {ok, Monitors} = send(Addrs, Out, delete, #mc_entry{key = Key},
                          undefined, ?MODULE, MinOk),
    case await_ok(1) of
        1 -> true;
        _ -> mc_ascii:send(Out, <<"ERROR\r\n">>)
    end,
    mc_downstream:demonitor(Monitors),
    {ok, Session};

cmd(flush_all, Session, InSock, _Out, ["noreply"]) ->
    cmd(flush_all, Session, InSock, undefined, []);
cmd(flush_all, Session, InSock, _Out, [X, "noreply"]) ->
    cmd(flush_all, Session, InSock, undefined, [X]);

cmd(flush_all, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, CmdArgs) ->
    Addrs = mc_bucket:addrs(Bucket),
    Delay = case CmdArgs of
                []  -> undefined;
                [X] -> XInt = list_to_integer(X),
                       <<XInt:32>>
            end,
    {NumFwd, Monitors} =
        lists:foldl(fun (Addr, Acc) ->
                        % Using undefined Out to swallow the OK
                        % responses from the downstreams.
                        accum(send([Addr], undefined,
                                   flush_all, #mc_entry{ext = Delay},
                                   undefined, ?MODULE, undefined), Acc)
                    end,
                    {0, []}, Addrs),
    await_ok(NumFwd),
    mc_ascii:send(Out, <<"OK\r\n">>),
    mc_downstream:demonitor(Monitors),
    {ok, Session};

cmd(stats, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, CmdArgs) ->
    Addrs = mc_bucket:addrs(Bucket),
    Args = case CmdArgs of [] -> undefined;
                           _  -> string:join(CmdArgs, " ")
           end,
    ResponseFilter =
        fun (LineBin, undefined) ->
                mc_ascii:send(Out, [LineBin, <<"\r\n">>]),
                false;
            (#mc_header{status = ?SUCCESS},
             #mc_entry{key = KeyBin, data = DataBin}) ->
                mc_ascii:send(Out, [<<"STAT ">>,
                                    KeyBin, <<" ">>,
                                    DataBin, <<"\r\n">>]),
                false;
            (_, _) ->
                false
        end,
    {NumFwd, Monitors} =
        lists:foldl(fun (Addr, Acc) ->
                        % Using undefined Out to swallow the OK
                        % responses from the downstreams.
                        accum(send([Addr], undefined,
                                   stats, #mc_entry{key = Args},
                                   ResponseFilter, ?MODULE, undefined), Acc)
                    end,
                    {0, []}, Addrs),
    await_ok(NumFwd),
    % TODO: Different stats args don't all use "END".
    % TODO: ERROR from stats doesn't use "END".
    mc_ascii:send(Out, <<"END\r\n">>),
    mc_downstream:demonitor(Monitors),
    {ok, Session};

cmd(version, Session, _InSock, Out, _CmdArgs) ->
    V = case ns_config:search(version) of
            {value, X} -> X;
            false      -> "X.X.X"
        end,
    mc_ascii:send(Out, [<<"VERSION ">>, V, <<"\r\n">>]),
    {ok, Session};

% TODO:
% verbosity

cmd(quit, _Session, _InSock, _Out, _Rest) ->
    exit({ok, quit_received});

cmd(_, Session, _, Out, _) ->
    mc_ascii:send(Out, <<"ERROR\r\n">>),
    {ok, Session}.

% ------------------------------------------

forward_get(Cmd, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, Keys) ->
    Groups =
        group_by(Keys,
                 fun (Key) ->
                     {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
                     Addr
                 end),
    {NumFwd, Monitors} =
        lists:foldl(fun ({Addr, AddrKeys}, Acc) ->
                        accum(send([Addr], Out, Cmd, AddrKeys,
                                   undefined, ?MODULE, undefined), Acc)
                    end,
                    {0, []}, Groups),
    await_ok(NumFwd),
    mc_ascii:send(Out, <<"END\r\n">>),
    mc_downstream:demonitor(Monitors),
    {ok, Session}.

% ------------------------------------------

forward_update(Cmd, Session, InSock, _Out,
               [Key, FlagIn, ExpireIn, DataLenIn, "noreply"]) ->
    forward_update(Cmd, Session, InSock, undefined,
                   [Key, FlagIn, ExpireIn, DataLenIn, "0"]);
forward_update(Cmd, Session,InSock, _Out,
               [Key, FlagIn, ExpireIn, DataLenIn, CasIn, "noreply"]) ->
    forward_update(Cmd, Session, InSock, undefined,
                   [Key, FlagIn, ExpireIn, DataLenIn, CasIn]);
forward_update(Cmd, Session, InSock, Out,
               [Key, FlagIn, ExpireIn, DataLenIn]) ->
    forward_update(Cmd, Session, InSock, Out,
                   [Key, FlagIn, ExpireIn, DataLenIn, "0"]);

forward_update(Cmd, #session_proxy{bucket = Bucket} = Session,
               InSock, Out, [Key, FlagIn, ExpireIn, DataLenIn, CasIn]) ->
    Flag = list_to_integer(FlagIn),
    Expire = list_to_integer(ExpireIn),
    DataLen = list_to_integer(DataLenIn),
    Cas = list_to_integer(CasIn),
    {ok, DataCRNL} = mc_ascii:recv_data(InSock, DataLen + 2),
    {Data, _} = mc_ascii:split_binary_suffix(DataCRNL, 2),
    {Key, Addrs, _Config} = mc_bucket:choose_addrs(Bucket, Key),
    {value, MinOk} =
        {value, undefined}, % ns_config:search(Config, replica_w),
    Entry = #mc_entry{key = Key, flag = Flag, expire = Expire, data = Data,
                      cas = Cas},
    {ok, Monitors} = send(Addrs, Out, Cmd, Entry,
                          undefined, ?MODULE, MinOk),
    case await_ok(1) of
        1 -> true;
        _ -> mc_ascii:send(Out, <<"ERROR\r\n">>)
    end,
    mc_downstream:demonitor(Monitors),
    {ok, Session};

forward_update(_, Session, _, Out, _CmdArgs) ->
    % Possibly due to wrong # of CmdArgs.
    mc_ascii:send(Out, <<"ERROR\r\n">>),
    {ok, Session}.

forward_arith(Cmd, Session,
              InSock, _Out, [Key, Amount, "noreply"]) ->
    forward_arith(Cmd, Session, InSock, undefined, [Key, Amount]);

forward_arith(Cmd, #session_proxy{bucket = Bucket} = Session,
              _InSock, Out, [Key, Amount]) ->
    {Key, Addrs, _Config} = mc_bucket:choose_addrs(Bucket, Key),
    {value, MinOk} =
        {value, undefined}, % ns_config:search(Config, replica_w),
    {ok, Monitors} = send(Addrs, Out, Cmd,
                          #mc_entry{key = Key, data = Amount},
                          undefined, ?MODULE, MinOk),
    case await_ok(1) of
        1 -> true;
        _ -> mc_ascii:send(Out, <<"ERROR\r\n">>)
    end,
    mc_downstream:demonitor(Monitors),
    {ok, Session};

forward_arith(_, Session, _, Out, _CmdArgs) ->
    % Possibly due to wrong # of CmdArgs.
    mc_ascii:send(Out, <<"ERROR\r\n">>),
    {ok, Session}.

% ------------------------------------------

send_response(ascii, Out, _Cmd, Head, Body) ->
    % Downstream is ascii.
    (Out =/= undefined) andalso
    ((Head =/= undefined) andalso
     (ok =:= mc_ascii:send(Out, [Head, <<"\r\n">>]))) andalso
    ((Body =:= undefined) orelse
     (ok =:= mc_ascii:send(Out, [Body#mc_entry.data, <<"\r\n">>])));

send_response(binary, Out, Cmd,
              #mc_header{status = Status,
                         opcode = Opcode} = _Head, Body) ->
    % Downstream is binary.
    case Status =:= ?SUCCESS of
        true ->
            case Opcode of
                ?GETKQ     -> send_entry_binary(Cmd, Out, Body);
                ?GETK      -> send_entry_binary(Cmd, Out, Body);
                ?NOOP      -> mc_ascii:send(Out, <<"END\r\n">>);
                ?INCREMENT -> send_arith_response(Out, Body);
                ?DECREMENT -> send_arith_response(Out, Body);
                _ -> mc_ascii:send(Out, mc_binary:b2a_code(Opcode, Status))
            end;
        false ->
            mc_ascii:send(Out, mc_binary:b2a_code(Opcode, Status))
    end.

send_entry_binary(Cmd, Out, #mc_entry{key = Key, data = Data,
                                      cas = Cas, flag = Flag}) ->
    DataLen = integer_to_list(bin_size(Data)),
    FlagStr = integer_to_list(Flag),
    case Cmd of
        get ->
            ok =:= mc_ascii:send(Out, [<<"VALUE ">>, Key,
                                       <<" ">>, FlagStr, <<" ">>,
                                       DataLen, <<"\r\n">>,
                                       Data, <<"\r\n">>]);
        gets ->
            CasStr = integer_to_list(Cas),
            ok =:= mc_ascii:send(Out, [<<"VALUE ">>, Key,
                                       <<" ">>, FlagStr, <<" ">>,
                                       DataLen, <<" ">>,
                                       CasStr, <<"\r\n">>,
                                       Data, <<"\r\n">>])
    end.

send_arith_response(Out, #mc_entry{data = Data}) ->
    <<Amount:64>> = Data,
    AmountStr = integer_to_list(Amount), % TODO: 64-bit parse issue here?
    ok =:= mc_ascii:send(Out, [AmountStr, <<"\r\n">>]).

kind_to_module(ascii)  -> mc_client_ascii_ac;
kind_to_module(binary) -> mc_client_binary_ac.

bin_size(undefined)               -> 0;
bin_size(List) when is_list(List) -> bin_size(iolist_to_binary(List));
bin_size(Binary)                  -> size(Binary).

