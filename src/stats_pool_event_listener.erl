% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(stats_pool_event_listener).

-behaviour(gen_event).

-export([start_link/0, setup_handler/0]).

-export([monitor_all/0, unmonitor_all/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {servers}).

start_link() ->
    exit(unimplemented).

setup_handler() ->
    {ok, Servers} = monitor_all(),
    gen_event:add_sup_handler(ns_config_events, ?MODULE, [Servers]).

init([Servers]) ->
    {ok, #state{servers=Servers}, hibernate}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_event({pools, _V}, State) ->
    Prev = State#state.servers,
    {Buckets, Servers} = get_buckets_and_servers(),
    lists:foreach(fun ({H, P}) ->
                          stats_collector:unmonitor(H, P)
                  end, Servers -- Prev),
    monitor(Servers, Buckets),
    {ok, #state{servers=Servers}, hibernate};
handle_event(_, State) ->
    {ok, State, hibernate}.

handle_call(Request, State) ->
    error_logger:info_msg("handle_call(~p, ~p)~n", [Request, State]),
    {ok, ok, State, hibernate}.

handle_info(Info, State) ->
    error_logger:info_msg("handle_info(~p, ~p)~n", [Info, State]),
    {ok, State, hibernate}.

monitor(Servers, Buckets) ->
    % Assuming all servers run all buckets.
    lists:foreach(fun({H, P}) ->
                          stats_collector:monitor(H, P, Buckets)
                  end,
                  Servers).

unmonitor(Servers) ->
    lists:foreach(fun ({H, P}) ->
                          stats_collector:unmonitor(H, P)
                  end, Servers).

get_buckets_and_servers() ->
    [Pool | []] = mc_pool:list(), % assume one pool
    Buckets = mc_bucket:list(Pool),
    Servers = lists:usort(lists:flatmap(fun(B) -> bucket_servers(Pool, B)
                                        end, Buckets)),
    {Buckets, Servers}.

bucket_servers(Pool, B) ->
    lists:map(fun({mc_addr, HP, _K, _A}) ->
                      [H, P] = string:tokens(HP, ":"),
                      {I, []} = string:to_integer(P),
                      {H, I}
              end,
              mc_bucket:addrs(Pool, B)).

monitor_all() ->
    {Buckets, Servers} = get_buckets_and_servers(),
    monitor(Servers, Buckets),
    {ok, Servers}.

unmonitor_all() ->
    {_Buckets, Servers} = get_buckets_and_servers(),
    unmonitor(Servers),
    {ok, Servers}.
