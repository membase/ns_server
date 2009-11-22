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

group_by(_Keys, _KeyFunc) ->
    [].

a2x_forward(Addr, Cmd, Out, CmdNum, CmdArgs) ->
    a2x_forward(Addr, Cmd, Out, CmdNum, CmdArgs,
                undefined, undefined).

a2x_forward(Addr, Cmd, Out, CmdNum, CmdArgs,
            ResponseFilter, NotifyData) ->
    ResponseFun =
        fun (Head, Body) ->
            case ((ResponseFilter =:= undefined) orelse
                  (ResponseFilter(Head, Body))) of
                true ->
                    a2x_send_response_from(Addr, Cmd, Out, CmdNum, CmdArgs,
                                           Head, Body);
                false -> true
            end
        end,
    ok = mc_downstream:monitor(Addr, self(), false),
    ok = mc_downstream:send(Addr, self(),
                            { false, "missing downstream", NotifyData },
                            fwd, self(), ResponseFilter,
                            mc_client_binary, Cmd, CmdArgs, NotifyData),
    true.

a2x_send_response_from(ascii, Cmd, Out, CmdNum, CmdArgs, Head, Body) ->
    % Downstream is ascii.
    Out =/= undefined andalso
    (Head =/= undefined andalso
     mc_ascii:send(Out, CmdNum, [Head, <<"\r\n">>])) andalso
    (Body =:= undefined orelse
     mc_ascii:send(Out, CmdNum, [Body#mc_entry.data, <<"\r\n">>]));

a2x_send_response_from(binary, Cmd, Out, CmdNum, CmdArgs,
                       #mc_header{statusOrReserved = Status,
                                  opcode = Opcode} = Head, Body) ->
    case Status =:= ?SUCCESS of
        true ->
            case Opcode of
                ?GETKQ -> a2x_send_entry_from_binary(Out, CmdNum, Body);
                ?GETK  -> a2x_send_entry_from_binary(Out, CmdNum, Body);
                ?NOOP  -> mc_ascii:send(Out, CmdNum, <<"END\r\n">>);
                _ -> mc_ascii:send(Out, CmdNum, binary_success(Opcode))
            end;
        false ->
            mc_ascii:send(Out, CmdNum, [<<"ERROR ">>,
                                        Body#mc_entry.data,
                                        <<"\r\n">>])
    end;

a2x_send_response_from(Addr, Cmd, Out, CmdNum, CmdArgs, Head, Body) ->
    a2x_send_response_from(mc_downstream:kind(Addr),
                           Cmd, Out, CmdNum, CmdArgs, Head, Body).

a2x_send_entry_from_binary(Out, CmdNum,
                           #mc_entry{key = Key, data = Data} = Body) ->
    DataLen = integer_to_list(bin_size(Data)),
    ok =:= mc_ascii:send(Out, CmdNum,
                         [<<"VALUE ">>, Key,
                          <<" 0 ">>, % TODO: Flag and Cas.
                          DataLen, <<"\r\n">>,
                          Data, <<"\r\n">>]).

bin_size(undefined) -> 0;
bin_size(List) when is_list(List) -> bin_size(iolist_to_binary(List));
bin_size(Binary) -> size(Binary).

binary_success(?SET)    -> <<"STORED\r\n">>;
binary_success(?NOOP)   -> <<"END\r\n">>;
binary_success(?DELETE) -> <<"DELETED\r\n">>;
binary_success(_)       -> <<"OK\r\n">>.

% ------------------------------------------

cmd(get, #session_proxy{bucket = Bucket} = Session,
    _InSock, Out, CmdNum, Keys) ->
    Groups =
        group_by(Keys,
                 fun (Key) -> {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
                              Addr
                 end),
    % Out ! {expect, CmdNum, length(Groups)},
    NumFwd = lists:foldl(fun ({Addr, AddrKeys}, Acc) ->
                             case a2x_forward(Addr, get, Out, CmdNum,
                                              AddrKeys) of
                                 true  -> Acc + 1;
                                 false -> Acc
                             end
                         end,
                         0, Groups),
    NumFwd,
    % Out ! {expect, CmdNum, NumFwd, <<"END\r\n">>},
    {ok, Session};

cmd(set, Session, InSock, Out, CmdNum, CmdArgs) ->
    forward_update(set, Session, InSock, Out, CmdNum, CmdArgs);
cmd(add, Session, InSock, Out, CmdNum, CmdArgs) ->
    forward_update(add, Session, InSock, Out, CmdNum, CmdArgs);
cmd(replace, Session, InSock, Out, CmdNum, CmdArgs) ->
    forward_update(replace, Session, InSock, Out, CmdNum, CmdArgs);
cmd(append, Session, InSock, Out, CmdNum, CmdArgs) ->
    forward_update(append, Session, InSock, Out, CmdNum, CmdArgs);
cmd(prepend, Session, InSock, Out, CmdNum, CmdArgs) ->
    forward_update(prepend, Session, InSock, Out, CmdNum, CmdArgs);

cmd(quit, _Session, _InSock, _Out, _CmdNum, _Rest) ->
    exit({ok, quit_received}).

% ------------------------------------------

forward_update(Cmd, #session_proxy{bucket = Bucket} = Session,
               InSock, Out, CmdNum,
               [Key, FlagIn, ExpireIn, DataLenIn]) ->
    Flag = list_to_integer(FlagIn),
    Expire = list_to_integer(ExpireIn),
    DataLen = list_to_integer(DataLenIn),
    {ok, DataCRNL} = mc_ascii:recv_data(InSock, DataLen + 2),
    {Data, _} = mc_ascii:split_binary_suffix(DataCRNL, 2),
    {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
    Entry = #mc_entry{key = Key, flag = Flag, expire = Expire, data = Data},
    ok = a2x_forward(Addr, Cmd, Out, CmdNum, Entry),
    {ok, Session}.

forward_arith(Cmd, #session_proxy{bucket = Bucket} = Session,
               InSock, Out, CmdNum,
               [Key, AmountIn]) ->
    Amount = list_to_integer(AmountIn),
    {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
    Entry = #mc_entry{key = Key, data = Amount},
    ok = a2x_forward(Addr, Cmd, Out, CmdNum, Entry),
    {ok, Session}.

% ------------------------------------------

% For testing...
%
main() ->
    mc_main:start(11222,
                  {mc_server_ascii,
                   {mc_server_ascii_proxy, mc_pool:create()}}).

