% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.


-module(ns_port_init).

-behaviour(gen_event).

-export([start_link/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).
-include("test/ns_port_init_test.erl").
-endif.

% Noop process to get initialized in the supervision tree.
start_link() ->
    {ok, spawn_link(fun() ->
                       gen_event:add_handler(ns_config_events, ?MODULE, ignored)
                    end)}.

init(ignored) ->
    {ok, #state{}, hibernate}.

handle_event({port_servers, List}, State) ->
    error_logger:info_msg("Changing port servers: ~p...~n", [List]),

    % CurrPorts looks like...
    %   [{memcached,<0.77.0>,worker,[ns_port_server]}]
    % Or, if the child process went down, then...
    %   [{memcached,undefined,worker,[ns_port_server]}]
    %
    CurrPorts = ns_port_sup:current_ports(),
    CurrPortParams = lists:map(fun({_Name, Pid, _, _}) ->
                                   {ok, Params} = ns_port_server:params(Pid),
                                   Params
                               end,
                               CurrPorts),
    OldPortParams = lists:subtract(CurrPortParams, List),
    NewPortParams = lists:subtract(List, CurrPortParams),

    lists:foreach(fun({Name, _Cmd, _Args, _Opts}) ->
                      ns_port_sup:terminate_port(Name)
                  end,
                  OldPortParams),
    lists:foreach(fun({Name, Cmd, Args, Opts}) ->
                      ns_port_sup:launch_port(Name, Cmd, Args, Opts)
                  end,
                  NewPortParams),

    {ok, State, hibernate};

handle_event(_Stuff, State) ->
    {ok, State, hibernate}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State, hibernate}.

handle_info(Info, State) ->
    error_logger:info_msg("Unhandled port init message: ~p...~n", [Info]),
    {ok, State, hibernate}.

terminate(Reason, _State) ->
    error_logger:info_msg("ns_port_init terminating: ~p...~n", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

