%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

-module(ns_cluster).

-behaviour(gen_fsm).

%% General FSMness
-export([start_link/0, init/1, handle_info/3,
         handle_event/3, handle_sync_event/4,
         code_change/4, terminate/3]).

-define(NODE_JOINED, 3).
-define(NODE_EJECTED, 4).

%% States
-export([running/2, joining/2, leaving/2]).

%% API
-export([join/2, leave/0, shun/1]).

-export([alert_key/1]).

-record(running_state, {child}).
-record(joining_state, {remote, cookie}).
-record(leaving_state, {}).

%% gen_server handlers
start_link() ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    ok = net_kernel:monitor_nodes(true,
                                  [{node_type, all}, nodedown_reason]),
    bringup().

%% Bringup services.
bringup() ->
    {ok, Pid} = ns_server_sup:start_link(),
    {ok, running, #running_state{child=Pid}}.

%%
%% State Transitions
%%

running({join, RemoteNode, NewCookie}, State) ->
    ns_log:log(?MODULE, 0002, "Node ~p is joining cluster via node ~p.", [node(), RemoteNode]),
    ns_config:set(otp, [{cookie, NewCookie}]),
    ns_config:set(nodes_wanted, [node(), RemoteNode], {0, 0, 0}),
    ns_config:clear([directory, otp, nodes_wanted]),
    true = exit(State#running_state.child, shutdown), % Pull the rug out from under the app
    {next_state, joining, #joining_state{remote=RemoteNode, cookie=NewCookie}};

running(leave, State) ->
    ns_log:log(?MODULE, 0001, "Node ~p is leaving cluster.", [node()]),
    NewCookie = ns_node_disco:cookie_gen(),
    erlang:set_cookie(node(), NewCookie),
    lists:foreach(fun erlang:disconnect_node/1, nodes()),
    WebPort = ns_config:search_prop(ns_config:get(), rest, port, false),
    ns_config:clear([directory]),
    case WebPort of
        false -> false;
        _ -> ns_config:set(rest, [{port, WebPort}])
    end,
    ns_config:set(nodes_wanted, [node()], {0, 0, 0}),
    ns_config:set(otp, [{cookie, NewCookie}], {0, 0, 0}),
    true = exit(State#running_state.child, shutdown),
    {next_state, leaving, #leaving_state{}}.

joining({exit, _Pid}, #joining_state{remote=RemoteNode, cookie=NewCookie}) ->
    error_logger:info_msg("ns_cluster: joining cluster. Child has exited.~n"),
    timer:sleep(1000), % Sleep for a second to let things settle
    true = erlang:set_cookie(node(), NewCookie),
    %% Let's verify connectivity.
    Connected = net_kernel:connect_node(RemoteNode),
    error_logger:info_msg("Connection from ~p to ~p:  ~p~n",
                          [node(), RemoteNode, Connected]),
    %% Add ourselves to nodes_wanted on the remote node after shutting
    %% down our own config server.
    MyNode = node(),
    Fun = fun({nodes_wanted, X}) ->
                  {nodes_wanted, lists:usort([MyNode | X])};
             (X) -> X
          end,
    Ref = make_ref(),
    case rpc:call(RemoteNode, ns_config, update, [Fun, Ref]) of
        {badrpc, Crap} -> exit({badrpc, Crap});
        _ -> error_logger:info_msg("Remote config updated to add ~p to ~p~n",
                                   [node(), RemoteNode])
    end,
    {ok, running, State} = bringup(),

    timer:apply_after(1000, ?MODULE, log_joined, []),
    {next_state, running, State}.

leaving({exit, _Pid}, _LeaveData) ->
    error_logger:info_msg("ns_cluster: leaving cluster~n"),
    timer:sleep(1000),
    {ok, running, State} = bringup(),
    {next_state, running, State};

leaving(leave, LeaveData) ->
    %% If we are told to leave in the leaving state, continue leaving.
    {next_state, leaving, LeaveData}.

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

%% API
join(RemoteNode, NewCookie) ->
    gen_fsm:send_event(?MODULE, {join, RemoteNode, NewCookie}).

leave() ->
    RemoteNode = ns_node_disco:random_node(),

    ns_log:log(?MODULE, ?NODE_EJECTED, "Node ~s left cluster", [node()]),

    error_logger:info_msg("ns_cluster: leaving the cluster from ~p.~n",
                         [RemoteNode]),

    %% Tell the remote server to tell everyone to shun me.
    rpc:cast(RemoteNode, ?MODULE, shun, [node()]),
    %% Then drop ourselves into a leaving state.
    gen_fsm:send_event(?MODULE, leave).

shun(RemoteNode) ->
    ns_config:update(fun({nodes_wanted, X}) ->
                             {nodes_wanted, X -- [RemoteNode]};
                        (X) -> X
                     end,
                     make_ref()),
    ns_config_rep:push().

alert_key(?NODE_JOINED) -> server_joined;
alert_key(?NODE_EJECTED) -> server_left;
alert_key(_) -> all.
