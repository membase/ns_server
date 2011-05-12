%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
%% Monitor and maintain the vbucket layout of each bucket.
%% There is one of these per bucket.
%%
-module(mb_master).

-behaviour(gen_fsm).

-include("ns_common.hrl").

%% Constants and definitions
-define(HEARTBEAT_INTERVAL, 2000).
-define(TIMEOUT, ?HEARTBEAT_INTERVAL * 5000). % in microseconds

-record(state, {child :: pid(), master :: node(), peers :: [node()],
                last_heard :: {integer(), integer(), integer()}}).


%% API
-export([start_link/0,
         master_node/0]).


%% gen_fsm callbacks
-export([code_change/4,
         init/1,
         handle_event/3,
         handle_info/3,
         handle_sync_event/4,
         terminate/3]).

%% States
-export([candidate/2,
         master/2,
         worker/2]).


%%
%% API
%%

start_link() ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).


%% @doc Returns the master node for the cluster, or undefined if it's
%% not known yet.
master_node() ->
    gen_fsm:sync_send_all_state_event(?MODULE, master_node).


%%
%% gen_fsm handlers
%%

init([]) ->
    Self = self(),
    ns_pubsub:subscribe(
      ns_config_events,
      fun ({nodes_wanted, Nodes}, State) ->
              Self ! {peers, Nodes},
              State;
          (_, State) ->
              State
      end, empty),
    erlang:process_flag(trap_exit, true),
    {ok, _} = timer:send_interval(?HEARTBEAT_INTERVAL, send_heartbeat),
    case ns_node_disco:nodes_wanted() of
        [N] = P when N == node() ->
            ?log_info("I'm the only node, so I'm the master.", []),
            {ok, master, start_master(#state{last_heard=now(), peers=P})};
        Peers when is_list(Peers) ->
            case lists:member(node(), Peers) of
                false ->
                    %% We're a worker, but don't know who the master is yet
                    ?log_info("Starting as worker. Peers: ~p", [Peers]),
                    {ok, worker, #state{last_heard=now()}};
                true ->
                    %% We're a candidate
                    ?log_info("Starting as candidate. Peers: ~p", [Peers]),
                    {ok, candidate, #state{last_heard=now(), peers=Peers}}
            end
    end.


handle_event(Event, StateName, StateData) ->
    ?log_info("Got unexpected event ~p in state ~p with data ~p",
              [Event, StateName, StateData]),
    {next_state, StateName, StateData}.


handle_info({'EXIT', _From, Reason} = Msg, _, _) ->
    ?log_info("Dying because of linked process exit: ~p~n", [Msg]),
    exit(Reason);

handle_info(send_heartbeat, candidate, #state{peers=Peers} = StateData) ->
    send_heartbeat(Peers, candidate, StateData),
    case timer:now_diff(now(), StateData#state.last_heard) >= ?TIMEOUT of
        true ->
            %% Take over
            ?log_info("Haven't heard from a higher priority node or "
                      "a master, so I'm taking over.", []),
            {ok, Pid} = mb_master_sup:start_link(),
            {next_state, master, StateData#state{child=Pid, master=node()}};
        false ->
            {next_state, candidate, StateData}
    end;

handle_info(send_heartbeat, master, StateData) ->
    %% Make sure our name hasn't changed
    StateData1 = case StateData#state.master of
                     N when N == node() ->
                         StateData;
                     N1 ->
                         ?log_info("Node changed name from ~p to ~p. "
                                   "Updating state.", [N1, node()]),
                         StateData#state{master=node()}
                 end,
    send_heartbeat(ns_node_disco:nodes_wanted(), master, StateData1),
    {next_state, master, StateData1};

handle_info(send_heartbeat, worker, StateData) ->
    %% Workers don't send heartbeats, but it's simpler to just ignore
    %% the timer than to turn it off.
    {next_state, worker, StateData};

handle_info({peers, Peers}, master, StateData) ->
    S = update_peers(StateData, Peers),
    case lists:member(node(), Peers) of
        true ->
            {next_state, master, S};
        false ->
            ?log_info("Master has been demoted. Peers = ~p", [Peers]),
            NewState = shutdown_master_sup(S),
            {next_state, worker, NewState}
    end;

handle_info({peers, Peers}, StateName, StateData) when
      StateName == candidate; StateName == worker ->
    S = update_peers(StateData, Peers),
    case Peers of
        [N] when N == node() ->
            ?log_info("I'm now the only node, so I'm the master.", []),
            {next_state, master, start_master(S)};
        _ ->
            case lists:member(node(), Peers) of
                true ->
                    {next_state, candidate, S};
                false ->
                    {next_state, worker, S}
            end
    end;

handle_info(Info, StateName, StateData) ->
    ?log_info("handle_info(~p, ~p, ~p)", [Info, StateName, StateData]),
    {next_state, StateName, StateData}.


handle_sync_event(master_node, _From, StateName, StateData) ->
    {reply, StateData#state.master, StateName, StateData};

handle_sync_event(_, _, StateName, StateData) ->
    {reply, unhandled, StateName, StateData}.


code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.


terminate(_Reason, _StateName, _StateData) ->
    ok.


%%
%% States
%%

candidate({heartbeat, Node, master, _H}, #state{peers=Peers} = State) ->
    case State#state.master of
        Node ->
            {next_state, candidate, State#state{last_heard=now()}};
        N ->
            case lists:member(Node, Peers) of
                true ->
                    ?log_info("Changing master from ~p to ~p", [N, Node]),
                    {next_state, candidate, State#state{last_heard=now(),
                                                        master=Node}};
                false ->
                    ?log_warning("Master got master heartbeat from node ~p "
                                 "which is not in peers ~p", [Node, Peers]),
                    {next_state, candidate, State}
            end
    end;

candidate({heartbeat, Node, candidate, _H}, #state{peers=Peers} = State) ->
    case lists:member(Node, Peers) of
        true ->
            case Node < node() of
                true ->
                    %% Higher priority node
                    {next_state, candidate, State#state{last_heard=now()}};
                false ->
                    %% Lower priority, so ignore it
                    {next_state, candidate, State}
            end;
        false ->
            ?log_warning("Candidate got candidate heartbeat from node ~p which "
                         "is not in peers ~p", [Node, Peers]),
            {next_state, candidate, State}
    end;

candidate(Event, State) ->
    ?log_info("Got event ~p as candidate with state ~p", [Event, State]),
    {next_state, candidate, State}.


master({heartbeat, Node, master, _H}, #state{peers=Peers} = State) ->
    case lists:member(Node, Peers) of
        true ->
            case Node < node() of
                true ->
                    ?log_info("Surrendering mastership to ~p", [Node]),
                    NewState = shutdown_master_sup(State),
                    {next_state, candidate, NewState#state{last_heard=now()}};
                false ->
                    ?log_info("Got master heartbeat from ~p when I'm master",
                              [Node]),
                    {next_state, master, State#state{last_heard=now()}}
            end;
        false ->
            ?log_warning("Master got master heartbeat from node ~p which is "
                         "not in peers ~p", [Node, Peers]),
            {next_state, master, State}
    end;

master({heartbeat, Node, candidate, _H}, #state{peers=Peers} = State) ->
    case lists:member(Node, Peers) of
        true ->
            ok;
        false ->
            ?log_info("Master got candidate heartbeat from node ~p which is "
                      "not in peers ~p", [Node, Peers])
    end,
    {next_state, master, State#state{last_heard=now()}};

master(Event, State) ->
    ?log_info("Got event ~p as master with state ~p", [Event, State]),
    {next_state, master, State}.


worker({heartbeat, Node, master, _H}, State) ->
    case State#state.master of
        Node ->
            {next_state, worker, State#state{last_heard=now()}};
        N ->
            ?log_info("Saw master change from ~p to ~p", [N, Node]),
            {next_state, worker, State#state{last_heard=now(), master=Node}}
    end;

worker(Event, State) ->
    ?log_info("Got event ~p as worker with state ~p", [Event, State]),
    {next_state, worker, State}.


%%
%% Internal functions
%%

%% @private
%% @doc Send an heartbeat to a list of nodes, except this one.
send_heartbeat(Nodes, StateName, StateData) ->
    Args = {heartbeat, node(), StateName,
            [{peers, StateData#state.peers}]},
    try
        misc:parallel_map(
          fun (Node) ->
                  %% we try to avoid sending event to nodes that are
                  %% down. Because send call inside gen_fsm will try to
                  %% establish connection each time we try to send.
                  case lists:member(Node, nodes()) of
                      true ->
                          gen_fsm:send_event({?MODULE, Node}, Args);
                      _ -> ok
                  end
          end, Nodes, 2000)
    catch exit:timeout -> ok
    end.


%% @private
%% @doc Go into master state. Returns new state data.
start_master(StateData) ->
    {ok, Pid} = mb_master_sup:start_link(),
    StateData#state{child=Pid, master=node()}.


%% @private
%% @doc Update the list of peers in the state. Also logs when it
%% changes.
update_peers(StateData, Peers) ->
    O = lists:sort(StateData#state.peers),
    P = lists:sort(Peers),
    case O == P of
        true ->
            %% No change
            StateData;
        false ->
            ?log_info("List of peers has changed from ~p to ~p", [O, P]),
            StateData#state{peers=P}
    end.

shutdown_master_sup(State) ->
    Pid = State#state.child,
    exit(Pid, shutdown),
    receive
        {'EXIT', Pid, _Reason} ->
            ok
    after 10000 ->
            ?log_info("Killing runaway child supervisor: ~p~n", [Pid]),
            exit(Pid, kill),
            receive
                {'EXIT', Pid, _Reason} ->
                    ok
            end
    end,
    State#state{child = undefined}.
