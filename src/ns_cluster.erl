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

-behaviour(gen_server).

-include("ns_common.hrl").

-define(NODE_JOIN_REQUEST, 2).
-define(NODE_JOINED, 3).
-define(NODE_EJECTED, 4).

%% gen_server callbacks
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1,
         terminate/2]).

%% API
-export([change_my_address/1,
         join/2,
         leave/0,
         leave/1,
         leave_async/0,
         log_joined/0,
         prepare_join_to/1,
         shun/1,
         start_link/0]).

-export([alert_key/1]).
-record(state, {}).

%%
%% API
%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%
%% gen_server handlers
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call({add_node, Node}, _From, State) ->
    Fun = fun(X) ->
                  lists:usort([Node | X])
          end,
    ns_config:update_key(nodes_wanted, Fun),
    ns_config:set({node, Node, membership}, inactiveAdded),
    ?log_info("Successfully added ~p to cluster.", [Node]),
    {reply, ok, State};

handle_call({change_address, NewAddr}, _From, State) ->
    MyNode = node(),
    case misc:node_name_host(MyNode) of
        {_, NewAddr} ->
            %% Don't do anything if we already have the right address.
            {reply, ok, State};
        {_, _} ->
            CookieBefore = erlang:get_cookie(),
            ok = ns_mnesia:prepare_rename(),
            ns_server_sup:pull_plug(
              fun() ->
                      case dist_manager:adjust_my_address(NewAddr) of
                          nothing ->
                              ok;
                          net_restarted ->
                              %% Make sure the cookie's still the same
                              CookieBefore = erlang:get_cookie(),
                              ok = ns_mnesia:rename_node(MyNode, node()),
                              rename_node(MyNode, node()),
                              ok
                      end
              end),
            {reply, ok, State}
    end.


handle_cast({join, RemoteNode, NewCookie}, State) ->
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
    %% Pull the rug out from under the app
    ok = ns_server_cluster_sup:stop_cluster(),
    ns_mnesia:delete_schema(),
    try
        error_logger:info_msg("ns_cluster: joining cluster. Child has exited.~n"),
        timer:sleep(1000), % Sleep for a second to let things settle
        true = erlang:set_cookie(node(), NewCookie),
        %% Let's verify connectivity.
        Connected = net_kernel:connect_node(RemoteNode),
        ?log_info("Connection from ~p to ~p:  ~p",
                  [node(), RemoteNode, Connected]),
        %% Add ourselves to nodes_wanted on the remote node after shutting
        %% down our own config server.
        ok = gen_server:call({?MODULE, RemoteNode}, {add_node, node()}, 20000),
        ?log_info("Remote config updated to add ~p to ~p",
                  [node(), RemoteNode])
    catch
        Type:Error ->
            ?log_error("Error during join: ~p", [{Type, Error}])
    end,
    ns_server_cluster_sup:start_cluster(),
    timer:apply_after(1000, ?MODULE, log_joined, []),
    {noreply, State};

handle_cast(leave, State) ->
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
    ok = ns_server_cluster_sup:stop_cluster(),
    ns_mnesia:delete_schema(),
    error_logger:info_msg("ns_cluster: leaving cluster~n"),
    timer:sleep(1000),
    ns_server_cluster_sup:start_cluster(),
    {noreply, State}.



handle_info(Msg, State) ->
    ?log_info("Unexpected message ~p", [Msg]),
    {noreply, State}.


init([]) ->
    {ok, #state{}}.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

log_joined() ->
    ns_log:log(?MODULE, ?NODE_JOINED, "Node ~s joined cluster",
               [node()]).


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

%%
%% API
%%

%% Called on a node in the cluster to add us to its nodes_wanted
join(RemoteNode, NewCookie) ->
    ns_log:log(?MODULE, ?NODE_JOIN_REQUEST, "Node join request on ~s to ~s",
               [node(), RemoteNode]),

    case lists:member(RemoteNode, ns_node_disco:nodes_wanted()) of
        true -> {error, already_joined};
        false-> gen_server:cast(?MODULE, {join, RemoteNode, NewCookie})
    end.

leave() ->
    RemoteNode = ns_node_disco:random_node(),

    ns_log:log(?MODULE, ?NODE_EJECTED, "Node ~s left cluster", [node()]),

    error_logger:info_msg("ns_cluster: leaving the cluster from ~p.~n",
                         [RemoteNode]),

    %% Tell the remote server to tell everyone to shun me.
    rpc:cast(RemoteNode, ?MODULE, shun, [node()]),
    %% Then drop ourselves into a leaving state.
    leave_async().

%% Cause another node to leave the cluster if it's up
leave(Node) ->
    case Node == node() of
        true ->
            leave();
        false ->
            %% Will never fail, but may not reach the destination
            gen_server:cast({?MODULE, Node}, leave),
            shun(Node)
    end.

%% @doc Just trigger the leave code; don't get another node to shun us.
leave_async() ->
    gen_server:cast(?MODULE, leave).

%% Note that shun does *not* cause the other node to reset its config!
shun(RemoteNode) ->
    case RemoteNode == node() of
        false ->
            ?log_info("Shunning ~p", [RemoteNode]),
            ns_config:update_key(nodes_wanted,
                                 fun (X) ->
                                         X -- [RemoteNode]
                                 end),
            ns_config_rep:push();
        true ->
            ?log_info("Asked to shun myself. Leaving cluster.", []),
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

change_my_address(MyAddr) ->
    gen_server:call(?MODULE, {change_address, MyAddr}, 20000).
