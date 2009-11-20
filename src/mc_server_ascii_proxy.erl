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

a2x_forward(_, _, _, _) ->
    true.

cmd(get, #session_proxy{bucket = Bucket} = SessData,
    _InSock, Out, CmdNum, Keys) ->
    Groups =
        group_by(Keys,
                 fun (Key) -> {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
                              Addr
                 end),
    % Out ! {expect, CmdNum, length(Groups)},
    NumFwd = lists:foldl(fun ({Addr, AddrKeys}, Acc) ->
                             case a2x_forward(Addr, Out, CmdNum,
                                              AddrKeys) of
                                 true  -> Acc + 1;
                                 false -> Acc
                             end
                         end,
                         0, Groups),
    NumFwd,
    % Out ! {expect, CmdNum, NumFwd, <<"END\r\n">>},
    {ok, SessData};

cmd(set, SessData,
    InSock, Out, CmdNum, [Key, FlagIn, ExpireIn, DataLenIn]) ->
    Flag = list_to_integer(FlagIn),
    Expire = list_to_integer(ExpireIn),
    DataLen = list_to_integer(DataLenIn),
    {ok, DataCRNL} = mc_ascii:recv_data(InSock, DataLen + 2),
    {Data, _} = mc_ascii:split_binary_suffix(DataCRNL, 2),
    save, Key, Flag, Expire, Data,
    todo,
    mc_ascii:send(Out, CmdNum, <<"STORED\r\n">>),
    {ok, SessData};

cmd(quit, _SessData, _InSock, _Out, _CmdNum, _Rest) ->
    exit({ok, quit_received}).

% ------------------------------------------

% For testing...
%
main() ->
    mc_main:start(11222,
                  {mc_server_ascii,
                   {mc_server_ascii_proxy, mc_pool:create()}}).

