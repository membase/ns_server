% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_port_init).

-behaviour(gen_event).

-export([start_link/0, reconfig/1]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

% Noop process to get initialized in the supervision tree.
start_link() ->
    {ok, spawn_link(fun() ->
                       gen_event:add_handler(ns_config_events, ?MODULE, ignored)
                    end)}.

init(ignored) ->
    {ok, #state{}, hibernate}.

handle_event(_Event, State) ->
    {value, PortServers} = ns_port_sup:port_servers_config(),
    ok = reconfig(PortServers),
    {ok, State, hibernate}.

handle_call(_Request, State) ->
    {ok, ok, State, hibernate}.

handle_info(Info, State) ->
    error_logger:info_msg("ns_port_init unhandled message: ~p...~n", [Info]),
    {ok, State, hibernate}.

terminate(Reason, _State) ->
    error_logger:info_msg("ns_port_init terminating: ~p...~n", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

reconfig(_PortServers) ->
    {value, PortServers} = ns_port_sup:port_servers_config(),
    error_logger:info_msg("ns_port_init reconfig ports: ~p...~n",
                          [PortServers]),

    % CurrPorts looks like...
    %   [{memcached,<0.77.0>,worker,[ns_port_server]}]
    % Or, if the child process went down, then...
    %   [{memcached,undefined,worker,[ns_port_server]}]
    %
    PortParams = [ns_port_sup:expand_args(NCAO) || NCAO <- PortServers],
    CurrPortParams = ns_port_sup:current_ports(),
    OldPortParams = lists:subtract(CurrPortParams, PortParams),
    NewPortParams = lists:subtract(PortParams, CurrPortParams),

    lists:foreach(fun(NCAO) ->
                      ns_port_sup:terminate_port(NCAO)
                  end,
                  OldPortParams),
    lists:foreach(fun({Name, Cmd, Args, Opts}) ->
                      ns_port_sup:launch_port(Name, Cmd, Args, Opts)
                  end,
                  NewPortParams),
    ok.
