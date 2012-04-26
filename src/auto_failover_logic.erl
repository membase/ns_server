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
         init_state/1]).

%% number of frames where node that we think is down needs to be down
%% _alone_ in order to trigger autofailover
-define(DOWN_GRACE_PERIOD, 2).

-record(node_state, {
          name :: atom(),
          down_counter = 0 :: non_neg_integer(),
          state :: removed|new|half_down|nearly_down|failover|up,
          % Whether are down_warning for this node was alrady
          % mailed or not
          mailed_down_warning = false :: boolean()
         }).

-record(state, {
          nodes_states :: [#node_state{}],
          mailed_too_small_cluster :: integer(),
          down_threshold :: pos_integer(),
          %% this flag indicates that rebalance_prevented_failover
          %% warning was sent out. We reset it back to false when we
          %% don't have 'desire' to autofailover anymore that's
          %% prevented by rebalance. Like when node becames healthy
          %% again. Or rebalance is stopped/completed. Or additional
          %% nodes become down preventing any auto-failover.
          rebalance_prevented_failover = false :: boolean()
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
    NewAcc = Fun(#node_state{name=Node,
                             state = new},
                 Acc),
    fold_matching_nodes(RestNodes, [], Fun, NewAcc);
fold_matching_nodes([Node | RestNodes] = AllNodes,
                    [#node_state{name=Name} = NodeState | RestStates] = States,
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


process_frame(Nodes, DownNodes, State, RebalanceRunning) ->
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
    {Actions0, DownStates2} =
        case DownStates of
            [#node_state{state = failover, name = Node}] ->
                ClusterSize = length(Nodes),
                case {ClusterSize > 2, RebalanceRunning} of
                    {true, false} ->
                        %% doing failover
                        {[{failover, Node}], DownStates};
                    {false, _} ->
                        case State#state.mailed_too_small_cluster =:= ClusterSize of
                            true ->
                                {[], DownStates};
                            false ->
                                {[{mail_too_small, Node}], DownStates}
                        end;
                    {_, true} ->
                        {[{rebalance_prevented_failover, Node}], DownStates}
                end;
            [#node_state{state = nearly_down}] -> {[], DownStates};
            Else ->
                case HasNearlyDown of
                    true ->
                        % Return separate events for all nodes that are down,
                        % which haven't been sent already.
                        {Actions2, DownStates3} = lists:foldl(
                          fun (#node_state{state=nearly_down,name=Node,
                                           mailed_down_warning=false}=S,
                               {Warnings, DS}) ->
                                  {[{mail_down_warning, Node}|Warnings],
                                   [S#node_state{mailed_down_warning=true}|DS]};
                              %% Warning was already sent
                              (S, {Warnings, DS}) ->
                                  {Warnings, [S|DS]}
                          end, {[], []}, Else),
                          {lists:reverse(Actions2), lists:reverse(DownStates3)};
                    _ ->
                        {[], DownStates}
                end
        end,
    Actions = case State#state.rebalance_prevented_failover of
                  true ->
                      [A || A <- Actions0,
                            case A of
                                %% filter out this if we already sent out this warning
                                {rebalance_prevented_failover, _} -> false;
                                _ -> true
                            end];
                  false ->
                      Actions0
              end,
    NewState = State#state{
                 rebalance_prevented_failover =
                     lists:any(fun ({rebalance_prevented_failover, _}) -> true;
                                   (_) -> false
                               end, Actions0),
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

process_frame_no_action(0, _Nodes, _DownNodes, State, _RebalanceRunning) ->
    State;
process_frame_no_action(Times, Nodes, DownNodes, State, RebalanceRunning) ->
    {[], NewState} = process_frame(Nodes, DownNodes, State, RebalanceRunning),
    process_frame_no_action(Times-1, Nodes, DownNodes, NewState, RebalanceRunning).

basic_1_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [], State0, false),
    State2 = process_frame_no_action(4, [a,b,c], [b], State1, false),
    {[{failover, b}], _} = process_frame([a,b,c], [b], State2, false).

rebalance_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [], State0, false),
    State2 = process_frame_no_action(4, [a,b,c], [b], State1, false),
    %% basic case: we won't autofailover during rebalance
    {[{rebalance_prevented_failover, b}], _} = process_frame([a,b,c], [b], State2, true).

rebalance_2_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [], State0, true),
    State2 = process_frame_no_action(4, [a,b,c], [b], State1, true),
    %% same as basic but note that rebalance was running all the time
    {[{rebalance_prevented_failover, b}], State3} = process_frame([a,b,c], [b], State2, true),
    #state{rebalance_prevented_failover = true} = State3,
    %% now we have reported that we couldn't we still cannot but don't report
    {[], _} = process_frame([a,b,c], [b], State3, true),
    lists:foldl(
      fun (_, State4) ->
              %% and now when rebalance is done we can
              {[{failover, b}], #state{rebalance_prevented_failover = false}} = process_frame([a,b,c], [b], State4, false),
              %% but in parallel world continue rebalance and see how it goes
              {[], #state{rebalance_prevented_failover = true} = State5} = process_frame([a,b,c], [b], State4, true),
              State5
      end, State3, lists:seq(0, 100)).

rebalance_2a_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [], State0, true),
    State2 = process_frame_no_action(4, [a,b,c], [b], State1, true),
    {[{rebalance_prevented_failover, b}], State3} = process_frame([a,b,c], [b], State2, true),
    #state{rebalance_prevented_failover = true} = State3,
    {[], State4} = process_frame([a,b,c], [b], State3, true),
    %% the following checks that we don't lose our internal 'warned about rebalance' flag
    lists:foldl(fun (_, State5) ->
                        {[], FollowingState} = process_frame([a,b,c], [b], State5, true),
                        #state{rebalance_prevented_failover = true} = FollowingState,
                        FollowingState
                end, State4, lists:seq(0, 100)).


rebalance_3_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [], State0, true),
    State2 = process_frame_no_action(4, [a,b,c], [b], State1, true),
    {[{rebalance_prevented_failover, b}], State3} = process_frame([a,b,c], [b], State2, true),
    #state{rebalance_prevented_failover = true} = State3,
    {[], State4} = process_frame([a,b,c], [b], State3, true),
    {[], State5} = process_frame([a,b,c], [b], State4, true),
    %% checking that we reset our 'warned about rebalance flag' if
    %% additional node goes down
    State6 = process_frame_no_action(2, [a,b,c], [b,c], State5, true),
    {[{mail_down_warning, _}], State7} = process_frame([a,b,c], [b,c], State6, true),
    #state{rebalance_prevented_failover = false} = State7,
    %% which implies another message next time
    {[{rebalance_prevented_failover, b}], State8} = process_frame([a,b,c], [b], State7, true),
    #state{rebalance_prevented_failover = true} = State8.

basic_2_test() ->
    State0 = init_state(4+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [b], State0, false),
    State2 = process_frame_no_action(4, [a,b,c], [b], State1, false),
    {[{failover, b}], _} = process_frame([a,b,c], [b], State2, false).

min_size_test_body(Threshold) ->
    State0 = init_state(Threshold+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b], [b], State0, false),
    State2 = process_frame_no_action(Threshold, [a,b], [b], State1, false),
    {[{mail_too_small, _}], State3} = process_frame([a,b], [b], State2, false),
    process_frame_no_action(30, [a,b], [b], State3, false).

min_size_test() ->
    min_size_test_body(2),
    min_size_test_body(3),
    min_size_test_body(4).

min_size_and_increasing_test() ->
    State = min_size_test_body(2),
    State2 = process_frame_no_action(3, [a,b,c], [b], State, false),
    {[{failover, b}], _} = process_frame([a,b,c], [b], State2, false).

other_down_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [b], State0, false),
    State2 = process_frame_no_action(3, [a,b,c], [b], State1, false),
    {[{mail_down_warning, _}], State3} = process_frame([a,b,c], [b,c], State2, false),
    State4 = process_frame_no_action(1, [a,b,c], [b], State3, false),
    {[{failover, b}], _} = process_frame([a,b,c], [b], State4, false),
    {[], State5} = process_frame([a,b,c],[b,c], State4, false),
    State6 = process_frame_no_action(1, [a,b,c], [b], State5, false),
    {[{failover, b}], _} = process_frame([a,b,c],[b], State6, false).

two_down_at_same_time_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    State1 = process_frame_no_action(2, [a,b,c,d], [b,c], State0, false),
    {[{mail_down_warning, b}, {mail_down_warning, c}], _} =
        process_frame([a,b,c,d], [b,c], State1, false).

multiple_mail_down_warning_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [b], State0, false),
    State2 = process_frame_no_action(2, [a,b,c], [b], State1, false),
    {[{mail_down_warning, b}], State3} = process_frame([a,b,c], [b,c], State2, false),
    % Make sure not every tick sends out a message
    State4 = process_frame_no_action(1, [a,b,c], [b,c], State3, false),
    {[{mail_down_warning, c}], _} = process_frame([a,b,c], [b,c], State4, false).

% Test if mail_down_warning is sent again if node was up in between
mail_down_warning_down_up_down_test() ->
    State0 = init_state(3+?DOWN_GRACE_PERIOD),
    {[], State1} = process_frame([a,b,c], [b], State0, false),
    State2 = process_frame_no_action(2, [a,b,c], [b], State1, false),
    {[{mail_down_warning, b}], State3} = process_frame([a,b,c], [b,c], State2, false),
    % Node is up again
    State4 = process_frame_no_action(1, [a,b,c], [], State3, false),
    State5 = process_frame_no_action(2, [a,b,c], [b], State4, false),
    {[{mail_down_warning, b}], _} = process_frame([a,b,c], [b,c], State5, false).

-endif.
