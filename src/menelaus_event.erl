%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(menelaus_event).

-behaviour(gen_event).

% Allows menelaus erlang processes (especially long-running HTTP /
% REST streaming processes) to register for messages when there
% are configuration changes.

-export([start_link/0]).

-export([register_watcher/1,
         unregister_watcher/1]).

%% gen_event callbacks

-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {webconfig, watchers = []}).

-include_lib("eunit/include/eunit.hrl").
-include("ns_common.hrl").

% Noop process to get initialized in the supervision tree.

start_link() ->
    misc:start_event_link(fun () ->
                                  gen_event:add_sup_handler(ns_config_events,
                                                            {?MODULE, ns_config_events},
                                                            ns_config_events),
                                  gen_event:add_sup_handler(ns_node_disco_events,
                                                            {?MODULE, ns_node_disco_events},
                                                            simple_events_handler),
                                  gen_event:add_sup_handler(buckets_events,
                                                            {?MODULE, buckets_events},
                                                            simple_events_handler)
                          end).

register_watcher(Pid) ->
    gen_event:call(ns_config_events,
                   {?MODULE, ns_config_events},
                   {register_watcher, Pid}),
    gen_event:call(ns_node_disco_events,
                   {?MODULE, ns_node_disco_events},
                   {register_watcher, Pid}),
    gen_event:call(buckets_events,
                   {?MODULE, buckets_events},
                   {register_watcher, Pid}).

unregister_watcher(Pid) ->
    gen_event:call(ns_config_events,
                   {?MODULE, ns_config_events},
                   {unregister_watcher, Pid}),
    gen_event:call(ns_node_disco_events,
                   {?MODULE, ns_node_disco_events},
                   {unregister_watcher, Pid}),
    gen_event:call(buckets_events,
                   {?MODULE, buckets_events},
                   {unregister_watcher, Pid}).

%% Implementation

init(ns_config_events) ->
    {ok, #state{watchers = [],
                webconfig = menelaus_web:webconfig()}};

init(_) ->
    {ok, #state{watchers = []}}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_event({{node, Node, rest}, _}, State) when Node =:= node() ->
    NewState = maybe_restart(State),
    {ok, NewState};

handle_event({rest, _}, State) ->
    NewState = maybe_restart(State),
    {ok, NewState};

handle_event({significant_buckets_change, _}, State) ->
    ok = notify_watchers(significant_buckets_change, State),
    {ok, State};

handle_event({memcached, _}, State) ->
    ok = notify_watchers(memcached, State),
    {ok, State};

handle_event({{node, _, memcached}, _}, State) ->
    ok = notify_watchers(memcached, State),
    {ok, State};

handle_event({rebalance_status, _}, State) ->
    ok = notify_watchers(rebalance_status, State),
    {ok, State};

handle_event({buckets, _}, State) ->
    ok = notify_watchers(buckets, State),
    {ok, State};

handle_event({nodes_wanted, _}, State) ->
    ok = notify_watchers(nodes_wanted, State),
    {ok, State};

handle_event({ns_node_disco_events, _NodesBefore, _NodesAfter}, State) ->
    ok = notify_watchers(ns_node_disco_events, State),
    {ok, State};

handle_event(_, State) ->
    {ok, State}.

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
    ?log_warning("Unexpected handle_call(~p, ~p)", [Request, State]),
    {ok, ok, State}.

handle_info({'DOWN', MonitorRef, _, _, _},
            #state{watchers = Watchers} = State) ->
    Watchers2 = case lists:keytake(MonitorRef, 2, Watchers) of
                    false -> Watchers;
                    {value, {_Pid, MonitorRef}, WatchersRest} ->
                        erlang:demonitor(MonitorRef, [flush]),
                        WatchersRest
                end,
    {ok, State#state{watchers = Watchers2}};

handle_info(_Info, State) ->
    {ok, State}.

% ------------------------------------------------------------

notify_watchers(Msg, #state{watchers = Watchers}) ->
    lists:foreach(fun({Pid, _}) ->
                          Pid ! {notify_watcher, Msg}
                  end,
                  Watchers),
    ok.

maybe_restart(#state{webconfig=WebConfigOld} = State) ->
    WebConfigNew = menelaus_web:webconfig(),
    case WebConfigNew =:= WebConfigOld of
        true -> State;
        false -> spawn(fun menelaus_web:restart/0),
                 State#state{webconfig=WebConfigNew}
    end.
