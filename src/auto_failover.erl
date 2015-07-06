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
%% It works like that: You specify a certain time interval a node
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
-include("ns_heart.hrl").

%% API
-export([start_link/0, enable/2, disable/0, reset_count/0, reset_count_async/0]).
%% For email alert notificatons
-export([alert_key/1, alert_keys/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% @doc Fired when a node was auto-failovered.
-define(EVENT_NODE_AUTO_FAILOVERED, 1).
%% @doc Fired when the maximum number of nodes that can be auto-failovered
%% was reached (and thus the auto-failover was disabled).
-define(EVENT_MAX_REACHED, 2).
%% @doc Fired when another node is down while we were trying to failover
%% a node
-define(EVENT_OTHER_NODES_DOWN, 3).
%% @doc Fired when the cluster gets to small to do a safe auto-failover
-define(EVENT_CLUSTER_TOO_SMALL, 4).
%% @doc Fired when a node is not auto-failedover because auto-failover
%% for one of the services running on the node is disabled.
-define(EVENT_AUTO_FAILOVER_DISABLED, 5).

%% @doc The time a stats request to a bucket may take (in milliseconds)
-define(STATS_TIMEOUT, 2000).

-record(state, {
          auto_failover_logic_state,
          %% Reference to the ns_tick_event. If it is nil, auto-failover is
          %% disabled.
          tick_ref=nil :: nil | timer:tref(),
          %% Time a node needs to be down until it is automatically failovered
          timeout=nil :: nil | integer(),
          %% Counts the number of nodes that were already auto-failovered
          count=0 :: non_neg_integer(),

          %% Whether we reported to the user autofailover_unsafe condition
          reported_autofailover_unsafe=false :: boolean(),
          %% Whether we reported that max number of auto failovers was reached
          reported_max_reached=false :: boolean(),
          %% Whether we reported that we could not auto failover because of
          %% rebalance
          reported_rebalance_running=false :: boolean(),
          %% Whether we reported that we could not auto failover because of
          %% recovery mode
          reported_in_recovery=false :: boolean()
         }).

%%
%% API
%%

start_link() ->
    misc:start_singleton(gen_server, ?MODULE, [], []).

%% @doc Enable auto-failover. Failover after a certain time (in seconds),
%% Returns an error (and reason) if it couldn't be enabled, e.g. because
%% not all nodes in the cluster were healthy.
%% `Timeout` is the number of seconds a node must be down before it will be
%% automatically failovered
%% `Max` is the maximum number of nodes that can will be automatically
%% failovered
-spec enable(Timeout::integer(), Max::integer()) -> ok.
enable(Timeout, Max) ->
    1 = Max,
    call({enable_auto_failover, Timeout, Max}).

%% @doc Disable auto-failover
-spec disable() -> ok.
disable() ->
    call(disable_auto_failover).

%% @doc Reset the number of nodes that were auto-failovered to zero
-spec reset_count() -> ok.
reset_count() ->
    call(reset_auto_failover_count).

-spec reset_count_async() -> ok.
reset_count_async() ->
    cast(reset_auto_failover_count).

call(Call) ->
    misc:wait_for_global_name(?MODULE, 20000),
    gen_server:call({global, ?MODULE}, Call).

cast(Call) ->
    misc:wait_for_global_name(?MODULE, 20000),
    gen_server:cast({global, ?MODULE}, Call).

-spec alert_key(Code::integer()) -> atom().
alert_key(?EVENT_NODE_AUTO_FAILOVERED) -> auto_failover_node;
alert_key(?EVENT_MAX_REACHED) -> auto_failover_maximum_reached;
alert_key(?EVENT_OTHER_NODES_DOWN) -> auto_failover_other_nodes_down;
alert_key(?EVENT_CLUSTER_TOO_SMALL) -> auto_failover_cluster_too_small;
alert_key(?EVENT_AUTO_FAILOVER_DISABLED) -> auto_failover_disabled;
alert_key(_) -> all.

%% @doc Returns a list of all alerts that might send out an email notification.
-spec alert_keys() -> [atom()].
alert_keys() ->
    [auto_failover_node,
     auto_failover_maximum_reached,
     auto_failover_other_nodes_down,
     auto_failover_cluster_too_small,
     auto_failover_disabled].

%%
%% gen_server callbacks
%%

init([]) ->
    {value, Config} = ns_config:search(ns_config:get(), auto_failover_cfg),
    ?log_debug("init auto_failover.", []),
    Timeout = proplists:get_value(timeout, Config),
    Count = proplists:get_value(count, Config),
    State0 = #state{timeout=Timeout,
                    count=Count,
                    auto_failover_logic_state = undefined},
    State1 = init_reported(State0),
    case proplists:get_value(enabled, Config) of
        true ->
            {reply, ok, State2} = handle_call(
                                    {enable_auto_failover, Timeout, 1},
                                    self(), State1),
            {ok, State2};
        false ->
            {ok, State1}
    end.

init_logic_state(Timeout) ->
    DownThreshold = (Timeout * 1000 + ?HEART_BEAT_PERIOD - 1) div ?HEART_BEAT_PERIOD,
    auto_failover_logic:init_state(DownThreshold).

%% @doc Auto-failover isn't enabled yet (tick_ref isn't set).
handle_call({enable_auto_failover, Timeout, Max}, _From,
            #state{tick_ref=nil}=State) ->
    1 = Max,
    ale:info(?USER_LOGGER, "Enabled auto-failover with timeout ~p", [Timeout]),
    {ok, Ref} = timer2:send_interval(?HEART_BEAT_PERIOD, tick),
    State2 = State#state{tick_ref=Ref, timeout=Timeout,
                         auto_failover_logic_state=init_logic_state(Timeout)},
    make_state_persistent(State2),
    {reply, ok, State2};
%% @doc Auto-failover is already enabled, just update the settings.
handle_call({enable_auto_failover, Timeout, Max}, _From, State) ->
    ?log_debug("updating auto-failover settings: ~p", [State]),
    1 = Max,
    ale:info(?USER_LOGGER, "Updating auto-failover timeout to ~p", [Timeout]),
    State2 = State#state{timeout=Timeout,
                         auto_failover_logic_state = init_logic_state(Timeout)},
    make_state_persistent(State2),
    {reply, ok, State2};

%% @doc Auto-failover is already disabled, so we don't do anything
handle_call(disable_auto_failover, _From, #state{tick_ref=nil}=State) ->
    {reply, ok, State};
%% @doc Auto-failover is enabled, disable it
handle_call(disable_auto_failover, _From, #state{tick_ref=Ref}=State) ->
    ?log_debug("disable_auto_failover: ~p", [State]),
    {ok, cancel} = timer2:cancel(Ref),
    State2 = State#state{tick_ref=nil, auto_failover_logic_state = undefined},
    make_state_persistent(State2),
    ale:info(?USER_LOGGER, "Disabled auto-failover"),
    {reply, ok, State2};
handle_call(reset_auto_failover_count, _From, State) ->
    {noreply, NewState} = handle_cast(reset_auto_failover_count, State),
    {reply, ok, NewState};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(reset_auto_failover_count, State) ->
    ?log_debug("reset auto_failover count: ~p", [State]),
    State2 = State#state{count=0,
                         auto_failover_logic_state = init_logic_state(State#state.timeout)},
    State3 = init_reported(State2),
    make_state_persistent(State3),
    ale:info(?USER_LOGGER, "Reset auto-failover count"),
    {noreply, State3};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% @doc Check if nodes should/could be auto-failovered on every tick
handle_info(tick, State0) ->
    Config = ns_config:get(),

    %% Reread autofailover count from config just in case. This value can be
    %% different, for instance, if due to network issues we get disconnected
    %% from the part of the cluster. This part of the cluster will elect new
    %% master node. Now say this new master node autofailovers some other
    %% node. Then if network issues disappear, we will connect back to the
    %% rest of the cluster. And say we win the battle over mastership
    %% again. In this case our failover count will still be zero which is
    %% incorrect.
    {value, AutoFailoverConfig} = ns_config:search(Config, auto_failover_cfg),
    AutoFailoverCount = proplists:get_value(count, AutoFailoverConfig),
    true = is_integer(AutoFailoverCount),

    State = State0#state{count=AutoFailoverCount},

    NonPendingNodes = lists:sort(ns_cluster_membership:active_nodes(Config)),

    NodeStatuses = ns_doctor:get_nodes(),
    CurrentlyDown = actual_down_nodes(NodeStatuses, NonPendingNodes, Config),

    NodeUUIDs =
        ns_config:fold(
          fun (Key, Value, Acc) ->
                  case Key of
                      {node, Node, uuid} ->
                          dict:store(Node, Value, Acc);
                      _ ->
                          Acc
                  end
          end, dict:new(), Config),

    %% Extract service specfic information from the Config
    ServicesConfig = all_services_config(Config),

    {Actions, LogicState} =
        auto_failover_logic:process_frame(attach_node_uuids(NonPendingNodes, NodeUUIDs),
                                          attach_node_uuids(CurrentlyDown, NodeUUIDs),
                                          State#state.auto_failover_logic_state,
                                          ServicesConfig),
    NewState =
        lists:foldl(
          fun ({mail_too_small, Service, SvcNodes, {Node, _UUID}}, S) ->
                  ?user_log(?EVENT_CLUSTER_TOO_SMALL,
                            "Could not auto-failover node (~p). "
                            "Number of nodes running ~p service is ~p. "
                            "You need at least ~p nodes.",
                            [Node, Service, length(SvcNodes),
                             auto_failover_logic:service_failover_min_node_count(Service) + 1]),
                  S;
              ({_, {Node, _UUID}}, #state{count=1} = S) ->
                  case should_report(#state.reported_max_reached, S) of
                      true ->
                          ?user_log(?EVENT_MAX_REACHED,
                                    "Could not auto-failover more nodes (~p). "
                                    "Maximum number of nodes that will be "
                                    "automatically failovered (1) is reached.",
                                    [Node]),
                          note_reported(#state.reported_max_reached, S);
                      false ->
                          S
                  end;
              ({mail_down_warning, {Node, _UUID}}, S) ->
                  ?user_log(?EVENT_OTHER_NODES_DOWN,
                            "Could not auto-failover node (~p). "
                            "There was at least another node down.",
                            [Node]),
                  S;
              ({mail_auto_failover_disabled, Service, {Node, _UUID}}, S) ->
                  ?user_log(?EVENT_AUTO_FAILOVER_DISABLED,
                            "Could not auto-failover node (~p). "
                            "Auto-failover for ~p service is disbaled.",
                            [Node, Service]),
                  S;
              ({failover, {Node, _UUID}}, S) ->
                  case ns_orchestrator:try_autofailover(Node) of
                      ok ->
                          ?user_log(?EVENT_NODE_AUTO_FAILOVERED,
                                    "Node (~p) was automatically failovered.~n~p",
                                    [Node, ns_doctor:get_node(Node, NodeStatuses)]),
                          init_reported(S#state{count = S#state.count+1});
                      {autofailover_unsafe, UnsafeBuckets} ->
                          case should_report(#state.reported_autofailover_unsafe, S) of
                              true ->
                                  ?user_log(?EVENT_NODE_AUTO_FAILOVERED,
                                            "Could not automatically fail over node (~p)."
                                            " Would lose vbuckets in the following buckets: ~p", [Node, UnsafeBuckets]),
                                  note_reported(#state.reported_autofailover_unsafe, S);
                              false ->
                                  S
                          end;
                      rebalance_running ->
                          case should_report(#state.reported_rebalance_running, S) of
                              true ->
                                  ?user_log(?EVENT_NODE_AUTO_FAILOVERED,
                                            "Could not automatically fail over node (~p). "
                                            "Rebalance is running.", [Node]),
                                  note_reported(#state.reported_rebalance_running, S);
                              false ->
                                  S
                          end;
                      in_recovery ->
                          case should_report(#state.reported_in_recovery, S) of
                              true ->
                                  ?user_log(?EVENT_NODE_AUTO_FAILOVERED,
                                            "Could not automatically fail over node (~p)."
                                            "Cluster is in recovery mode.", [Node]),
                                  note_reported(#state.reported_in_recovery, S);
                              false ->
                                  S
                          end
                  end
          end, State#state{auto_failover_logic_state = LogicState}, Actions),

    NewState1 = update_reported_flags_by_actions(Actions, NewState),

    if
        NewState1#state.count =/= State#state.count ->
            make_state_persistent(NewState1);
        true -> ok
    end,
    {noreply, NewState1};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%
%% Internal functions
%%

%% @doc Returns a list of nodes that should be active, but are not running.
-spec actual_down_nodes(dict(), [atom()], [{atom(), term()}]) -> [atom()].
actual_down_nodes(NodesDict, NonPendingNodes, Config) ->
    %% Get all buckets
    BucketConfigs = ns_bucket:get_buckets(Config),
    actual_down_nodes_inner(NonPendingNodes, BucketConfigs, NodesDict, erlang:now()).

actual_down_nodes_inner(NonPendingNodes, BucketConfigs, NodesDict, Now) ->
    BucketsServers = [{Name, lists:sort(proplists:get_value(servers, BC, []))}
                      || {Name, BC} <- BucketConfigs],

    lists:filter(
      fun (Node) ->
              case dict:find(Node, NodesDict) of
                  {ok, Info} ->
                      case proplists:get_value(last_heard, Info) of
                          T -> timer:now_diff(Now, T) > (?HEART_BEAT_PERIOD + ?STATS_TIMEOUT) * 1000
                      end orelse
                          begin
                              Ready = proplists:get_value(ready_buckets, Info, []),
                              ExpectedReady = [Name || {Name, Servers} <- BucketsServers,
                                                       ordsets:is_element(Node, Servers)],
                              (ExpectedReady -- Ready) =/= []
                          end;
                  error ->
                      true
              end
      end, NonPendingNodes).

%% @doc Save the current state in ns_config
-spec make_state_persistent(State::#state{}) -> ok.
make_state_persistent(State) ->
    Enabled = case State#state.tick_ref of
                  nil -> false;
                  _ -> true
              end,
    ns_config:set(auto_failover_cfg,
                  [{enabled, Enabled},
                   {timeout, State#state.timeout},
                   {count, State#state.count}]).

note_reported(Flag, State) ->
    false = element(Flag, State),
    setelement(Flag, State, true).

should_report(Flag, State) ->
    not(element(Flag, State)).

init_reported(State) ->
    State#state{reported_autofailover_unsafe=false,
                reported_max_reached=false,
                reported_rebalance_running=false,
                reported_in_recovery=false}.

update_reported_flags_by_actions(Actions, State) ->
    case lists:keymember(failover, 1, Actions) of
        false ->
            init_reported(State);
        true ->
            State
    end.

%% Create a list of all services with following info for each service:
%% - is auto-failover for the service disabled
%% - list of nodes that are currently running the service.
all_services_config(Config) ->
    %% Get list of all supported services
    AllServices = ns_cluster_membership:supported_services(),
    lists:map(
      fun (Service) ->
              %% Get list of all nodes running the service.
              SvcNodes = ns_cluster_membership:service_active_nodes(Config,
                                                                    Service, all),
              %% Is auto-failover for the service disabled?
              ServiceKey = {auto_failover_disabled, Service},
              DV = case Service of
                       index ->
                           %% Auto-failover disabled by default for index service.
                           true;
                       _ ->
                           false
                   end,
              AutoFailoverDisabled = ns_config:search(Config, ServiceKey, DV),
              {Service, {{disable_auto_failover, AutoFailoverDisabled},
                         {nodes, SvcNodes}}}
      end, AllServices).

attach_node_uuids(Nodes, UUIDDict) ->
    lists:map(
      fun (Node) ->
              case dict:find(Node, UUIDDict) of
                  {ok, UUID} ->
                      {Node, UUID};
                  error ->
                      {Node, undefined}
              end
      end, Nodes).

-ifdef(EUNIT).

actual_down_nodes_inner_test() ->
    PList0 = [{a, ["bucket1", "bucket2"]},
              {b, ["bucket1"]},
              {c, []}],
    NodesDict = dict:from_list([{N, [{ready_buckets, B},
                                     {last_heard, {0, 0, 0}}]}
                                || {N, B} <- PList0]),
    R = fun (Nodes, Buckets) ->
                actual_down_nodes_inner(Nodes, Buckets, NodesDict, {0, 0, 0})
        end,
    ?assertEqual([], R([a, b, c], [])),
    ?assertEqual([], R([a, b, c],
                       [{"bucket1", [{servers, [a]}]}])),
    ?assertEqual([], R([a, b, c],
                       [{"bucket1", [{servers, [a, b]}]}])),
    %% this also tests too "old" hearbeats a bit
    ?assertEqual([a,b,c],
                 actual_down_nodes_inner([a,b,c],
                                         [{"bucket1", [{servers, [a, b]}]}],
                                         NodesDict, {16#100000000, 0, 0})),
    ?assertEqual([c], R([a, b, c],
                        [{"bucket1", [{servers, [a, b, c]}]}])),
    ?assertEqual([b, c], R([a, b, c],
                           [{"bucket1", [{servers, [a, b, c]}]},
                            {"bucket2", [{servers, [a, b, c]}]}])),
    ?assertEqual([b, c], R([a, b, c],
                           [{"bucket2", [{servers, [a, b, c]}]}])),
    ?assertEqual([a, b, c], R([a, b, c],
                              [{"bucket3", [{servers, [a]}]},
                               {"bucket2", [{servers, [a, b, c]}]}])),
    ok.

-define(FLAG, #state.reported_autofailover_unsafe).
reported_test() ->
    %% nothing reported initially
    State = init_reported(#state{}),

    %% we correctly instructed to report the condition for the first time
    ?assertEqual(should_report(?FLAG, State), true),
    State1 = note_reported(?FLAG, State),
    State2 = update_reported_flags_by_actions([{failover, some_node}], State1),

    %% we don't report it second time
    ?assertEqual(should_report(?FLAG, State2), false),

    %% we report the condition again for the other "instance" of failover
    %% (i.e. failover is not needed for some time, but the it's needed again)
    State3 = update_reported_flags_by_actions([], State2),
    ?assertEqual(should_report(?FLAG, State3), true),

    %% we report the condition after we explicitly drop it (note that we use
    %% State2)
    State4 = init_reported(State2),
    ?assertEqual(should_report(?FLAG, State4), true),

    ok.

-endif.
