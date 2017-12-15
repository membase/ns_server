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
-module(auto_failover_logic).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").

-export([process_frame/4,
         init_state/1,
         service_failover_min_node_count/1]).

%% number of frames where node that we think is down needs to be down
%% _alone_ in order to trigger autofailover
-define(DOWN_GRACE_PERIOD, 2).

%% Auto-failover is possible for a service only if the number of nodes
%% in the cluster running that service is greater than the count specified
%% below.
%% E.g. to auto-failover kv (data) service, cluster needs atleast 3 data nodes.
-define(AUTO_FAILOVER_KV_NODE_COUNT, 2).
-define(AUTO_FAILOVER_INDEX_NODE_COUNT, 1).
-define(AUTO_FAILOVER_N1QL_NODE_COUNT, 1).
-define(AUTO_FAILOVER_FTS_NODE_COUNT, 1).
-define(AUTO_FAILOVER_EVENTING_NODE_COUNT, 1).
-define(AUTO_FAILOVER_CBAS_NODE_COUNT, 1).
-define(AUTO_FAILOVER_EXAMPLE_NODE_COUNT, 1).

-record(node_state, {
          name :: term(),
          down_counter = 0 :: non_neg_integer(),
          state :: removed|new|half_down|nearly_down|failover|up,
          %% Whether are down_warning for this node was already
          %% mailed or not
          mailed_down_warning = false :: boolean()
         }).

-record(service_state, {
          name :: term(),
          %% List of nodes running this service when the "too small cluster"
          %% event was generated.
          mailed_too_small_cluster :: list(),
          %% Have we already logged the auto_failover_disabled message
          %% for this service?
          logged_auto_failover_disabled = false :: boolean()
         }).

-record(state, {
          nodes_states :: [#node_state{}],
          services_state :: [#service_state{}],
          down_threshold :: pos_integer()
         }).

init_state(DownThreshold) ->
    init_state(DownThreshold, cluster_compat_mode:get_compat_version()).

init_state(DownThreshold, CompatVersion) ->
    #state{nodes_states = [],
           services_state = init_services_state(CompatVersion),
           down_threshold = DownThreshold - 1 - ?DOWN_GRACE_PERIOD}.

init_services_state(CompatVersion) ->
    lists:map(
      fun (Service) ->
              #service_state{name = Service,
                             mailed_too_small_cluster = [],
                             logged_auto_failover_disabled = false}
      end, ns_cluster_membership:supported_services_for_version(CompatVersion)).

fold_matching_nodes([], NodeStates, Fun, Acc) ->
    lists:foldl(fun (S, A) ->
                        Fun(S#node_state{state = removed}, A)
                end, Acc, NodeStates);
fold_matching_nodes([Node | RestNodes], [], Fun, Acc) ->
    NewAcc = Fun(#node_state{name = Node,
                             state = new},
                 Acc),
    fold_matching_nodes(RestNodes, [], Fun, NewAcc);
fold_matching_nodes([Node | RestNodes] = AllNodes,
                    [#node_state{name = Name} = NodeState | RestStates] = States,
                    Fun, Acc) ->
    case Node < Name of
        true ->
            NewAcc = Fun(#node_state{name = Node,
                                     state = new},
                         Acc),
            fold_matching_nodes(RestNodes, States, Fun, NewAcc);
        false ->
            case Node =:= Name of
                false ->
                    NewAcc = Fun(NodeState#node_state{state = removed}, Acc),
                    fold_matching_nodes(AllNodes, RestStates, Fun, NewAcc);
                _ ->
                    NewAcc = Fun(NodeState, Acc),
                    fold_matching_nodes(RestNodes, RestStates, Fun, NewAcc)
            end
    end.

process_down_state(NodeState, Threshold, NewState, ResetCounter) ->
    CurrCounter = NodeState#node_state.down_counter,
    NewCounter = CurrCounter + 1,
    case NewCounter >= Threshold of
        true ->
            Counter = case ResetCounter of
                          true ->
                              0;
                          false ->
                              CurrCounter
                      end,
            NodeState#node_state{down_counter = Counter, state = NewState};
        _ ->
            NodeState#node_state{down_counter = NewCounter}
    end.

increment_down_state(NodeState, DownNodes, BigState, NodesChanged) ->
    case {NodeState#node_state.state, NodesChanged} of
        {new, _} ->
            NodeState#node_state{state = half_down};
        {up, _} ->
            NodeState#node_state{state = half_down};
        {_, true} ->
            NodeState#node_state{state = half_down, down_counter = 0};
        {half_down, _} ->
            process_down_state(NodeState, BigState#state.down_threshold,
                               nearly_down, true);
        {nearly_down, _} ->
            case DownNodes of
                [_,_|_] ->
                    NodeState#node_state{down_counter = 0};
                [_] ->
                    process_down_state(NodeState, ?DOWN_GRACE_PERIOD,
                                       failover, false)
            end;
        {failover, _} ->
            NodeState
    end.

log_master_activity(#node_state{state = _Same, down_counter = _SameCounter},
                    #node_state{state = _Same, down_counter = _SameCounter}) ->
    ok;
log_master_activity(#node_state{state = Prev, name = {Node, _} = Name} = NodeState,
                    #node_state{state = New, down_counter = NewCounter} = NewState) ->
    case New of
        up ->
            false = Prev =:= up,
            ?log_debug("Transitioned node ~p state ~p -> up", [Name, Prev]);
        _ ->
            ?log_debug("Incremented down state:~n~p~n->~p", [NodeState,
                                                             NewState])
    end,
    master_activity_events:note_autofailover_node_state_change(Node, Prev,
                                                               New, NewCounter).
get_up_states(UpNodes, NodeStates) ->
    UpFun =
        fun (#node_state{state = removed}, Acc) -> Acc;
            (NodeState, Acc) ->
                NewUpState = NodeState#node_state{state = up,
                                                  down_counter = 0,
                                                  mailed_down_warning = false},
                log_master_activity(NodeState, NewUpState),
                [NewUpState | Acc]
        end,
    UpStates0 = fold_matching_nodes(UpNodes, NodeStates, UpFun, []),
    lists:reverse(UpStates0).

get_down_states(DownNodes, State, NodesChanged) ->
    DownFun =
        fun (#node_state{state = removed}, Acc) -> Acc;
            (NodeState, Acc) ->
                NewState = increment_down_state(NodeState, DownNodes,
                                                State, NodesChanged),
                log_master_activity(NodeState, NewState),
                [NewState | Acc]
        end,
    DownStates0 = fold_matching_nodes(DownNodes, State#state.nodes_states,
                                      DownFun, []),
    lists:reverse(DownStates0).

process_frame(Nodes, DownNodes, State, SvcConfig) ->
    SortedNodes = ordsets:from_list(Nodes),
    SortedDownNodes = ordsets:from_list(DownNodes),

    PrevNodes = [NS#node_state.name || NS <- State#state.nodes_states],
    NodesChanged = (SortedNodes =/= ordsets:from_list(PrevNodes)),

    UpStates = get_up_states(ordsets:subtract(SortedNodes, SortedDownNodes),
                             State#state.nodes_states),
    DownStates = get_down_states(DownNodes, State, NodesChanged),

    {Actions, NewDownStates} = process_node_down(DownStates, State, SvcConfig),

    NodeStates = lists:umerge(UpStates, NewDownStates),
    SvcS = update_services_state(Actions, State#state.services_state),

    case Actions of
        [] ->
            ok;
        _ ->
            ?log_debug("Decided on following actions: ~p", [Actions])
    end,
    {Actions, State#state{nodes_states = NodeStates, services_state = SvcS}}.

process_node_down([#node_state{state = failover, name = Node}] = DownStates,
                  State, SvcConfig) ->
    {should_failover_node(State, Node, SvcConfig), DownStates};
process_node_down([#node_state{state = nearly_down}] = DownStates, _, _) ->
    {[], DownStates};
process_node_down(DownStates, _, _) ->
    Fun = fun (#node_state{state = nearly_down}) -> true; (_) -> false end,
    case lists:any(Fun, DownStates) of
        true ->
            process_multiple_nodes_down(DownStates);
        _ ->
            {[], DownStates}
    end.

%% Return separate events for all nodes that are down.
process_multiple_nodes_down(DownStates) ->
    {Actions, NewDownStates} =
        lists:foldl(
          fun (#node_state{state = nearly_down, name = Node,
                           mailed_down_warning = false} = S, {Warnings, DS}) ->
                  {[{mail_down_warning, Node} | Warnings],
                   [S#node_state{mailed_down_warning = true} | DS]};
              %% Warning was already sent
              (S, {Warnings, DS}) ->
                  {Warnings, [S | DS]}
          end, {[], []}, DownStates),
    {lists:reverse(Actions), lists:reverse(NewDownStates)}.

%% Update mailed_too_small_cluster state
%% At any time, only one node can have mail_too_small Action.
update_services_state([{mail_too_small, Svc, SvcNodes, _}], ServicesState) ->
    MTSFun =
        fun (S) ->
                S#service_state{mailed_too_small_cluster = SvcNodes}
        end,
    update_services_state_inner(ServicesState, Svc, MTSFun);

%% Update mail_auto_failover_disabled state
%% At any time, only one node can have mail_auto_failover_disabled Action.
update_services_state([{mail_auto_failover_disabled, Svc, _}], ServicesState) ->
    LogAFOFun =
        fun (S) ->
                S#service_state{logged_auto_failover_disabled = true}
        end,
    update_services_state_inner(ServicesState, Svc, LogAFOFun);

%% Do not update services state for other Actions
update_services_state(_, ServicesState) ->
    ServicesState.

update_services_state_inner(ServicesState, Svc, Fun) ->
    case lists:keyfind(Svc, #service_state.name, ServicesState) of
        false ->
            exit(node_running_unknown_service);
        S ->
            lists:keyreplace(Svc, #service_state.name, ServicesState, Fun(S))
    end.

%% Decide whether to failover the node based on the services running
%% on the node.
should_failover_node(State, Node, SvcConfig) ->
    %% Find what services are running on the node
    {NodeName, _ID} = Node,
    NodeSvc = get_node_services(NodeName, SvcConfig, []),
    %% Is this a dedicated node running only one service or collocated
    %% node running multiple services?
    case NodeSvc of
        [Service] ->
            %% Only one service running on this node, so follow its
            %% auto-failover policy.
            should_failover_service(State, SvcConfig, Service, Node);
        _ ->
            %% Node is running multiple services.
            should_failover_colocated_node(State, SvcConfig, NodeSvc, Node)
    end.

get_node_services(_, [], Acc) ->
    Acc;
get_node_services(NodeName, [ServiceInfo | Rest], Acc) ->
    {Service, {_, {nodes, NodesList}}} = ServiceInfo,
    case lists:member(NodeName, NodesList) of
        true ->
            get_node_services(NodeName, Rest, [Service | Acc]);
        false ->
            get_node_services(NodeName, Rest,  Acc)
    end.


should_failover_colocated_node(State, SvcConfig, NodeSvc, Node) ->
    %% Is data one of the services running on the node?
    %% If yes, then we give preference to its auto-failover policy
    %% otherwise we treat all other servcies equally.
    case lists:member(kv, NodeSvc) of
        true ->
            should_failover_service(State, SvcConfig, kv, Node);
        false ->
            should_failover_colocated_service(State, SvcConfig, NodeSvc, Node)
    end.

%% Iterate through all services running on this node and check if
%% each of those services can be failed over.
%% Auto-failover the node only if ok to auto-failover all the services running
%% on the node.
should_failover_colocated_service(_, _, [], Node) ->
    [{failover, Node}];
should_failover_colocated_service(State, SvcConfig, [Service | Rest], Node) ->
    %% OK to auto-failover this service? If yes, then go to the next one.
    case should_failover_service(State, SvcConfig, Service, Node) of
        [{failover, Node}] ->
            should_failover_colocated_service(State, SvcConfig, Rest, Node);
        Else ->
            Else
    end.

should_failover_service(State, SvcConfig, Service, Node) ->
    %% Check whether auto-failover is disabled for the service.
    case is_failover_disabled_for_service(SvcConfig, Service) of
        false ->
            should_failover_service_policy(State, SvcConfig, Service, Node);
        true ->
            ?log_debug("Auto-failover for ~p service is disabled.~n",
                       [Service]),
            LogFun =
                fun (S) ->
                        S#service_state.logged_auto_failover_disabled =:= false
                end,
            case check_if_action_needed(State#state.services_state,
                                        Service, LogFun) of
                true ->
                    [{mail_auto_failover_disabled, Service, Node}];
                false ->
                    []
            end
    end.

is_failover_disabled_for_service(SvcConfig, Service) ->
    {{disable_auto_failover, V}, _} = proplists:get_value(Service, SvcConfig),
    V.

%% Determine whether to failover the service based on
%% how many nodes in the cluster are running the same service and
%% whether that count is above the the minimum required by the service.
should_failover_service_policy(State, SvcConfig, Service, Node) ->
    {_, {nodes, SvcNodes}} = proplists:get_value(Service, SvcConfig),
    SvcNodeCount = length(SvcNodes),
    case SvcNodeCount > service_failover_min_node_count(Service) of
        true ->
            %% doing failover
            [{failover, Node}];
        false ->
            %% Send mail_too_small only if the new set of nodes
            %% running the service do not match the list of nodes
            %% when the last time the event was generated for this
            %% service.
            MTSFun =
                fun (S) ->
                        S#service_state.mailed_too_small_cluster =/= SvcNodes
                end,
            case check_if_action_needed(State#state.services_state,
                                        Service, MTSFun) of
                false ->
                    [];
                true ->
                    [{mail_too_small, Service, SvcNodes, Node}]
            end
    end.

%% Check the existing state of services to decide if need to
%% take any action.
check_if_action_needed(ServicesState, Service, ActFun) ->
    case lists:keyfind(Service, #service_state.name, ServicesState) of
        false ->
            exit(node_running_unknown_service);
        S ->
            ActFun(S)
    end.

%% Helper to get the minimum node count.
service_failover_min_node_count(kv) ->
    ?AUTO_FAILOVER_KV_NODE_COUNT;
service_failover_min_node_count(index) ->
    ?AUTO_FAILOVER_INDEX_NODE_COUNT;
service_failover_min_node_count(n1ql) ->
    ?AUTO_FAILOVER_N1QL_NODE_COUNT;
service_failover_min_node_count(fts) ->
    ?AUTO_FAILOVER_FTS_NODE_COUNT;
service_failover_min_node_count(eventing) ->
    ?AUTO_FAILOVER_EVENTING_NODE_COUNT;
service_failover_min_node_count(cbas) ->
    ?AUTO_FAILOVER_CBAS_NODE_COUNT;
service_failover_min_node_count(example) ->
    ?AUTO_FAILOVER_EXAMPLE_NODE_COUNT.

-ifdef(EUNIT).

service_failover_min_node_count_test() ->
    Services = ns_cluster_membership:supported_services(),
    lists:foreach(
      fun (Service) ->
              true = is_integer(service_failover_min_node_count(Service))
      end, Services).

process_frame_no_action(0, _Nodes, _DownNodes, State, _SvcConfig) ->
    State;
process_frame_no_action(Times, Nodes, DownNodes, State, SvcConfig) ->
    {[], NewState} = process_frame(Nodes, DownNodes, State, SvcConfig),
    process_frame_no_action(Times-1, Nodes, DownNodes, NewState, SvcConfig).

build_svc_config(AllServices, AutoFailoverDisabled, Nodes) ->
    lists:map(
      fun (Service) ->
              {Service, {{disable_auto_failover, AutoFailoverDisabled},
                         {nodes, Nodes}}}
      end, AllServices).

attach_uuid(Nodes) ->
    lists:map(fun(X) -> {X, list_to_binary(atom_to_list(X))} end, Nodes).

basic_kv_1_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD, ?LATEST_VERSION_NUM),
    SvcConfig = build_svc_config([kv], false, [a,b,c]),
    Nodes = attach_uuid([a,b,c]),
    DownNode = attach_uuid([b]),
    {[], State1} = process_frame(Nodes, [], State0, SvcConfig),
    State2 = process_frame_no_action(4, Nodes, DownNode, State1, SvcConfig),
    DN = hd(DownNode),
    {[{failover, DN}], _} = process_frame(Nodes, DownNode, State2, SvcConfig).

basic_kv_2_test() ->
    State0 = init_state(4+?DOWN_GRACE_PERIOD, ?LATEST_VERSION_NUM),
    SvcConfig = build_svc_config([kv], false, [a,b,c]),
    Nodes = attach_uuid([a,b,c]),
    DownNode = attach_uuid([b]),
    {[], State1} = process_frame(Nodes, DownNode, State0, SvcConfig),
    State2 = process_frame_no_action(4, Nodes, DownNode, State1, SvcConfig),
    DN = hd(DownNode),
    {[{failover, DN}], _} = process_frame(Nodes, DownNode, State2, SvcConfig).

min_size_test_body(Threshold) ->
    State0 = init_state(Threshold+?DOWN_GRACE_PERIOD, ?LATEST_VERSION_NUM),
    SvcConfig = build_svc_config([kv], false, [a,b]),
    Nodes = attach_uuid([a,b]),
    DownNode = attach_uuid([b]),
    {[], State1} = process_frame(Nodes, DownNode, State0, SvcConfig),
    State2 = process_frame_no_action(Threshold, Nodes, DownNode, State1, SvcConfig),
    {[{mail_too_small, _, _, _}], State3} = process_frame(Nodes, DownNode, State2, SvcConfig),
    process_frame_no_action(30, Nodes, DownNode, State3, SvcConfig).

min_size_test() ->
    min_size_test_body(2),
    min_size_test_body(3),
    min_size_test_body(4).

min_size_and_increasing_test() ->
    State = min_size_test_body(2),
    SvcConfig = build_svc_config([kv], false, [a,b,c]),
    Nodes = attach_uuid([a,b,c]),
    DownNode = attach_uuid([b]),
    State2 = process_frame_no_action(3, Nodes, DownNode, State, SvcConfig),
    DN = hd(DownNode),
    {[{failover, DN}], _} = process_frame(Nodes, DownNode, State2, SvcConfig).

other_down_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD, ?LATEST_VERSION_NUM),
    SvcConfig = build_svc_config([kv], false, [a,b,c]),
    Nodes = attach_uuid([a,b,c]),
    DownNode1 = attach_uuid([b]),
    {[], State1} = process_frame(Nodes, DownNode1, State0, SvcConfig),
    State2 = process_frame_no_action(3, Nodes, DownNode1, State1, SvcConfig),
    DownNode2 = attach_uuid([b, c]),
    {[{mail_down_warning, _}], State3} = process_frame(Nodes, DownNode2, State2, SvcConfig),
    State4 = process_frame_no_action(1, Nodes, DownNode1, State3, SvcConfig),
    DN = hd(DownNode1),
    {[{failover, DN}], _} = process_frame(Nodes, DownNode1, State4, SvcConfig),
    {[], State5} = process_frame(Nodes, DownNode2, State4, SvcConfig),
    State6 = process_frame_no_action(1, Nodes, DownNode1, State5, SvcConfig),
    {[{failover, DN}], _} = process_frame(Nodes, DownNode1, State6, SvcConfig).

two_down_at_same_time_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD, ?LATEST_VERSION_NUM),
    SvcConfig = build_svc_config([kv], false, [a,b,c,d]),
    Nodes = attach_uuid([a,b,c,d]),
    DownNode2 = attach_uuid([b, c]),
    State1 = process_frame_no_action(2, Nodes, DownNode2, State0, SvcConfig),
    [B, C] = DownNode2,
    {[{mail_down_warning, B}, {mail_down_warning, C}], _} =
        process_frame(Nodes, DownNode2, State1, SvcConfig).

multiple_mail_down_warning_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD, ?LATEST_VERSION_NUM),
    SvcConfig = build_svc_config([kv], false, [a,b,c]),
    Nodes = attach_uuid([a,b,c]),
    DownNode1 = attach_uuid([b]),
    {[], State1} = process_frame(Nodes, DownNode1, State0, SvcConfig),
    State2 = process_frame_no_action(2, Nodes, DownNode1, State1, SvcConfig),
    DownNode2 = attach_uuid([b, c]),
    [B, C] = DownNode2,
    {[{mail_down_warning, B}], State3} = process_frame(Nodes, DownNode2, State2, SvcConfig),
    %% Make sure not every tick sends out a message
    State4 = process_frame_no_action(1, Nodes, DownNode2, State3, SvcConfig),
    {[{mail_down_warning, C}], _} = process_frame(Nodes, DownNode2, State4, SvcConfig).

%% Test if mail_down_warning is sent again if node was up in between
mail_down_warning_down_up_down_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD, ?LATEST_VERSION_NUM),
    SvcConfig = build_svc_config([kv], false, [a,b,c]),
    Nodes = attach_uuid([a,b,c]),
    DownNode1 = attach_uuid([b]),
    {[], State1} = process_frame(Nodes, DownNode1, State0, SvcConfig),
    State2 = process_frame_no_action(2, Nodes, DownNode1, State1, SvcConfig),
    DN = hd(DownNode1),
    DownNode2 = attach_uuid([b, c]),
    {[{mail_down_warning, DN}], State3} = process_frame(Nodes, DownNode2, State2, SvcConfig),
    %% Node is up again
    State4 = process_frame_no_action(1, Nodes, [], State3, SvcConfig),
    State5 = process_frame_no_action(2, Nodes, DownNode1, State4, SvcConfig),
    {[{mail_down_warning, DN}], _} = process_frame(Nodes, DownNode2, State5, SvcConfig).

-endif.
