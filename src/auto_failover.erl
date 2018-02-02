%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2011-2018 Couchbase, Inc.
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
-export([start_link/0, enable/3, disable/1, reset_count/0, reset_count_async/0]).
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

%% @doc Frequency (in milliseconds) at which to check for down nodes.
-define(TICK_PERIOD, 1000).

%% @doc Minimum number of active server groups needed for server group failover
-define(MIN_ACTIVE_SERVER_GROUPS, 3).

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
%% `Extras` are optional settings.
-spec enable(Timeout::integer(), Max::integer(), Extras::list()) -> ok.
enable(Timeout, Max, Extras) ->
    1 = Max,
    %% Request will be sent to the master for processing.
    %% In a mixed version cluster, node running highest version is
    %% usually selected as the master.
    %% But to be safe, if the cluster has not been fully upgraded yet,
    %% then use the old API.
    case cluster_compat_mode:is_cluster_vulcan() of
        true ->
            call({enable_auto_failover, Timeout, Max, Extras});
        false ->
            call({enable_auto_failover, Timeout, Max})
    end.

%% @doc Disable auto-failover
-spec disable(Extras::list()) -> ok.
disable(Extras) ->
    case cluster_compat_mode:is_cluster_vulcan() of
        true ->
            call({disable_auto_failover, Extras});
        false ->
            call(disable_auto_failover)
    end.

%% @doc Reset the number of nodes that were auto-failovered to zero
-spec reset_count() -> ok.
reset_count() ->
    call(reset_auto_failover_count).

-spec reset_count_async() -> ok.
reset_count_async() ->
    cast(reset_auto_failover_count).

call(Call) ->
    misc:wait_for_global_name(?MODULE),
    gen_server:call({global, ?MODULE}, Call).

cast(Call) ->
    misc:wait_for_global_name(?MODULE),
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
    TickPeriod = get_tick_period(),
    DownThreshold = (Timeout * 1000 + TickPeriod - 1) div TickPeriod,
    auto_failover_logic:init_state(DownThreshold).

handle_call({enable_auto_failover, Timeout, Max}, From, State) ->
    handle_call({enable_auto_failover, Timeout, Max, []}, From, State);
%% @doc Auto-failover isn't enabled yet (tick_ref isn't set).
handle_call({enable_auto_failover, Timeout, Max, Extras}, _From,
            #state{tick_ref=nil}=State) ->
    1 = Max,
    ale:info(?USER_LOGGER, "Enabled auto-failover with timeout ~p", [Timeout]),
    {ok, Ref} = timer2:send_interval(get_tick_period(), tick),
    State2 = State#state{tick_ref=Ref, timeout=Timeout,
                         auto_failover_logic_state=init_logic_state(Timeout)},
    make_state_persistent(State2, Extras),
    {reply, ok, State2};
%% @doc Auto-failover is already enabled, just update the settings.
handle_call({enable_auto_failover, Timeout, Max, Extras}, _From,
            #state{timeout = CurrTimeout} = State) ->
    ?log_debug("updating auto-failover settings: ~p", [State]),
    1 = Max,
    State2 = case Timeout =/= CurrTimeout of
                 true ->
                     ale:info(?USER_LOGGER,
                              "Updating auto-failover timeout to ~p",
                              [Timeout]),
                     State#state{timeout = Timeout,
                                 auto_failover_logic_state = init_logic_state(Timeout)};
                 false ->
                     ?log_debug("No change in timeout ~p", [Timeout]),
                     State
             end,
    make_state_persistent(State2, Extras),
    {reply, ok, State2};

handle_call(disable_auto_failover, From, State) ->
    handle_call({disable_auto_failover, []}, From, State);
%% @doc Auto-failover is already disabled, so we don't do anything
handle_call({disable_auto_failover, _}, _From, #state{tick_ref=nil}=State) ->
    {reply, ok, State};
%% @doc Auto-failover is enabled, disable it
handle_call({disable_auto_failover, Extras}, _From, #state{tick_ref=Ref}=State) ->
    ?log_debug("disable_auto_failover: ~p", [State]),
    {ok, cancel} = timer2:cancel(Ref),
    State2 = State#state{tick_ref=nil, auto_failover_logic_state = undefined},
    make_state_persistent(State2, Extras),
    ale:info(?USER_LOGGER, "Disabled auto-failover"),
    {reply, ok, State2};
handle_call(reset_auto_failover_count, _From, State) ->
    {noreply, NewState} = handle_cast(reset_auto_failover_count, State),
    {reply, ok, NewState};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(reset_auto_failover_count, #state{count=0}=State) ->
    {noreply, State};
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
    State = State0#state{count = get_auto_failover_count(Config)},

    NonPendingNodes = lists:sort(ns_cluster_membership:active_nodes(Config)),

    NodeStatuses = ns_doctor:get_nodes(),
    {DownNodes, DownSG} = get_down_nodes(NodeStatuses,
                                         NonPendingNodes, Config),
    CurrentlyDown = [N || {N, _} <- DownNodes],
    NodeUUIDs = ns_config:get_node_uuid_map(Config),

    %% Extract service specfic information from the Config
    ServicesConfig = all_services_config(Config),

    {Actions, LogicState} =
        auto_failover_logic:process_frame(attach_node_uuids(NonPendingNodes, NodeUUIDs),
                                          attach_node_uuids(CurrentlyDown, NodeUUIDs),
                                          State#state.auto_failover_logic_state,
                                          ServicesConfig, DownSG),
    NewState = lists:foldl(
                 fun(Action, S) ->
                         process_action(Action, S, DownNodes, NodeStatuses)
                 end, State#state{auto_failover_logic_state = LogicState},
                 Actions),

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
process_action({mail_too_small, Service, SvcNodes, {Node, _UUID}}, S, _, _) ->
    ?user_log(?EVENT_CLUSTER_TOO_SMALL,
              "Could not auto-failover node (~p). "
              "Number of nodes running ~s service is ~p. "
              "You need at least ~p nodes.",
              [Node,
               ns_cluster_membership:user_friendly_service_name(Service),
               length(SvcNodes),
               auto_failover_logic:service_failover_min_node_count(Service) + 1]),
    S;
process_action({mail_down_warning, {Node, _UUID}}, S, _, _) ->
    ?user_log(?EVENT_OTHER_NODES_DOWN,
              "Could not auto-failover node (~p). "
              "There was at least another node down.",
              [Node]),
    S;
process_action({mail_auto_failover_disabled, Service, {Node, _}}, S, _, _) ->
    ?user_log(?EVENT_AUTO_FAILOVER_DISABLED,
              "Could not auto-failover node (~p). "
              "Auto-failover for ~s service is disabled.",
              [Node, ns_cluster_membership:user_friendly_service_name(Service)]),
    S;
process_action({_, {Node, _UUID}}, #state{count = 1} = S, _, _) ->
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
process_action({failover_group, SG, Nodes0}, #state{count = 1} = S, _, _) ->
    case should_report(#state.reported_max_reached, S) of
        true ->
            Nodes = [N || {N, _} <- Nodes0],
            ?user_log(?EVENT_MAX_REACHED,
                      "Could not auto-failover server group (~p) "
                      "with nodes (~p). Maximum number of auto-failover "
                      "events has been reached.", [binary_to_list(SG), Nodes]),
            note_reported(#state.reported_max_reached, S);
        false ->
            S
    end;
process_action({failover_group, SG, Nodes0}, OldState, DownNodes,
               NodeStatuses) ->
    Nodes = [N || {N, _} <- Nodes0],
    %% TODO: Add new reported flag in the state for following message
    %% so that this message is dispalyed only once for each unique
    %% server group auto-failover event.
    %% Otherwise it will spam the user log when failover of nodes in SG fails.
    ale:info(?USER_LOGGER, "Attempting auto-failover of server group (~p) "
             "with nodes (~p).", [binary_to_list(SG), Nodes]),
    lists:foldl(
      fun (Node, NewState) ->
              %% Pass OldState instead of NewState for failover of each node.
              %% This is so that any errors are reported for each of them
              %% and also the count does not get incremented more than once.
              NS = failover_node(Node, OldState, DownNodes, NodeStatuses),
              case NS#state.count > OldState#state.count of
                  true ->
                      init_reported(NewState#state{count = NS#state.count});
                  false ->
                      update_reported_flags(NewState, NS)
              end
      end, OldState, Nodes);
process_action({failover, {Node, _UUID}}, S, DownNodes, NodeStatuses) ->
    failover_node(Node, S, DownNodes, NodeStatuses).

failover_node(Node, S, DownNodes, NodeStatuses) ->
    case ns_orchestrator:try_autofailover(Node) of
        ok ->
            {_, DownInfo} = lists:keyfind(Node, 1, DownNodes),
            case DownInfo of
                unknown ->
                    ?user_log(?EVENT_NODE_AUTO_FAILOVERED,
                              "Node (~p) was automatically failovered.~n~p",
                              [Node, ns_doctor:get_node(Node, NodeStatuses)]);
                {Reason, MARes} ->
                    MA = [atom_to_list(M) || M <- MARes],
                    master_activity_events:note_autofailover_done(Node, string:join(MA, ",")),
                    ?user_log(?EVENT_NODE_AUTO_FAILOVERED,
                              "Node (~p) was automatically failed over. Reason: ~s",
                              [Node, Reason])
            end,
            init_reported(S#state{count = S#state.count + 1});
        Error ->
            process_failover_error(Error, Node, S)
    end.

process_failover_error({autofailover_unsafe, UnsafeBuckets}, Node, S) ->
    ErrMsg = lists:flatten(io_lib:format("Would lose vbuckets in the"
                                         " following buckets: ~p",
                                         [UnsafeBuckets])),
    report_failover_error(#state.reported_autofailover_unsafe, ErrMsg,
                          Node, S);
process_failover_error(rebalance_running, Node, S) ->
    report_failover_error(#state.reported_rebalance_running,
                          "Rebalance is running.", Node, S);
process_failover_error(in_recovery, Node, S) ->
    report_failover_error(#state.reported_in_recovery,
                          "Cluster is in recovery mode.", Node, S).

report_failover_error(Flag, ErrMsg, Node, State) ->
    case should_report(Flag, State) of
        true ->
            ?user_log(?EVENT_NODE_AUTO_FAILOVERED,
                      "Could not automatically fail over node (~p). ~s",
                      [Node, ErrMsg]),
            note_reported(Flag, State);
        false ->
            State
    end.
%% TODO - move this later to (yet to be created) auto_failover_settings module.
get_auto_failover_count(Config) ->
    {value, AutoFailoverConfig} = ns_config:search(Config, auto_failover_cfg),
    AutoFailoverCount = proplists:get_value(count, AutoFailoverConfig),
    true = is_integer(AutoFailoverCount),
    AutoFailoverCount.

get_tick_period() ->
    case cluster_compat_mode:is_cluster_50() of
        true ->
            ?TICK_PERIOD;
        false ->
            ?HEART_BEAT_PERIOD
    end.

%% Returns list of nodes that are down/unhealthy along with the reason
%% why the node is considered unhealthy.
%% Also, returns name of the down server group if all nodes in that group
%% are down and all other requirements for server group auto-failover are
%% satisfied.
get_down_nodes(NodeStatuses, NonPendingNodes, Config) ->
    case cluster_compat_mode:is_cluster_50() of
        true ->
            %% Find down nodes using the new failure detector.
            DownNodesInfo0 = fastfo_down_nodes(NonPendingNodes),
            DownSG = get_down_server_group(DownNodesInfo0, Config,
                                           NonPendingNodes),
            DownNodesInfo = [{N, Info} || {N, Info, _} <- DownNodesInfo0],
            {DownNodesInfo, DownSG};
        false ->
            DownNodes = actual_down_nodes(NodeStatuses, NonPendingNodes,
                                          Config),
            {lists:zip(DownNodes, lists:duplicate(length(DownNodes), unknown)),
             []}
    end.

fastfo_down_nodes(NonPendingNodes) ->
    NodeStatuses = node_status_analyzer:get_nodes(),
    lists:foldl(
      fun (Node, Acc) ->
              case dict:find(Node, NodeStatuses) of
                  error ->
                      Acc;
                  {ok, NodeStatus} ->
                      case is_node_down(Node, NodeStatus) of
                          false ->
                              Acc;
                          {true, DownInfo} ->
                              [{Node, DownInfo, false} | Acc];
                          {true, DownInfo, AllMonitorsDown} ->
                              [{Node, DownInfo, AllMonitorsDown} | Acc]
                      end
              end
      end, [], NonPendingNodes).

is_node_down(Node, {unhealthy, _}) ->
    %% When ns_server is the only monitor running on a node,
    %% then we cannot distinguish between ns_server down and node down.
    %% This is currently true for all non-KV nodes.
    %% For such nodes, display ns-server down message as it is
    %% applicable during both conditions.
    %%
    %% The node is down because all monitors on the node report it as
    %% unhealthy. This is one of the requirements for server group
    %% auto-failover.
    case health_monitor:node_monitors(Node) of
        [ns_server] = Monitor ->
            {true, Res} = is_node_down(Monitor),
            {true, Res, true};
        _ ->
            {true, {"All monitors report node is unhealthy.",
                    [unhealthy_node]}, true}
    end;
is_node_down(_, {{needs_attention, MonitorStatuses}, _}) ->
    %% Different monitors are reporting different status for the node.
    is_node_down(MonitorStatuses);
is_node_down(_, _) ->
    false.

is_node_down(MonitorStatuses) ->
    Down = lists:foldl(
             fun (MonitorStatus, {RAcc, MAcc}) ->
                     {Monitor, Status} = case MonitorStatus of
                                             {M, S} ->
                                                 {M, S};
                                             M ->
                                                 {M, needs_attention}
                                         end,
                     Module = health_monitor:get_module(Monitor),
                     case Module:is_node_down(Status) of
                         false ->
                             {RAcc, MAcc};
                         {true, {Reason, MAinfo}} ->
                             {Reason ++ " " ++  RAcc, [MAinfo | MAcc]}
                     end
             end, {[], []}, MonitorStatuses),
    case Down of
        {[], []} ->
            false;
        _ ->
            {true, Down}
    end.

%%
%% Requirements for server group auto-failover:
%%  - User has enabled auto-failover of server groups.
%%  - There are 3 or more active server groups in the cluster
%%    at the time of the failure.
%%      - If there are only two server groups and there is a network
%%      partition between them, then both groups may try to fail each other
%%      over. This requirement prevents such a scenario.
%%  - All nodes in the server group are down.
%%  - All down nodes belong to the same server group.
%%      - This prevents a network partition from causing two or more
%%      partitions of a cluster from failing each other over.
%%  - All monitors report the down nodes are unhealthy.
%%      - When all monitors report all nodes in the server group are
%%        down then it is taken as an indication of a correlated failure.
%%      - Scenario #1: Say a server group has two nodes, node1 and node2.
%%        node1 is reported as down by KV monitor due to say memcached issues
%%        and node2 is reported as down by ns_server monitor.
%%        This scenario does not meet the requirement for server group
%%        failover.
%%      - Scenario #2: Both ns-server & KV monitor on node1 and node2
%%        report those nodes are down. This meets the requirement for
%%        server group failover.
%%
get_down_server_group([], _, _) ->
    [];
get_down_server_group([_], _, _) ->
    %% Only one node is down. Skip the checks for server group failover.
    [];
get_down_server_group(DownNodesInfo, Config, NonPendingNodes) ->
    %% TODO: Temporary. Save the failoverServerGroup setting in
    %% the auto_failover gen_server state to avoid this lookup.
    {value, AFOConfig} = ns_config:search(Config, auto_failover_cfg),
    case proplists:get_value(failoverServerGroup, AFOConfig, false) of
        true ->
            case length(DownNodesInfo) > (length(NonPendingNodes)/2) of
                true ->
                    DownNodes = [N || {N, _, _} <- DownNodesInfo],
                    ?log_debug("Skipping checks for server group autofailover "
                               "because majority of nodes are down. "
                               "Down nodes:~p", [DownNodes]),
                    [];
                false ->
                    get_down_server_group_inner(DownNodesInfo, Config)
            end;
        false ->
            []
    end.

get_down_server_group_inner(DownNodesInfo, Config) ->
    %% Do all monitors on all down nodes report them as unhealthy?
    Pred = fun ({_, _, true}) -> true; (_) -> false end,
    case lists:all(Pred, DownNodesInfo) of
        true ->
            case enough_active_server_groups(Config) of
                false ->
                    [];
                SGs ->
                    DownNodes = lists:sort([N || {N, _, _} <- DownNodesInfo]),
                    case all_nodes_down_in_same_group(SGs, DownNodes) of
                        false ->
                            [];
                        DownSG ->
                            DownSG
                    end
            end;
        false ->
            []
    end.

enough_active_server_groups(Config) ->
    ActiveSGs = active_server_groups(Config),
    case length(ActiveSGs) < ?MIN_ACTIVE_SERVER_GROUPS of
        true ->
            false;
        false ->
            ActiveSGs
    end.

active_server_groups(Config) ->
    {value, Groups} = ns_config:search(Config, server_groups),
    AllSGs = [{proplists:get_value(name, SG),
               proplists:get_value(nodes, SG)} || SG <- Groups],
    lists:filtermap(
      fun ({SG, Ns}) ->
              NMs = ns_cluster_membership:get_nodes_cluster_membership(Ns),
              ActiveNodes = [N || {N, active} <- NMs],
              case ActiveNodes of
                  [] ->
                      false;
                  _ ->
                      {true, {SG, ActiveNodes}}
              end
      end, AllSGs).

%% All nodes in the server group are down.
%% All down nodes belong to the same server group.
all_nodes_down_in_same_group([], _) ->
    false;
all_nodes_down_in_same_group([{SG, Nodes} | Rest], DownNodes) ->
    case lists:sort(Nodes) =:= DownNodes of
        true ->
            SG;
        false ->
            all_nodes_down_in_same_group(Rest, DownNodes)
    end.

%% @doc Returns a list of nodes that should be active, but are not running.
-spec actual_down_nodes(dict(), [atom()], [{atom(), term()}]) -> [atom()].
actual_down_nodes(NodesDict, NonPendingNodes, Config) ->
    %% Get all buckets
    BucketConfigs = ns_bucket:get_buckets(Config),
    actual_down_nodes_inner(NonPendingNodes, BucketConfigs, NodesDict,
                            time_compat:monotonic_time()).

actual_down_nodes_inner(NonPendingNodes, BucketConfigs, NodesDict, Now) ->
    BucketsServers = [{Name, lists:sort(proplists:get_value(servers, BC, []))}
                      || {Name, BC} <- BucketConfigs],

    lists:filter(
      fun (Node) ->
              case dict:find(Node, NodesDict) of
                  {ok, Info} ->
                      LastHeard = proplists:get_value(last_heard, Info),
                      Diff      = time_compat:convert_time_unit(Now - LastHeard,
                                                                native,
                                                                millisecond),

                      Diff > (?HEART_BEAT_PERIOD + ?STATS_TIMEOUT) orelse
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
    make_state_persistent(State, []).
make_state_persistent(State, Extras) ->
    Enabled = case State#state.tick_ref of
                  nil ->
                      false;
                  _ ->
                      true
              end,
    {value, Cfg} = ns_config:search(ns_config:get(), auto_failover_cfg),
    NewCfg0 = lists:keyreplace(enabled, 1, Cfg, {enabled, Enabled}),
    NewCfg1 = lists:keyreplace(timeout, 1, NewCfg0,
                               {timeout, State#state.timeout}),
    NewCfg2 = lists:keyreplace(count, 1, NewCfg1,
                               {count, State#state.count}),
    NewCfg = lists:foldl(
               fun ({Key, Val}, Acc) ->
                       lists:keyreplace(Key, 1, Acc, {Key, Val})
               end, NewCfg2, Extras),
    ns_config:set(auto_failover_cfg, NewCfg).

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

update_reported_flags(NewState0, UpdatedState) ->
    Flags = [#state.reported_autofailover_unsafe,
             #state.reported_rebalance_running,
             #state.reported_in_recovery],
    lists:foldl(
      fun (Flag, NewState) ->
              case element(Flag, UpdatedState) of
                  true ->
                      setelement(Flag, NewState, true);
                  false ->
                      NewState
              end
      end, NewState0, Flags).

update_reported_flags_by_actions(Actions, State) ->
    case lists:keymember(failover, 1, Actions) orelse
        lists:keymember(failover_group, 1, Actions) of
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
    AllServices = ns_cluster_membership:cluster_supported_services(),
    lists:map(
      fun (Service) ->
              %% Get list of all nodes running the service.
              SvcNodes = ns_cluster_membership:service_active_nodes(Config, Service),
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
                                     {last_heard, 0}]}
                                || {N, B} <- PList0]),
    R = fun (Nodes, Buckets) ->
                actual_down_nodes_inner(Nodes, Buckets, NodesDict, 0)
        end,
    ?assertEqual([], R([a, b, c], [])),
    ?assertEqual([], R([a, b, c],
                       [{"bucket1", [{servers, [a]}]}])),
    ?assertEqual([], R([a, b, c],
                       [{"bucket1", [{servers, [a, b]}]}])),
    %% this also tests too "old" heartbeats a bit
    ?assertEqual([a,b,c],
                 actual_down_nodes_inner([a,b,c],
                                         [{"bucket1", [{servers, [a, b]}]}],
                                         NodesDict, 16#100000000000)),
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
