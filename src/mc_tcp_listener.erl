-module (mc_tcp_listener).

-export([start/0, start/1, start_link/0, start_link/1, init/1]).

% Starting the server
start() ->
    start(11211).

start(PortNum) when integer(PortNum) ->
    {ok, spawn(?MODULE, init, [PortNum])}.

start_link() ->
    start_link(11211).

start_link(PortNum) when integer(PortNum) ->
    {ok, spawn_link(?MODULE, init, [PortNum])}.


%
% The server itself
%

% server self-init
init(PortNum) ->
    {ok, LS} = gen_tcp:listen(PortNum, [binary,
                                        {reuseaddr, true},
                                        {packet, raw},
                                        {active, false}]),
    accept_loop(LS).

% Accept incoming connections
accept_loop(LS) ->
    {ok, NS} = gen_tcp:accept(LS),
    Pid = spawn(mc_connection, loop, [NS]),
    gen_tcp:controlling_process(NS, Pid),
    accept_loop(LS).


