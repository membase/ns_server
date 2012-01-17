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
-include_lib("eunit/include/eunit.hrl").

%% Constants and definitions
-define(HEARTBEAT_INTERVAL, 2000).
-define(TIMEOUT, ?HEARTBEAT_INTERVAL * 5000). % in microseconds

-type node_info() :: node() | {version(), node()}.
-type operation_mode() :: compatible | normal.

-define(DEFAULT_MODE, compatible).

-record(state, {child                :: pid(),
                master               :: node(),
                peers                :: [node()],
                last_heard           :: {integer(), integer(), integer()},

                new_peers            :: [node()],
                mode = ?DEFAULT_MODE :: operation_mode()}).


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
    ns_pubsub:subscribe_link(
      ns_config_events,
      fun ({nodes_wanted, Nodes}, State) ->
              Self ! {peers, Nodes},
              State;
          (_, State) ->
              State
      end, empty),
    erlang:process_flag(trap_exit, true),
    {ok, _} = timer:send_interval(?HEARTBEAT_INTERVAL, send_heartbeat),

    NewPeers = [node()],

    case ns_node_disco:nodes_wanted() of
        [N] = P when N == node() ->
            ?log_info("I'm the only node, so I'm the master.", []),
            %% since we're the only node in the cluster we can operate in new
            %% mode
            {ok, master, start_master(#state{last_heard=now(),
                                             peers=P,
                                             new_peers=NewPeers,
                                             mode=normal})};
        Peers when is_list(Peers) ->
            case lists:member(node(), Peers) of
                false ->
                    %% We're a worker, but don't know who the master is yet
                    ?log_info("Starting as worker. Peers: ~p", [Peers]),
                    {ok, worker, #state{last_heard=now(),
                                        new_peers=NewPeers}};
                true ->
                    %% We're a candidate
                    ?log_info("Starting as candidate. Peers: ~p", [Peers]),
                    {ok, candidate, #state{last_heard=now(),
                                           peers=Peers,
                                           new_peers=NewPeers}}
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
            {next_state, master,
             choose_mode(StateData#state{child=Pid, master=node()})};
        false ->
            {next_state, candidate, choose_mode(StateData)}
    end;

handle_info(send_heartbeat, master, StateData) ->
    case misc:flush(send_heartbeat) of
        0 -> ok;
        Eaten ->
            ?log_warning("Skipped ~p heartbeats~n", [Eaten])
    end,

    Self = node(),

    %% Make sure our name hasn't changed
    StateData1 = case StateData#state.master of
                     Self ->
                         StateData;
                     N1 ->
                         ?log_info("Node changed name from ~p to ~p. "
                                   "Updating state.", [N1, node()]),
                         StateData#state{master=node()}
                 end,
    send_heartbeat(ns_node_disco:nodes_wanted(), master, StateData1),
    {next_state, master, StateData1};

handle_info(send_heartbeat, worker, StateData) ->
    misc:flush(send_heartbeat),
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

candidate({heartbeat, NodeInfo, master, Data}, #state{peers=Peers} = State) ->
    S = update_new_peers(State, NodeInfo, Data),
    Node = node_info_to_node(NodeInfo),

    case S#state.master of
        Node ->
            {next_state, candidate, S#state{last_heard=now()}};
        N ->
            case lists:member(Node, Peers) of
                true ->
                    ?log_info("Changing master from ~p to ~p", [N, Node]),
                    {next_state, candidate, S#state{last_heard=now(),
                                                    master=Node}};
                false ->
                    ?log_warning("Master got master heartbeat from node ~p "
                                 "which is not in peers ~p", [Node, Peers]),
                    {next_state, candidate, S}
            end
    end;

candidate({heartbeat, NodeInfo, candidate, Data},
          #state{peers=Peers} = State) ->
    Node = node_info_to_node(NodeInfo),
    S = update_new_peers(State, NodeInfo, Data),

    case lists:member(Node, Peers) of
        true ->
            case higher_priority_node(NodeInfo, S) of
                true ->
                    %% Higher priority node
                    {next_state, candidate, S#state{last_heard=now()}};
                false ->
                    %% Lower priority, so ignore it
                    {next_state, candidate, S}
            end;
        false ->
            ?log_warning("Candidate got candidate heartbeat from node ~p which "
                         "is not in peers ~p", [Node, Peers]),
            {next_state, candidate, S}
    end;

candidate(Event, State) ->
    ?log_info("Got event ~p as candidate with state ~p", [Event, State]),
    {next_state, candidate, State}.


master({heartbeat, NodeInfo, master, Data}, #state{peers=Peers} = State) ->
    Node = node_info_to_node(NodeInfo),
    S = update_new_peers(State, NodeInfo, Data),

    case lists:member(Node, Peers) of
        true ->
            case higher_priority_node(NodeInfo, S) of
                true ->
                    ?log_info("Surrendering mastership to ~p", [NodeInfo]),
                    NewState = shutdown_master_sup(S),
                    {next_state, candidate, NewState#state{last_heard=now()}};
                false ->
                    ?log_info("Got master heartbeat from ~p when I'm master",
                              [Node]),
                    {next_state, master, S#state{last_heard=now()}}
            end;
        false ->
            ?log_warning("Master got master heartbeat from node ~p which is "
                         "not in peers ~p", [Node, Peers]),
            {next_state, master, S}
    end;

master({heartbeat, NodeInfo, candidate, Data}, #state{peers=Peers} = State) ->
    Node = node_info_to_node(NodeInfo),
    S = update_new_peers(State, NodeInfo, Data),

    case lists:member(Node, Peers) of
        true ->
            ok;
        false ->
            ?log_info("Master got candidate heartbeat from node ~p which is "
                      "not in peers ~p", [Node, Peers])
    end,
    {next_state, master, S#state{last_heard=now()}};

master(Event, State) ->
    ?log_info("Got event ~p as master with state ~p", [Event, State]),
    {next_state, master, State}.


worker({heartbeat, NodeInfo, master, Data}, State) ->
    Node = node_info_to_node(NodeInfo),
    S = update_new_peers(State, NodeInfo, Data),

    case S#state.master of
        Node ->
            {next_state, worker, S#state{last_heard=now()}};
        N ->
            ?log_info("Saw master change from ~p to ~p", [N, Node]),
            {next_state, worker, S#state{last_heard=now(), master=Node}}
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
    NodeInfo = node_info(StateData),

    Args = {heartbeat, NodeInfo, StateName,
            [{peers, StateData#state.peers},
             {versioning, true}]},
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
    catch exit:timeout ->
            ?log_info("send heartbeat timed out~n", [])
    end.


%% @private
%% @doc Go into master state. Returns new state data.
start_master(StateData) ->
    {ok, Pid} = mb_master_sup:start_link(),
    StateData#state{child=Pid, master=node()}.


%% @private
%% @doc Update the list of peers in the state. Also logs when it
%% changes.
update_peers(#state{new_peers=NPeers0} = StateData, Peers) ->
    O = lists:sort(StateData#state.peers),
    P = lists:sort(Peers),
    case O == P of
        true ->
            %% No change
            StateData;
        false ->
            NPeers1 = ordsets:intersection(P, NPeers0),
            %% no matter what happens but keep ourselves in the list of new
            %% peers
            NPeers2 = ordsets:add_element(node(), NPeers1),
            ?log_info("List of peers has changed from ~p to ~p", [O, P]),

            case NPeers0 =:= NPeers2 of
                false ->
                    ?log_info("List of new peers has changed from ~p to ~p",
                              [NPeers0, NPeers2]);
                true ->
                    ok
            end,

            choose_mode(StateData#state{peers=P,
                                        new_peers=NPeers2})
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

%% Checks state and adjusts execution mode when it's possible.
-spec choose_mode(#state{}) -> #state{}.
choose_mode(#state{peers=Peers,
                   new_peers=NPeers,
                   mode=CurrentMode} = StateData) ->
    Mode =
        case Peers of
            %% we're the only node, thus the new mode can be used
            [N] when N =:= node() ->
                normal;
            _ ->
                %% both Peers and NPeers are sorted
                case NPeers =:= Peers of
                    true -> normal;
                    false -> compatible
                end
        end,

    case CurrentMode =/= Mode of
        true ->
            ?log_info("Switching from ~p to ~p mode",
                      [CurrentMode, Mode]);
        false ->
            ok
    end,

    StateData#state{mode=Mode}.

%% Updates an information about new peers. Switches mode if necessary.
update_new_peers(#state{peers=Peers, new_peers=NPeers0} = StateData,
                 NodeInfo, HeartbeatData) ->
    Node = node_info_to_node(NodeInfo),

    case lists:member(Node, Peers) of
        true ->
            NPeers1 =
                case proplists:get_value(versioning, HeartbeatData, false) of
                    true ->
                        ordsets:add_element(node_info_to_node(NodeInfo),
                                            NPeers0);
                    false ->
                        NPeers0
                end,

            case NPeers0 =:= NPeers1 of
                false ->
                    ?log_info("Got new peer supporting versioning: ~p", [Node]);
                true ->
                    ok
            end,

            choose_mode(StateData#state{new_peers=NPeers1});
        false ->
            ?log_info("Got heartbeat from unknown node ~p~n", [Node]),
            StateData
    end.

-spec node_info(#state{}) -> node_info().
node_info(#state{mode=compatible}) ->
    node();
node_info(#state{mode=normal}) ->
    RawVersion = ns_info:version(ns_server),
    Version = misc:parse_version(RawVersion),
    {Version, node()}.

%% Convert node info to node.
-spec node_info_to_node(node_info()) -> node().
node_info_to_node({_Version, Node}) ->
    Node;
node_info_to_node(Node) ->
    Node.

%% Determine whether some node is of higher priority than ourselves.
-spec higher_priority_node(node_info(), #state{}) -> boolean().
higher_priority_node(NodeInfo, #state{mode=Mode} = StateData) ->
    Self = node_info(StateData),
    higher_priority_node(Self, NodeInfo, Mode).

-spec higher_priority_node(node_info(), node_info(), operation_mode()) ->
                                  boolean().
higher_priority_node(Self, NodeInfo, Mode) ->
    Node = node_info_to_node(NodeInfo),

    case Mode =:= normal andalso not is_atom(NodeInfo) of
        true ->
            {SelfVersion, SelfNode} = Self,
            {Version, _} = NodeInfo,

            if
                Version > SelfVersion ->
                    true;
                Version =:= SelfVersion ->
                    Node < SelfNode;
                true ->
                    false
            end;
        false ->
            case is_atom(NodeInfo) of
                false ->
                    ?log_warning("Got new-style heartbeat from ~p "
                                 "node when in compatible mode", [Node]);
                true ->
                    ok
            end,
            Node < node_info_to_node(Self)
    end.

-ifdef(EUNIT).

priority_test() ->
    ?assertEqual(true,
                 higher_priority_node('ns_2@192.168.1.1',
                                      'ns_1@192.168.1.1',
                                      compatible)),

    ?assertEqual(false,
                 higher_priority_node({misc:parse_version("1.7.1"),
                                       'ns_1@192.168.1.1'},
                                      'ns_2@192.168.1.1',
                                      normal)),
    ?assertEqual(true,
                 higher_priority_node({misc:parse_version("1.7.1"),
                                       'ns_2@192.168.1.1'},
                                      'ns_1@192.168.1.1',
                                      normal)),

    ?assertEqual(true,
                 higher_priority_node({misc:parse_version("1.7.1"),
                                       'ns_1@192.168.1.1'},
                                      {misc:parse_version("2.0"),
                                       'ns_2@192.168.1.1'},
                                      normal)),
    ?assertEqual(true,
                 higher_priority_node({misc:parse_version("1.7.1"),
                                       'ns_2@192.168.1.1'},
                                      {misc:parse_version("2.0"),
                                       'ns_1@192.168.1.1'},
                                      normal)),
    ?assertEqual(false,
                 higher_priority_node({misc:parse_version("2.0"),
                                       'ns_1@192.168.1.1'},
                                      {misc:parse_version("1.7.2"),
                                       'ns_0@192.168.1.1'},
                                      normal)),
    ?assertEqual(true,
                 higher_priority_node({misc:parse_version("2.0"),
                                       'ns_2@192.168.1.1'},
                                      {misc:parse_version("2.0"),
                                       'ns_1@192.168.1.1'},
                                      normal)).

-endif.
