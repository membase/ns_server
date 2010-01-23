% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(menelaus_event).

-behaviour(gen_event).

% Allows menelaus erlang processes (especially long-running HTTP /
% REST streaming processes) to register for messages when there
% are configuration changes.

-export([start_link/0]).

-export([watchers/0,
         register_watcher/1,
         unregister_watcher/1]).

%% gen_event callbacks

-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {id, webconfig, watchers = []}).

-include_lib("eunit/include/eunit.hrl").

% Noop process to get initialized in the supervision tree.

start_link() ->
    {ok, spawn_link(fun() ->
                       gen_event:add_handler(ns_config_events,
                                             {?MODULE, ns_config_events},
                                             ns_config_events),
                       gen_event:add_handler(ns_node_disco_events,
                                             {?MODULE, ns_node_disco_events},
                                             ns_node_disco_events)
                    end)}.

watchers() ->
    {gen_event:call(ns_config_events,
                    {?MODULE, ns_config_events}, watchers),
     gen_event:call(ns_node_disco_events,
                    {?MODULE, ns_node_disco_events}, watchers)}.

register_watcher(Pid) ->
    gen_event:call(ns_config_events,
                   {?MODULE, ns_config_events},
                   {register_watcher, Pid}),
    gen_event:call(ns_node_disco_events,
                   {?MODULE, ns_node_disco_events},
                   {register_watcher, Pid}).

unregister_watcher(Pid) ->
    gen_event:call(ns_config_events,
                   {?MODULE, ns_config_events},
                   {unregister_watcher, Pid}),
    gen_event:call(ns_node_disco_events,
                   {?MODULE, ns_node_disco_events},
                   {unregister_watcher, Pid}).

%% Implementation

init(ns_config_events = Id) ->
    {ok, #state{id = Id,
                watchers = [],
                webconfig = menelaus_web:webconfig()}};

init(ns_node_disco_events = Id) ->
    {ok, #state{id = Id,
                watchers = []}}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_event({rest, _}, #state{webconfig = WebConfigOld} = State) ->
    WebConfigNew = menelaus_web:webconfig(),
    case WebConfigNew =:= WebConfigOld of
        true -> {ok, State};
        false -> spawn(fun menelaus_web:restart/0),
                 {ok, State#state{webconfig = WebConfigNew}}
    end;

handle_event({pools, _}, State) ->
    ok = notify_watchers(pools, State),
    {ok, State};

handle_event({nodes_wanted, _}, State) ->
    ok = notify_watchers(nodes_wanted, State),
    {ok, State};

handle_event({ns_node_disco_events, _NodesBefore, _NodesAfter}, State) ->
    ok = notify_watchers(ns_node_disco_events, State),
    {ok, State};

handle_event(_, State) ->
    {ok, State}.

handle_call(watchers, #state{watchers = Watchers} = State) ->
    {ok, Watchers, State};

handle_call({register_watcher, Pid},
            #state{watchers = Watchers} = State) ->
    Watchers2 = case lists:keysearch(Pid, 1, Watchers) of
                    false -> MonitorRef = erlang:monitor(process, Pid),
                             [{Pid, MonitorRef} | Watchers];
                    _     -> Watchers
                end,
    {ok, ok, State#state{watchers = Watchers2}};

handle_call({unregister_watcher, Pid},
            #state{watchers = Watchers} = State) ->
    Watchers2 = case lists:keytake(Pid, 1, Watchers) of
                    false -> Watchers;
                    {value, {Pid, MonitorRef}, WatchersRest} ->
                        erlang:demonitor(MonitorRef, [flush]),
                        WatchersRest
                end,
    {ok, ok, State#state{watchers = Watchers2}};

handle_call(Request, State) ->
    error_logger:info_msg("menelaus_event handle_call(~p, ~p)~n",
                          [Request, State]),
    {ok, ok, State}.

handle_info({'DOWN', MonitorRef, _, _, _},
            #state{watchers = Watchers} = State) ->
    error_logger:info_msg("menelaus_event watcher down."),
    Watchers2 = case lists:keytake(MonitorRef, 2, Watchers) of
                    false -> Watchers;
                    {value, {Pid, MonitorRef}, WatchersRest} ->
                        error_logger:info_msg("menelaus_event watcher down: ~p~n", [Pid]),
                        erlang:demonitor(MonitorRef, [flush]),
                        WatchersRest
                end,
    {ok, State#state{watchers = Watchers2}};

handle_info(Info, State) ->
    error_logger:info_msg("menelaus_event handle_info(~p, ~p)~n",
                          [Info, State]),
    {ok, State}.

% ------------------------------------------------------------

notify_watchers(Msg, #state{watchers = Watchers}) ->
    error_logger:info_msg("menelaus_event: notify_watchers: ~p~n", [Msg]),
    lists:foreach(fun({Pid, _}) ->
                          Pid ! {notify_watcher, Msg}
                  end,
                  Watchers),
    ok.
