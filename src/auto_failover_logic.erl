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

-export([process_frame/3,
         init_state/1]).

%% number of frames where node that we think is down needs to be down
%% _alone_ in order to trigger autofailover
-define(DOWN_GRACE_PERIOD, 2).

-record(node_state, {
          name :: term(),
          down_counter = 0 :: non_neg_integer(),
          state :: removed|new|half_down|nearly_down|failover|up,
          % Whether are down_warning for this node was already
          % mailed or not
          mailed_down_warning = false :: boolean()
         }).

-record(state, {
          nodes_states :: [#node_state{}],
          mailed_too_small_cluster :: integer(),
          down_threshold :: pos_integer()
         }).

init_state(DownThreshold) ->
    #state{nodes_states = [],
           mailed_too_small_cluster = 0,
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

increment_down_state(NodeState, DownNodes, BigState, SizeChanged) ->
    case {NodeState#node_state.state, SizeChanged} of
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


process_frame(Nodes, DownNodes, State) ->
    SortedNodes = ordsets:from_list(Nodes),
    SortedDownNodes = ordsets:from_list(DownNodes),
    SizeChanged = (length(Nodes) =/= length(State#state.nodes_states)),
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
                NewState = increment_down_state(NodeState, DownNodes, State, SizeChanged),
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
                ClusterSize = length(Nodes),
                case ClusterSize > 2 of
                    true ->
                        %% doing failover
                        {[{failover, Node}], DownStates};
                    false ->
                        case State#state.mailed_too_small_cluster =:= ClusterSize of
                            true ->
                                {[], DownStates};
                            false ->
                                {[{mail_too_small, Node}], DownStates}
                        end
                end;
            [#node_state{state = nearly_down}] -> {[], DownStates};
            Else ->
                case HasNearlyDown of
                    true ->
                        % Return separate events for all nodes that are down,
                        % which haven't been sent already.
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
                                                [{mail_too_small, _}] -> length(Nodes);
                                                _ -> State#state.mailed_too_small_cluster
                                            end
                },
    case Actions of
        [] -> ok;
        _ ->
            ?log_debug("Decided on following actions: ~p", [Actions])
    end,
    {Actions, NewState}.


-ifdef(EUNIT).

process_frame_no_action(0, _Nodes, _DownNodes, State) ->
    State;
process_frame_no_action(Times, Nodes, DownNodes, State) ->
    {[], NewState} = process_frame(Nodes, DownNodes, State),
    process_frame_no_action(Times-1, Nodes, DownNodes, NewState).

basic_1_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [], State0),
    State2 = process_frame_no_action(4, [a,b,c], [b], State1),
    {[{failover, b}], _} = process_frame([a,b,c], [b], State2).

basic_2_test() ->
    State0 = init_state(4+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [b], State0),
    State2 = process_frame_no_action(4, [a,b,c], [b], State1),
    {[{failover, b}], _} = process_frame([a,b,c], [b], State2).

min_size_test_body(Threshold) ->
    State0 = init_state(Threshold+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b], [b], State0),
    State2 = process_frame_no_action(Threshold, [a,b], [b], State1),
    {[{mail_too_small, _}], State3} = process_frame([a,b], [b], State2),
    process_frame_no_action(30, [a,b], [b], State3).

min_size_test() ->
    min_size_test_body(2),
    min_size_test_body(3),
    min_size_test_body(4).

min_size_and_increasing_test() ->
    State = min_size_test_body(2),
    State2 = process_frame_no_action(3, [a,b,c], [b], State),
    {[{failover, b}], _} = process_frame([a,b,c], [b], State2).

other_down_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [b], State0),
    State2 = process_frame_no_action(3, [a,b,c], [b], State1),
    {[{mail_down_warning, _}], State3} = process_frame([a,b,c], [b,c], State2),
    State4 = process_frame_no_action(1, [a,b,c], [b], State3),
    {[{failover, b}], _} = process_frame([a,b,c], [b], State4),
    {[], State5} = process_frame([a,b,c],[b,c], State4),
    State6 = process_frame_no_action(1, [a,b,c], [b], State5),
    {[{failover, b}], _} = process_frame([a,b,c],[b], State6).

two_down_at_same_time_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    State1 = process_frame_no_action(2, [a,b,c,d], [b,c], State0),
    {[{mail_down_warning, b}, {mail_down_warning, c}], _} =
        process_frame([a,b,c,d], [b,c], State1).

multiple_mail_down_warning_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [b], State0),
    State2 = process_frame_no_action(2, [a,b,c], [b], State1),
    {[{mail_down_warning, b}], State3} = process_frame([a,b,c], [b,c], State2),
    % Make sure not every tick sends out a message
    State4 = process_frame_no_action(1, [a,b,c], [b,c], State3),
    {[{mail_down_warning, c}], _} = process_frame([a,b,c], [b,c], State4).

% Test if mail_down_warning is sent again if node was up in between
mail_down_warning_down_up_down_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [b], State0),
    State2 = process_frame_no_action(2, [a,b,c], [b], State1),
    {[{mail_down_warning, b}], State3} = process_frame([a,b,c], [b,c], State2),
    % Node is up again
    State4 = process_frame_no_action(1, [a,b,c], [], State3),
    State5 = process_frame_no_action(2, [a,b,c], [b], State4),
    {[{mail_down_warning, b}], _} = process_frame([a,b,c], [b,c], State5).

-endif.
