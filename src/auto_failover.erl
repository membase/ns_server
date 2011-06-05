%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

%% @doc Does auto failover nodes that are down.
%% It works like that: You specify a certain time interval (age) a node
%% must be down, before it will be auto-failovered. There's also a
%% maximum number of nodes that may be auto-failovered. Whenever a node
%% gets auto-failovered a counter is increased by one. Once the counter
%% has reached the maximum number of nodes that may be auto-failovered
%% the user will only get a notification that there was a node that would
%% have been auto-failovered if the maximum wouldn't have been reached.

-module(auto_failover).

-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/0, enable/2, disable/0, reset_count/0]).
%% For email alert notificatons
-export([alert_key/1, alert_keys/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, {global, ?MODULE}).
%% @doc Fired when a node was auto-failovered.
-define(EVENT_NODE_AUTO_FAILOVERED, 1).
%% @doc Fired when the maximum number of nodes that can be auto-failovered
%% was reached (and thus the auto-failover was disabled).
-define(EVENT_MAX_REACHED, 2).

-record(state, {
          % The nodes that are currently consideren to be down. It's a list
          % of a three-tuple that conists of the node ID, the timestamp
          % when it was first considered down and whether the nodes was
          % tried to auto-failover or not (this info is needed to be able
          % to send out notices about nodes that would be auto-failovered
          % when the maximum wouldn't have been reached yet).
          nodes_down=[] :: [{atom(), integer(), boolean()}],
          % Reference to the ns_tick_event. If it is nil, auto-failover is
          % disabled.
          tick_ref=nil :: nil|reference(),
          % Time a node needs to be down until it is automatically failovered
          age=nil :: nil|integer(),
          % The maximum number of nodes that should get automatically
          % failovered
          max_nodes=1 :: integer(),
          % Counts the number of nodes that were already auto-failovered
          count=0 :: integer()
         }).

%%
%% API
%%

start_link() ->
    misc:start_singleton(gen_server, ?MODULE, [], []).

%% @doc Enable auto-failover. Failover after a certain time (in seconds),
%% Returns an error (and reason) if it couldn't be enabled, e.g. because
%% not all nodes in the cluster were healthy.
%% `Age` is the number of seconds a node must be down before it will be
%% automatically failovered
%% `Max` is the maximum number of nodes that can will be automatically
%% failovered
-spec enable(Age::integer(), Max::integer()) -> ok|{error, unhealthy}.
enable(Age, Max) ->
    gen_server:call(?SERVER, {enable_auto_failover, Age, Max}).

%% @doc Disable auto-failover
-spec disable() -> ok.
disable() ->
    gen_server:call(?SERVER, disable_auto_failover).

%% @doc Reset the number of nodes that were auto-failovered to zero
-spec reset_count() -> ok.
reset_count() ->
    gen_server:call(?SERVER, reset_auto_failover_count).

-spec alert_key(Code::integer()) -> atom().
alert_key(?EVENT_NODE_AUTO_FAILOVERED) -> auto_failover_node;
alert_key(?EVENT_MAX_REACHED) -> auto_failover_maximum_reached;
alert_key(_) -> all.

%% @doc Returns a list of all alerts that might send out an email notfication.
-spec alert_keys() -> [atom()].
alert_keys() ->
    [auto_failover_node,
     auto_failover_maximum_reached,
     auto_failover_too_many_nodes_down].

%%
%% gen_server callbacks
%%

init([]) ->
    {value, Config} = ns_config:search(ns_config:get(), auto_failover),
    ?log_info("init auto_failover.", []),
    Age = proplists:get_value(age, Config),
    Max = proplists:get_value(max_nodes, Config),
    Count = proplists:get_value(count, Config),
    State = #state{age=Age, max_nodes=Max, count=Count},
    case proplists:get_value(enabled, Config) of
        true ->
            {reply, ok, State2} = handle_call({enable_auto_failover, Age, Max},
                                              self(), State),
            {ok, State2};
        false ->
            {ok, State}
    end.

%% @doc Auto-failover isn't enabled yet (tick_ref isn't set).
handle_call({enable_auto_failover, Age, Max}, _From, 
            #state{tick_ref=nil}=State) ->
    ?log_info("enable auto-failover: ~p", [State]),
    Ref = ns_pubsub:subscribe(ns_tick_event),
    State2 = State#state{tick_ref=Ref, age=Age, max_nodes=Max},
    make_state_persistent(State2),
    {reply, ok, State2};
%% @doc Auto-failover is already enabled, just update the settings.
handle_call({enable_auto_failover, Age, Max}, _From, State) ->
    ?log_info("updating auto-failover settings: ~p", [State]),
    State2 = State#state{age=Age, max_nodes=Max},
    make_state_persistent(State2),
    {reply, ok, State2};

handle_call(disable_auto_failover, _From, #state{tick_ref=Ref}=State) ->
    ?log_info("disable_auto_failover: ~p", [State]),
    ns_pubsub:unsubscribe(ns_tick_event, Ref),
    State2 = State#state{tick_ref=nil},
    make_state_persistent(State2),
    {reply, ok, State2};

handle_call(reset_auto_failover_count, _From, State) ->
    ?log_info("reset auto_failover count: ~p", [State]),
    State2 = State#state{count=0,nodes_down=[]},
    make_state_persistent(State2),
    {reply, ok, State2};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% @doc Check if nodes should/could be auto-failovered on every tick
handle_info({tick, TS}, State) ->
    CurrentlyDown = actual_down_nodes(),
    % Failover all nodes that are down for a certain amount of time.
    % Send out a notice when the when the maximum number of nodes that can
    % be auto-failovered is reached.
    State2 = failover_nodes(CurrentlyDown, TS, State),
    case State2#state.count =/= State#state.count of
        true -> make_state_persistent(State2);
        false -> ok
    end,
    {noreply, State2};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%
%% Internal functions
%%

%% @doc Failover a node. `Max` is the number of nodes that can be
%% auto-failovered at most, `Count` is the current number of nodes
%% that were already auto-failovered.
-spec failover(Node::atom(), Count::integer(), Max::integer()) ->
                  ok|{error, maximum_reached}.
failover(Node, Count, Max) ->
    % Only failover if the maximum number of nodes that
    % will be automatically failovered isn't reached yet
    case Count < Max of
        true ->
            ns_cluster_membership:failover(Node),
            ns_log:log(?MODULE, ?EVENT_NODE_AUTO_FAILOVERED,
                       "Node (~p) was automatically failovered.~n", [Node]),
            ok;
        false ->
            ns_log:log(?MODULE, ?EVENT_MAX_REACHED,
                       "Could not auto-failover node (~p). "
                       "Maximum number of nodes that will be "
                       "automatically failovered (~p) is reached.~n",
                       [Node, Max]),
            {error, maximum_reached}
    end.

%% @doc Loop through all nodes that are currently down and failovers a node
%% if it was down long enough and the maximum number of nodes that may be
%% auto-failovered isn't reached yet.
%% `CurrentlyDown` are the nodes that are down at the current tick
%% `ConsideredDown` are the nodes that were down on the last tick
%% `TS` is the timestamp of the current tick
%% `State` the current state of the gen_server
%% Returns a new state that contains an updated count and an updated list of
%% nodes that are currently down
-spec failover_nodes(CurrentlyDown::[atom()], TS::integer(),
                     State::#state{}) -> #state{}.
failover_nodes(CurrentlyDown, TS, State) ->
    failover_nodes(CurrentlyDown, TS, State, []).

-spec failover_nodes(CurrentlyDown::[atom()], TS::integer(),
                     State::#state{}, Acc::[{atom(), integer(), boolean()}]) ->
                        #state{}.
failover_nodes([], _TS, State, Acc) ->
    State#state{nodes_down=lists:reverse(Acc)};
failover_nodes([Node|Rest], TS,
               #state{nodes_down=ConsideredDown, max_nodes=Max,
                      count=Count}=State, Acc) ->
    case lists:keyfind(Node, 1, ConsideredDown) of
        % Node wasn't considered as down yet, add it to the list.
        false ->
            failover_nodes(Rest, TS, State, [{Node, TS, false}|Acc]);
        % Node was already down in the last tick, but might not have been
        % down longer than the specified time span (age)
        {Node, DownTs, IsAlreadyAutoFailovered} ->
            % Check for how long this node is down already.
            % is_node_down doesn't change the state.
            DownForLong = is_node_down(Node, State),
            % The count is only increased if the node was really failovered
            Count2 = case DownForLong and not IsAlreadyAutoFailovered of
                true ->
                    case failover(Node, Count, Max) of
                        ok -> Count+1;
                        {error, maximum_reached} -> Count
                    end;
                _ ->
                    Count
            end,
            % DownForLong can be used as third tuple element as every node
            % that was down for a long enough time span was definitely tried
            % to be auto-failovered.
            failover_nodes(Rest, TS, State#state{count=Count2},
                           [{Node, DownTs, DownForLong}|Acc])
    end.

%% @doc Returns a list of nodes that should be active, but are not running.
-spec actual_down_nodes() -> [atom()].
actual_down_nodes() ->
    Active = ns_cluster_membership:active_nodes(),
    Actual = ns_cluster_membership:actual_active_nodes(),
    lists:subtract(Active, Actual).

%% @doc Returns true if the node is down longer than the configured time span.
-spec is_node_down(Node::atom(), State::#state{}) -> true|false.
is_node_down(Node, #state{nodes_down=ConsideredDown, age=Age}) ->
    {Node, DownTime, _} = lists:keyfind(Node, 1, ConsideredDown),
    Now = ns_tick:time(),
    (DownTime + Age*1000) < Now.

%% @doc Save the current state in ns_config
-spec make_state_persistent(State::#state{}) -> ok.
make_state_persistent(State) ->
    Enabled = case State#state.tick_ref of
        nil -> false;
        _ -> true
    end,
    ns_config:set(auto_failover, [{enabled, Enabled},
                                  {age, State#state.age},
                                  {max_nodes, State#state.max_nodes},
                                  {count, State#state.count}]).
