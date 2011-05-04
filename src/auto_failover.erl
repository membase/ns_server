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
%% @doc Does auto failover nodes that are down
%%
-module(auto_failover).

-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/0, enable/2, disable/0, is_node_down/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, {global, ?MODULE}).

-record(state, {
          %enabled=true :: true|false,
          % The nodes that are currently consideren to be down. It's a list
          % of a two-tuple that conists of the node ID and the timestamp
          % when it was first considered down.
          nodes_down=[] :: [{atom(), integer()}],
          % Reference to the ns_tick_event. If it is nil, auto-failover is
          % disabled.
          tick_ref=nil :: nil|reference(),
          % Time a node needs to be down until it is automatically failovered
          age=nil :: nil|integer(),
          % The maximum number of nodes that should get automatically
          % failovered
          max_nodes=1 :: integer()
         }).

%%
%% API
%%

start_link() ->
    misc:start_singleton(gen_server, ?MODULE, [], []).
    %gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

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
    gen_server:cast(?SERVER, disable_auto_failover).

%% @doc Returns true if the node is down longer than the configured timespan.
-spec is_node_down(Node::atom()) -> true|false.
is_node_down(Node) ->
    gen_server:call(?SERVER, {is_node_down, Node}).

%%% @doc Returns true if the node is down longer than the configured timespan.
%%% 'Offset' (in seconds) will be add to the current time, this means that
%%% nodes that have not now, but now+Offset reached the age of being down will
%%% return true as well.
%-spec is_node_down(Node::atom(), Offset:integer()) -> true|false.
%is_node_down(Node, Offset) ->
%    gen_server:call(?SERVER, {is_node_down, Node, Offset}).


%%
%% gen_server callbacks
%%

init([]) ->
    ?log_info("init auto_failover: ~p", []),
    {value, Config} = ns_config:search(ns_config:get(), auto_failover),
    State = case proplists:get_value(enabled, Config) of
        true ->
            ?log_info("auto-failover is enabled~n", []),
            Age = proplists:get_value(age, Config),
            Max = proplists:get_value(max_nodes, Config),
            {reply, Enabled, State2} = handle_call(
                                         {enable_auto_failover, Age, Max},
                                         self(), #state{}),
            case Enabled of
                ok ->
                    ok;
                % Auto-failover wasn't really enabled. Update config.
                {error, _} ->
                    ns_config:set(auto_failover, [{enabled, false},
                                                  {age, Age},
                                                  {max_nodes, Max}])
            end,
            State2;
        _ ->
            #state{}
    end,
    {ok, State}.

%% @doc Auto-failover isn't enabled yet (tick_ref isn't set). We might not
%% enable it successfully because of certain contraints like a cluster
%% where some nodes are down.
handle_call({enable_auto_failover, Age, Max}, _From,
            #state{tick_ref=nil}=State) ->
    case actual_down_nodes() of
        [] ->
            Ref = ns_pubsub:subscribe(ns_tick_event),
            {reply, ok, State#state{tick_ref=Ref, age=Age, max_nodes=Max}};
        _ ->
            ?log_warning("Couldn't enable auto-failover. Please failover "
                         "all nodes that are currently down manually first",
                         []),
            {reply, {error, unhealthy}, State}
    end;
%% @doc Auto-failover is already, we don't do any further checks, whether
%% it can be enabled or not. We just update the settings.
handle_call({enable_auto_failover, Age, Max}, _From, State) ->
    ?log_info("updating auto-failover settings: ~p", [State]),
    {reply, ok, State#state{age=Age, max_nodes=Max}};

handle_call({is_node_down, Node}, _From,
            #state{nodes_down=ConsideredDown, age=Age}=State) ->
    {Node, DownTime} = lists:keyfind(Node, 1, ConsideredDown),
    Now = ns_tick:time(),
    {reply, (DownTime + Age*1000) < Now, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.


handle_cast(disable_auto_failover, #state{tick_ref=Ref}=State) ->
    ?log_info("disable_auto_failover: ~p", [State]),
    ns_pubsub:unsubscribe(ns_tick_event, Ref),
    {noreply, #state{}};

handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info({tick, TS}, #state{max_nodes=Max}=State) ->
    CurrentlyDown = actual_down_nodes(),
    AlreadyFailoveredNum = length(failovered_nodes()),
    case length(CurrentlyDown) + AlreadyFailoveredNum =< Max of
        % All nodes that went down can potentially be auto-failovered
        true ->
            % Failover all nodes that are down for a certain amount of time.
            % Disable auto-failover automatically when the maximum number of
            % nodes that can be auto-failovered is reached.
            case failover_nodes(CurrentlyDown, TS, State) of
                {error, _} ->
                    handle_cast(auto_failover_disable, State);
                StillDown ->
                    {noreply, State#state{nodes_down=StillDown}}
            end;
        % Many nodes are down at the same time, not all nodes can be
        % auto-failovered. This happens on major outages/net splits.
        % Therefore we disable auto-failover right now.
        false ->
            handle_cast(disable_auto_failover, State)
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%
%% Internal functions
%%

%% @doc Failover a node. `Max` is ther number of nodes that can be
%% auto-failovered at most.
-spec failover(Node::atom(), Max::integer()) -> ok|{error, maximum_reached}.
failover(Node, Max) ->
    % Only failover if the maximum number of nodes that
    % will be automatically failovered isn't reached yet
    case length(failovered_nodes()) < Max of
        true ->
            ns_cluster_membership:failover(Node),
            ok;
        false ->
            ?log_warning(
               "Could not auto-failover node (~p). "
               "Maximum number of nodes that will be "
               "automatically failovered (~p) is "
               "reached. Disabling auto-failver now.",
               [Node, Max]),
            {error, maximum_reached}
    end.

%% @doc Loop through all nodes that are currently down and Failovers a node
%% if it was down long enough and the maximum number of nodes that may be
%% auto-failovered isn't reached yet.
%% `CurrentlyDown` are the nodes that are down at the current tick
%% `ConsideredDown` are the nodes that were down on the last tick
%% `TS` is the timestamp of the current tick
%% `State` the current state of the gen_server
%% Returns the list of nodes that are currently down or and error.
-spec failover_nodes(CurrentlyDown::[atom()], TS::integer(),
                     State::#state{}) ->
                        [{atom(), integer()}]|{error, maximum_reached}.
failover_nodes(CurrentlyDown, TS, State) ->
    failover_nodes(CurrentlyDown, TS, State, []).

-spec failover_nodes(CurrentlyDown::[atom()], TS::integer(),
                     State::#state{}, Acc::[{atom(), integer()}]) ->
                        [{atom(), integer()}]|{error, maximum_reached}.
failover_nodes([], _TS, _State, Acc) ->
    lists:reverse(Acc);
failover_nodes([Node|Rest], TS,
               #state{nodes_down=ConsideredDown, max_nodes=Max}=State, Acc) ->
    case lists:keyfind(Node, 1, ConsideredDown) of
        % Node wasn't considered as down yet, add it to the list.
        false ->
            failover_nodes(Rest, TS, State, [{Node, TS}|Acc]);
        AlreadyDown ->
            % Check for how long this node is down already.
            % is_node_down doesn't change the state.
            {reply, DownForLong, State} = handle_call({is_node_down, Node},
                                                      self(), State),
            Failovered = case DownForLong of
                true -> failover(Node, Max);
                false -> ok
            end,
            % If node was successfully failovered, go on. If it failed,
            % return with an error.
            case Failovered of
                ok ->
                    failover_nodes(Rest, TS, State, [AlreadyDown|Acc]);
                Error ->
                    Error
            end
    end.

%% @doc Returns a list of nodes that should be active, but are not running.
-spec actual_down_nodes() -> [atom()].
actual_down_nodes() ->
    Active = ns_cluster_membership:active_nodes(),
    Actual = ns_cluster_membership:actual_active_nodes(),
    lists:subtract(Active, Actual).

%% @doc Returns a list of nodes that were already failovered.
-spec failovered_nodes() -> [atom()].
failovered_nodes() ->
    Nodes = ns_cluster_membership:get_nodes_cluster_membership(),
    [Node || {Node, Membership} <- Nodes, Membership=:=inactiveFailed].
