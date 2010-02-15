% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(mc_pool_init).

-behaviour(gen_event).

-export([start_link/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

-include_lib("eunit/include/eunit.hrl").

% Noop process to get initialized in the supervision tree.
start_link() ->
    {ok, spawn_link(fun() ->
                       gen_event:add_handler(ns_config_events,
                                             ?MODULE,
                                             ns_config_events),
                       gen_event:add_handler(ns_node_disco_events,
                                             ?MODULE,
                                             ns_node_disco_events)
                    end)}.

init(Why) ->
    error_logger:info_msg("mc_pool_init: init: ~p~n", [Why]),
    % Have one explict reconfig_pools on init.  We don't have to
    % reconfig_nodes, since reconfig_pools picks up the latest nodes.
    reconfig_pools(mc_pool:pools_config_get()),
    {ok, #state{}, hibernate}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

% With {pools, PropList}, the PropList looks like:
%
%  [{"default", [
%     {port, 11211},
%     {buckets, [
%       {"default", [
%         {auth_plain, undefined},
%         {size_per_node, 64} % In MB.
%       ]}
%     ]}
%   ]}]

handle_event({pools, PropList}, State) ->
    error_logger:info_msg("mc_pool_init: pools changed~n"),
    ok = reconfig_pools(PropList),
    {ok, State, hibernate};

handle_event({nodes_wanted, _}, State) ->
    error_logger:info_msg("mc_pool_init: nodes_wanted changed~n"),
    ok = reconfig_nodes(ns_node_disco:nodes_actual_proper()),
    {ok, State, hibernate};

handle_event({ns_node_disco_events, _NodesBefore, NodesAfter}, State) ->
    error_logger:info_msg("mc_pool_init: ns_node_disco_events: ~p~n",
                          [NodesAfter]),
    ok = reconfig_nodes(NodesAfter),
    {ok, State, hibernate};

handle_event(_, State) ->
    {ok, State, hibernate}.

handle_call(Request, State) ->
    error_logger:info_msg("mc_pool_init handle_call(~p, ~p)~n",
                          [Request, State]),
    {ok, ok, State, hibernate}.

handle_info(Info, State) ->
    error_logger:info_msg("mc_pool_init handle_info(~p, ~p)~n",
                          [Info, State]),
    {ok, State, hibernate}.

% ------------------------------------------------------------

reconfig_pools(false) -> false;

reconfig_pools(Pools) ->
    error_logger:info_msg("mc_pool_init reconfig: ~p~n", [Pools]),

    WantPoolNames = proplists:get_keys(Pools),
    CurrPoolNames = emoxi_sup:current_pools(),

    OldPoolNames = lists:subtract(CurrPoolNames, WantPoolNames),
    NewPoolNames = lists:subtract(WantPoolNames, CurrPoolNames),
    SamePoolNames = lists:subtract(CurrPoolNames, OldPoolNames),

    lists:foreach(fun(Name) -> emoxi_sup:stop_pool(Name) end,
                  OldPoolNames),
    lists:foreach(fun(Name) -> emoxi_sup:start_pool(Name) end,
                  NewPoolNames),
    lists:foreach(fun(Name) -> mc_pool_sup:reconfig(Name) end,
                  SamePoolNames),
    ok.

reconfig_nodes(NodesAfter) ->
    error_logger:info_msg("mc_pool_init: nodes changed: ~p~n",
                          [NodesAfter]),
    lists:foreach(fun(Name) ->
                          mc_pool_sup:reconfig_nodes(Name, NodesAfter)
                  end,
                  emoxi_sup:current_pools()),
    ok.
