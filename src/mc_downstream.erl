-module(mc_downstream).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

%% API for downstream.

monitor(Addr, CallerPid, SomeFlag) ->
    ?debugFmt("mcd.monitor ~p ~p ~p~n", [Addr, CallerPid, SomeFlag]),
    todo.

send(Addr, CallerPid, ErrMsg, SendCmd, CallerPid2, ResponseFilter,
     ClientProtocolModule, Cmd, CmdArgs, NotifyData) ->
    ?debugFmt("mcd.send ~p ~p ~p ~p ~p ~p ~p ~p ~p ~p~n",
              [Addr, CallerPid,
               ErrMsg, SendCmd, CallerPid2, ResponseFilter,
               ClientProtocolModule, Cmd, CmdArgs, NotifyData]),
    todo.

% Note, this can be a child/worker in a supervision tree.

start_link(#mc_addr{location = Location} = Addr) ->
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
        {fwd} ->
            loop(Addr, Sock);
        {close} ->
            ok
    end.
