-module(mc_downstream).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

%% API for downstream.

monitor(Addr) ->
    ?debugFmt("mcd.monitor ~p~n", [Addr]),
    todo.

demonitor(Addr) ->
    ?debugFmt("mcd.demonitor ~p~n", [Addr]),
    todo.

send(Addr, Op, NotifyPid, NotifyData, ResponseFun,
     CmdModule, Cmd, CmdArgs) ->
    ?debugFmt("mcd.send ~p ~p ~p ~p ~p ~p ~p ~p~n",
              [Addr, Op, NotifyPid, NotifyData, ResponseFun,
               CmdModule, Cmd, CmdArgs]),
    todo.

% Note, this can be a child/worker in a supervision tree.

start_link(Addr) ->
    Location = mc_addr:location(Addr),
    [Host, Port] = string:tokens(Location, ":"),
    PortNum = list_to_integer(Port),
    {ok, Sock} = gen_tcp:connect(Host, PortNum,
                                 [binary, {packet, 0}, {active, false}]),
    % TODO: Auth.
    % TODO: Bucket selection.
    % TODO: Protocol capability test (binary or ascii).
    {ok, spawn_link(?MODULE, loop, [Addr, Sock])}.

loop(Addr, Sock) ->
    receive
        {fwd, NotifyPid, NotifyData, ResponseFun,
              CmdModule, Cmd, CmdArgs} ->
            RV = apply(CmdModule, Cmd, [Sock, ResponseFun, CmdArgs]),
            notify(NotifyPid, {RV, nil, NotifyData}),
            case RV of
                true  -> loop(Addr, Sock);
                false -> gen_tcp:close(Sock)
            end;
        {close, NotifyPid, NotifyData} ->
            gen_tcp:close(Sock),
            notify(NotifyPid, {false, "downstream closed", NotifyData})
    end.

notify(P, V) when is_pid(P) -> P ! V;
notify(_, _) -> ok.
