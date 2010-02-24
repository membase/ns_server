-module(mc_downstream_conn).

-export([start_link/2, init/3]).

start_link(Addr, Timeout) ->
    proc_lib:start_link(?MODULE, init, [self(), Addr, Timeout]).

init(Parent, Addr, Timeout) ->
    Location = mc_addr:location(Addr),
    [Host, Port | _] = string:tokens(Location, ":"),
    PortNum = list_to_integer(Port),
    {ok, Sock} = gen_tcp:connect(Host, PortNum,
                                 [binary, {packet, 0}, {active, false}]),
    proc_lib:init_ack(Parent, {ok, self()}),
    worker(Addr, Sock, Timeout).

%% Child/worker process implementation, where we have one child/worker
%% process per downstream Addr or MBox.  Note, this can one day be a
%% child/worker in a supervision tree.

worker(Addr, Sock, Timeout) ->
    case mc_addr:kind(Addr) of
        ascii  -> loop(Addr, Sock, Timeout);
        binary ->
            %% TODO: Need a way to prevent auth & re-auth storms.
            %% TODO: Bucket selection, one day.
            %%
            Auth = mc_addr:auth(Addr),
            case mc_client_binary:auth(Sock, Auth) of
                ok  -> loop(Addr, Sock, Timeout);
                Err -> gen_tcp:close(Sock),
                       ns_log:log(?MODULE, 1, "auth failed: ~p with ~p",
                                  [Err, Auth])
            end
    end.

loop(Addr, Sock, Timeout) ->
    inet:setopts(Sock, [{active, once}]),
    receive
        {send, NotifyPid, NotifyData, ResponseFun,
               CmdModule, Cmd, CmdArgs} ->
            inet:setopts(Sock, [{active, false}]),
            RV = CmdModule:cmd(Cmd, Sock, ResponseFun, undefined, CmdArgs),
            notify(NotifyPid, NotifyData, RV),
            case RV of
                {ok, _}       -> loop(Addr, Sock, Timeout);
                {ok, _, _}    -> loop(Addr, Sock, Timeout);
                {ok, _, _, _} -> loop(Addr, Sock, Timeout);
                _Error        -> gen_tcp:close(Sock)
            end;
        {tcp_closed, Sock} -> ok;
        Other ->
            gen_tcp:close(Sock),
            error_logger:info_msg("Unhandled message:  ~p~n", [Other])
    after Timeout ->
        gen_tcp:close(Sock)
    end.

notify(P, D, V) when is_pid(P) -> P ! {D, V};
notify(_, _, _)                -> ok.
