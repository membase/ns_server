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

-record(node_state, {
          name :: term(),
          down_counter = 0 :: non_neg_integer(),
          state :: removed|new|half_down|nearly_down|failover|up,
          %% Whether are down_warning for this node was already
          %% mailed or not
          mailed_down_warning = false :: boolean()
         }).

-record(state, {
          nodes_states :: [#node_state{}],
          mailed_too_small_cluster :: list(),
          down_threshold :: pos_integer()
         }).

init_state(DownThreshold) ->
    #state{nodes_states = [],
           mailed_too_small_cluster = [],
           down_threshold = DownThreshold - 1 - ?DOWN_GRACE_PERIOD}.

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

increment_down_state(NodeState, DownNodes, BigState, NodesChanged) ->
    case {NodeState#node_state.state, NodesChanged} of
        {new, _} -> NodeState#node_state{state = half_down};
        {up, _} -> NodeState#node_state{state = half_down};
        {_, true} ->
            NodeState#node_state{state = half_down,
                                 down_counter = 0};
        {half_down, _} ->
            NewCounter = NodeState#node_state.down_counter + 1,
            case NewCounter >= BigState#state.down_threshold of
                true ->
                    NodeState#node_state{down_counter = 0,
                                         state = nearly_down};
                _ ->
                    NodeState#node_state{down_counter = NewCounter}
            end;
        {nearly_down, _} ->
            case DownNodes of
                [_,_|_] ->
                    NodeState#node_state{down_counter = 0};
                [_] ->
                    NewCounter = NodeState#node_state.down_counter + 1,
                    case NewCounter >= ?DOWN_GRACE_PERIOD of
                        true -> NodeState#node_state{state = failover};
                        _ -> NodeState#node_state{down_counter = NewCounter}
                    end
            end;
        {failover, _} ->
            NodeState
    end.


process_frame(Nodes, DownNodes, State, SvcConfig) ->
    SortedNodes = ordsets:from_list(Nodes),
    SortedDownNodes = ordsets:from_list(DownNodes),

    PrevNodes = [NS#node_state.name || NS <- State#state.nodes_states],
    NodesChanged = (SortedNodes =/= ordsets:from_list(PrevNodes)),

    UpNodes = ordsets:subtract(SortedNodes, SortedDownNodes),
    UpFun =
        fun (#node_state{state = removed}, Acc) -> Acc;
            (NodeState, Acc) ->
                case NodeState#node_state.state of
                    up -> ok;
                    Prev ->
                        ?log_debug("Transitioned node ~p state ~p -> up", [NodeState#node_state.name, Prev])
                end,
                [NodeState#node_state{state = up,
                                      down_counter = 0,
                                      mailed_down_warning = false}
                 | Acc]
        end,
    UpStates0 = fold_matching_nodes(UpNodes, State#state.nodes_states, UpFun, []),
    UpStates = lists:reverse(UpStates0),
    DownFun =
        fun (#node_state{state = removed}, Acc) -> Acc;
            (NodeState, Acc) ->
                NewState = increment_down_state(NodeState, DownNodes, State, NodesChanged),
                ?log_debug("Incremented down state:~n~p~n->~p", [NodeState, NewState]),
                [NewState | Acc]
        end,
    DownStates0 = fold_matching_nodes(DownNodes, State#state.nodes_states, DownFun, []),
    DownStates = lists:reverse(DownStates0),
    HasNearlyDown =
        lists:any(fun (#node_state{state = nearly_down}) -> true;
                      (_) -> false
                  end, DownStates),
    {Actions, DownStates2} =
        case DownStates of
            [#node_state{state = failover, name = Node}] ->
                ServiceAction = should_failover_node(State, Node, SvcConfig),
                {ServiceAction, DownStates};
            [#node_state{state = nearly_down}] -> {[], DownStates};
            Else ->
                case HasNearlyDown of
                    true ->
                        %% Return separate events for all nodes that are down,
                        %% which haven't been sent already.
                        {Actions2, DownStates3} = lists:foldl(
                                                    fun (#node_state{state = nearly_down,
                                                                     name = Node,
                                                                     mailed_down_warning = false}=S,
                                                         {Warnings, DS}) ->
                                                            {[{mail_down_warning, Node}|Warnings],
                                                             [S#node_state{mailed_down_warning = true}|DS]};
                                                        %% Warning was already sent
                                                        (S, {Warnings, DS}) ->
                                                            {Warnings, [S|DS]}
                                                    end, {[], []}, Else),
                        {lists:reverse(Actions2), lists:reverse(DownStates3)};
                    _ ->
                        {[], DownStates}
                end
        end,
    NewState = State#state{
                 nodes_states = lists:umerge(UpStates, DownStates2),
                 mailed_too_small_cluster = case Actions of
                                                [{mail_too_small, _, SvcNodes, _}] -> SvcNodes;
                                                _ -> State#state.mailed_too_small_cluster
                                            end
                },
    case Actions of
        [] -> ok;
        _ ->
            ?log_debug("Decided on following actions: ~p", [Actions])
    end,
    {Actions, NewState}.

%% Decide whether to failover the node based on the services running
%% on the node.
should_failover_node(State, Node, SvcConfig) ->
    %% Find what services are running on the node
    {NodeName, _ID} = Node,
    NodeSvc = get_node_services(NodeName, SvcConfig, []),
    %% Is this a dedicated node running only one service or collocated
    %% node running multiple services?
    case length(NodeSvc) of
        1 ->
            %% Only one service running on this node, so follow its
            %% auto-failover policy.
            should_failover_service(State, SvcConfig, hd(NodeSvc), Node);
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
            []
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
            case State#state.mailed_too_small_cluster =:= SvcNodes of
                true ->
                    [];
                false ->
                    %% TODO:
                    %% Translate "Service" for user_log consumption
                    %% e.g. translate "kv" to "data"
                    [{mail_too_small, Service, SvcNodes, Node}]
            end
    end.

%% Helper to get the minimum node count.
service_failover_min_node_count(kv) ->
    ?AUTO_FAILOVER_KV_NODE_COUNT;
service_failover_min_node_count(index) ->
    ?AUTO_FAILOVER_INDEX_NODE_COUNT;
service_failover_min_node_count(n1ql) ->
    ?AUTO_FAILOVER_N1QL_NODE_COUNT.

-ifdef(EUNIT).

process_frame_no_action(0, _Nodes, _DownNodes, State, _SvcConfig) ->
    State;
process_frame_no_action(Times, Nodes, DownNodes, State, SvcConfig) ->
    {[], NewState} = process_frame(Nodes, DownNodes, State, SvcConfig),
    process_frame_no_action(Times-1, Nodes, DownNodes, NewState, SvcConfig).

build_svc_config([], _, _, Acc) ->
    Acc;
build_svc_config([Service | Rest], AutoFailoverDisabled, Nodes, Acc) ->
    PerSvcCfg = {Service, {{disable_auto_failover, AutoFailoverDisabled},
                           {nodes, Nodes}}},
    build_svc_config(Rest, AutoFailoverDisabled, Nodes, [PerSvcCfg | Acc]).

attach_uuid(Nodes) ->
    lists:map(fun(X) -> {X, list_to_binary(atom_to_list(X))} end, Nodes).

basic_kv_1_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    SvcConfig = build_svc_config([kv], false, [a,b,c], []),
    Nodes = attach_uuid([a,b,c]),
    DownNode = attach_uuid([b]),
    {[], State1} = process_frame(Nodes, [], State0, SvcConfig),
    State2 = process_frame_no_action(4, Nodes, DownNode, State1, SvcConfig),
    DN = hd(DownNode),
    {[{failover, DN}], _} = process_frame(Nodes, DownNode, State2, SvcConfig).

basic_kv_2_test() ->
    State0 = init_state(4+?DOWN_GRACE_PERIOD),
    SvcConfig = build_svc_config([kv], false, [a,b,c], []),
    Nodes = attach_uuid([a,b,c]),
    DownNode = attach_uuid([b]),
    {[], State1} = process_frame(Nodes, DownNode, State0, SvcConfig),
    State2 = process_frame_no_action(4, Nodes, DownNode, State1, SvcConfig),
    DN = hd(DownNode),
    {[{failover, DN}], _} = process_frame(Nodes, DownNode, State2, SvcConfig).

min_size_test_body(Threshold) ->
    State0 = init_state(Threshold+?DOWN_GRACE_PERIOD),
    SvcConfig = build_svc_config([kv], false, [a,b], []),
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
    SvcConfig = build_svc_config([kv], false, [a,b,c], []),
    Nodes = attach_uuid([a,b,c]),
    DownNode = attach_uuid([b]),
    State2 = process_frame_no_action(3, Nodes, DownNode, State, SvcConfig),
    DN = hd(DownNode),
    {[{failover, DN}], _} = process_frame(Nodes, DownNode, State2, SvcConfig).

other_down_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    SvcConfig = build_svc_config([kv], false, [a,b,c], []),
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
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    SvcConfig = build_svc_config([kv], false, [a,b,c,d], []),
    Nodes = attach_uuid([a,b,c,d]),
    DownNode2 = attach_uuid([b, c]),
    State1 = process_frame_no_action(2, Nodes, DownNode2, State0, SvcConfig),
    [B, C] = DownNode2,
    {[{mail_down_warning, B}, {mail_down_warning, C}], _} =
        process_frame(Nodes, DownNode2, State1, SvcConfig).

multiple_mail_down_warning_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    SvcConfig = build_svc_config([kv], false, [a,b,c], []),
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
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    SvcConfig = build_svc_config([kv], false, [a,b,c], []),
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
