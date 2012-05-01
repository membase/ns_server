-module (mc_tcp_listener).

-export([start_link/1, init/1]).

-include("ns_common.hrl").

% Starting the server

start_link(PortNum) ->
    proc_lib:start_link(?MODULE, init, [PortNum]).

%
% The server itself
%

% server self-init
init(PortNum) ->
    {ok, LS} = gen_tcp:listen(PortNum, [binary,
                                        {reuseaddr, true},
                                        {packet, raw},
                                        {active, false}]),
    ?log_info("mccouch is listening on port ~p", [PortNum]),
    proc_lib:init_ack({ok, self()}),
    accept_loop(LS).

% Accept incoming connections
accept_loop(LS) ->
    {ok, NS} = gen_tcp:accept(LS),
    ?log_debug("Got new connection"),
    Pid = mc_conn_sup:start_connection(NS),
    ?log_debug("Passed connection to mc_conn_sup: ~p", [Pid]),
    accept_loop(LS).
