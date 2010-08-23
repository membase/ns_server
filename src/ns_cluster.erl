%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
-module(ns_cluster).

-behaviour(gen_fsm).

-include("ns_common.hrl").

%% General FSMness
-export([start_link/0, init/1, handle_info/3,
         handle_event/3, handle_sync_event/4,
         code_change/4, terminate/3, prepare_join_to/1, change_my_address/1]).

-define(NODE_JOIN_REQUEST, 2).
-define(NODE_JOINED, 3).
-define(NODE_EJECTED, 4).

%% States
-export([running/2, running/3, joining/2, joining/3, leaving/2, leaving/3]).

%% API
-export([add_node/1, join/2, leave/0, leave/1, shun/1, log_joined/0]).

-export([alert_key/1]).

-record(running_state, {child}).
-record(joining_state, {remote, cookie, my_ip}).
-record(leaving_state, {callback}).

%% gen_server handlers
start_link() ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    ok = net_kernel:monitor_nodes(true,
                                  [{node_type, all}, nodedown_reason]),
    ns_mnesia:start(),
    bringup().

%% Bringup services.
bringup() ->
    case ns_server_sup:start_link() of
        {ok, Pid} ->
            {ok, running, #running_state{child=Pid}};
        E ->
            %% Sleep a second and a half to give the global singleton
            %% watchdog time to realize it's not registered
            timer:sleep(1500),
            {error, E}
    end.

%%
%% State Transitions
%%

running({join, RemoteNode, NewCookie}, State) ->
    ns_log:log(?MODULE, 0002, "Node ~p is joining cluster via node ~p.",
               [node(), RemoteNode]),
    BlackSpot = make_ref(),
    MyNode = node(),
    ns_config:update(fun ({directory,_} = X) -> X;
                         ({otp, _}) -> {otp, [{cookie, NewCookie}]};
                         ({nodes_wanted, _} = X) -> X;
                         ({{node, _, membership}, _}) -> BlackSpot;
                         ({{node, Node, _}, _} = X) when Node =:= MyNode -> X;
                         (_) -> BlackSpot
                     end, BlackSpot),
    %% cannot force low timestamp with ns_config update, so we set it separately
    ns_config:set_initial(nodes_wanted, [node(), RemoteNode]),
    error_logger:info_msg("pre-join cleaned config is:~n~p~n",
                          [ns_config:get()]),
    true = exit(State#running_state.child, shutdown), % Pull the rug out from
                                                      % under the app
    {next_state, joining, #joining_state{remote=RemoteNode, cookie=NewCookie}};

running({leave, Data}, State) ->
    ns_log:log(?MODULE, 0001, "Node ~p is leaving cluster.", [node()]),
    NewCookie = ns_node_disco:cookie_gen(),
    erlang:set_cookie(node(), NewCookie),
    lists:foreach(fun erlang:disconnect_node/1, nodes()),
    WebPort = ns_config:search_node_prop(ns_config:get(), rest, port, false),
    ns_config:clear([directory]),
    case WebPort of
        false -> false;
        _ -> ns_config:set(rest, [{port, WebPort}])
    end,
    ns_config:set_initial(nodes_wanted, [node()]),
    ns_config:set_initial(otp, [{cookie, NewCookie}]),
    ns_mnesia:delete_schema_and_stop(),
    true = exit(State#running_state.child, shutdown),
    {next_state, leaving, Data};

running(leave, State) ->
    running({leave, #leaving_state{}}, State).


running({change_address, NewAddr}, _From, State) ->
    MyNode = node(),
    case misc:node_name_host(MyNode) of
        {_, NewAddr} ->
            %% Don't do anything if we already have the right address.
            {reply, ok, running, State};
        {_, _} ->
            CookieBefore = erlang:get_cookie(),
            ns_server_sup:pull_plug(
              fun() ->
                      case ns_mnesia:prepare_rename() of
                          ok ->
                              case dist_manager:adjust_my_address(NewAddr) of
                                  nothing ->
                                      ns_mnesia:backout_rename();
                                  net_restarted ->
                                      case erlang:get_cookie() of
                                          CookieBefore ->
                                              ok;
                                          CookieAfter ->
                                              error_logger:error_msg(
                                                "critical: Cookie has changed from ~p "
                                                "to ~p~n", [CookieBefore, CookieAfter]),
                                              exit(bad_cookie)
                                      end,
                                      ns_mnesia:rename_node(MyNode, node()),
                                      rename_node(MyNode, node()),
                                      ok
                              end;
                          E ->
                              ?log_error("Not attempting to rename node: ~p", [E])
                      end
              end),
            {reply, ok, running, State}
    end.


joining({exit, _Pid}, #joining_state{remote=RemoteNode, cookie=NewCookie}) ->
    error_logger:info_msg("ns_cluster: joining cluster. Child has exited.~n"),
    ns_mnesia:delete_schema(),
    timer:sleep(1000), % Sleep for a second to let things settle
    true = erlang:set_cookie(node(), NewCookie),
    %% Let's verify connectivity.
    Connected = net_kernel:connect_node(RemoteNode),
    ?log_info("Connection from ~p to ~p:  ~p",
              [node(), RemoteNode, Connected]),
    %% Add ourselves to nodes_wanted on the remote node after shutting
    %% down our own config server.
    ok = rpc:call(RemoteNode, ns_cluster, add_node, [node()]),
    error_logger:info_msg("Remote config updated to add ~p to ~p~n",
                          [node(), RemoteNode]),
    {ok, running, State} = bringup(),

    timer:apply_after(1000, ?MODULE, log_joined, []),
    {next_state, running, State};
joining(Event, State) ->
    ?log_warning("Got unexpected event ~p in state joining: ~p", [Event, State]),
    {next_state, joining, State}.


joining(_Event, _From, State) ->
    {reply, unhandled, joining, State}.


leaving({exit, _Pid}, LeaveData) ->
    error_logger:info_msg("ns_cluster: leaving cluster~n"),
    timer:sleep(1000),
    ns_mnesia:start(),
    {ok, running, State} = bringup(),
    case LeaveData#leaving_state.callback of
        F when is_function(F) -> F();
        _ -> ok
    end,
    {next_state, running, State};

leaving(leave, LeaveData) ->
    %% If we are told to leave in the leaving state, continue leaving.
    {next_state, leaving, LeaveData};
leaving({leave, _}, LeaveData) ->
    %% If we are told to leave in the leaving state, continue leaving.
    {next_state, leaving, LeaveData}.


leaving(_Event, _From, State) ->
    {reply, unhandled, leaving, State}.


%%
%% Internal functions
%%

log_joined() ->
    ns_log:log(?MODULE, ?NODE_JOINED, "Node ~s joined cluster",
               [node()]).


%%
%% Miscellaneous gen_fsm callbacks.
%%

handle_info({'EXIT', Pid, shutdown}, CurrentState, CurrentData) ->
    ?MODULE:CurrentState({exit, Pid}, CurrentData);
handle_info(Other, CurrentState, CurrentData) ->
    error_logger:info_msg("ns_cluster saw ~p in state ~p~n",
                          [Other, CurrentState]),
    {next_state, CurrentState, CurrentData}.

handle_event(Event, State, _StateData) ->
    exit({unhandled_event, Event, State}).

handle_sync_event(Event, _From, State, _StateData) ->
    exit({unhandled_event, Event, State}).

code_change(_OldVsn, State, StateData, _Extra) ->
    {ok, State, StateData}.

terminate(_Reason, _StateName, _StateData) -> ok.

%%
%% API
%%

%% Called on a node in the cluster to add us to its nodes_wanted
add_node(Node) ->
    Fun = fun(X) ->
                  lists:usort([Node | X])
          end,
    ns_config:update_key(nodes_wanted, Fun),
    ns_config:set({node, Node, membership}, inactiveAdded),
    ns_mnesia:add_node(Node),
    error_logger:info_msg("~p:add_node: successfully added ~p to cluster.~n",
                          [?MODULE, Node]),
    ok.


join(RemoteNode, NewCookie) ->
    ns_log:log(?MODULE, ?NODE_JOIN_REQUEST, "Node join request on ~s to ~s",
               [node(), RemoteNode]),

    case lists:member(RemoteNode, ns_node_disco:nodes_wanted()) of
        true -> {error, already_joined};
        false-> gen_fsm:send_event(?MODULE, {join, RemoteNode, NewCookie})
    end.

leave() ->
    RemoteNode = ns_node_disco:random_node(),

    ns_log:log(?MODULE, ?NODE_EJECTED, "Node ~s left cluster", [node()]),

    error_logger:info_msg("ns_cluster: leaving the cluster from ~p.~n",
                         [RemoteNode]),

    %% Tell the remote server to tell everyone to shun me.
    rpc:cast(RemoteNode, ?MODULE, shun, [node()]),
    %% Then drop ourselves into a leaving state.
    gen_fsm:send_event(?MODULE, leave).

%% Cause another node to leave the cluster if it's up
leave(Node) ->
    case Node == node() of
        true ->
            leave();
        false ->
            catch gen_fsm:send_event({?MODULE, Node}, leave),
            shun(Node)
    end.

%% Note that shun does *not* cause the other node to reset its config!
shun(RemoteNode) ->
    case RemoteNode == node() of
        false ->
            ns_config:update_key(nodes_wanted,
                                 fun (X) ->
                                         X -- [RemoteNode]
                                 end),
            ns_config_rep:push(),
            ns_mnesia:delete_node(RemoteNode);
        true ->
            leave()
    end.

alert_key(?NODE_JOINED) -> server_joined;
alert_key(?NODE_EJECTED) -> server_left;
alert_key(_) -> all.

prepare_join_to(OtherHost) ->
    %% connect to epmd at other side
    case gen_tcp:connect(OtherHost, 4369,
                         [binary, {packet, 0}, {active, false}],
                         5000) of
        {ok, Socket} ->
            %% and determine our ip address
            {ok, {IpAddr, _}} = inet:sockname(Socket),
            inet:close(Socket),
            RV = string:join(lists:map(fun erlang:integer_to_list/1,
                                       tuple_to_list(IpAddr)), "."),
            {ok, RV};
        {error, _} = X -> X
    end.

rename_node(Old, New) ->
    ns_config:update(fun ({K, V} = Pair) ->
                             NewK = misc:rewrite_value(Old, New, K),
                             NewV = misc:rewrite_value(Old, New, V),
                             if
                                 NewK =/= K orelse NewV =/= V ->
                                     error_logger:info_msg(
                                       "renaming node conf ~p -> ~p:~n  ~p ->~n  ~p~n",
                                       [K, NewK, V, NewV]),
                                     {NewK, NewV};
                                 true ->
                                     Pair
                             end
                     end, erlang:make_ref()).

change_my_address(MyAddr) ->
    gen_fsm:sync_send_event(?MODULE, {change_address, MyAddr}).
