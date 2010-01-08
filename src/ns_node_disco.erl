% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_node_disco).

%% API
-export([start_link/0,
         init/0,
         nodes_wanted/0, nodes_wanted_raw/0,
         nodes_wanted_updated/0, nodes_wanted_updated/1,
         nodes_actual/0,
         nodes_actual_proper/0,
         nodes_actual_other/0,
         cookie_init/0, cookie_get/0, cookie_set/1, cookie_sync/0,
         pool_join/2,
         pool_leave/1, pool_leave/0,
         config_push/0, config_push/1, config_push/2,
         config_pull/0, config_pull/1,
         loop/0]).

-include_lib("eunit/include/eunit.hrl").

start_link() ->
    {ok, spawn_link(?MODULE, init, [])}.

%
% Node Discovery and monitoring
%

init() ->
    nodes_wanted_updated(),
    ok = net_kernel:monitor_nodes(true),
    % the ns_node_disco_conf_events gen_event handler will inform
    % me when relevant configuration changes.
    gen_event:add_handler(ns_config_events, ns_node_disco_conf_events, self()),
    loop().

% Callback invoked when ns_config keys have changed.

nodes_wanted_updated() ->
    nodes_wanted_updated(nodes_wanted()).

% Callback invoked when ns_config keys have changed.

nodes_wanted_updated(NodeListIn) ->
    cookie_sync(),
    NodeList = lists:usort(NodeListIn),
    error_logger:info_msg("nodes_wanted updated ~p~n", [NodeList]),
    lists:filter(fun(N) -> net_adm:ping(N) == pong end, NodeList).

% Read from ns_config nodes_wanted.

nodes_wanted_raw() ->
    case ns_config:search(ns_config:get(), nodes_wanted) of
        {value, L} -> lists:usort(L);
        false      -> []
    end.

% Read from ns_config nodes_wanted, and add ourselves to nodes_wanted,
% if not already there.

nodes_wanted() ->
    W1 = nodes_wanted_raw(),
    W2 = lists:usort([node() | W1]),
    case W2 =/= W1 of
        true  -> ns_config:set(nodes_wanted, W2);
        false -> ok
    end,
    W2.

% Returns all nodes that we see.
% TODO: Track flapping nodes and attenuate.

nodes_actual() ->
    lists:usort([node() | nodes()]).

% Returns a subset of the nodes_wanted() that we see.

nodes_actual_proper() ->
    Curr = nodes_actual(),
    Want = nodes_wanted(),
    Diff = lists:subtract(Curr, Want),
    lists:usort(lists:subtract(Curr, Diff)).

% Returns nodes_actual_proper(), but with self node() filtered out.

nodes_actual_other() ->
    lists:subtract(ns_node_disco:nodes_actual_proper(), [node()]).

% -----------------------------------------------------------

cookie_gen() ->
    {A1, A2, A3} = erlang:now(),
    random:seed(A1, A2, A3),
    list_to_atom(misc:rand_str(16)).

cookie_init() ->
    NewCookie = cookie_gen(),
    ns_log:log(?MODULE, 0001, "otp cookie generated: ~p",
               [NewCookie]),
    cookie_set(NewCookie).

% Sets our wanted otp cookie.
%
cookie_set(Cookie) ->
    X = ns_config:set(otp, [{cookie, Cookie}]),
    erlang:set_cookie(node(), Cookie),
    X.

% Gets our wanted otp cookie (might be =/= our actual otp cookie).
%
cookie_get() ->
    ns_config:search_prop(ns_config:get(), otp, cookie).

% Makes our wanted otp cookie =:= to our actual cookie.
% Will generate a cookie if needed for the first time.
%
cookie_sync() ->
    error_logger:info_msg("cookie_sync~n"),
    case cookie_get() of
        undefined ->
            case erlang:get_cookie() of
                nocookie ->
                    % TODO: We should have length(nodes_wanted) == 0 or 1,
                    %       so, we should check that assumption.
                    ok = cookie_init(),
                    {ok, init, generated};
                CurrCookie ->
                    ns_log:log(?MODULE, 0002, "otp cookie inherited: ~p",
                               [CurrCookie]),
                    cookie_set(CurrCookie),
                    {ok, init}
            end;
        WantedCookie ->
            case erlang:get_cookie() of
                WantedCookie -> {ok, same};
                _ ->
                    ns_log:log(?MODULE, 0003, "otp cookie sync: ~p",
                               [WantedCookie]),
                    erlang:set_cookie(node(), WantedCookie),
                    {ok, sync}
            end
    end.

% --------------------------------------------------

loop() ->
    Timeout = 5000 + trunc(random:uniform() * 55000),
    receive
        {nodeup, Node} ->
            % This codepath also handles network partition healing here.
            % This is different than a node restarting, since in a network
            % partition healing, nodes might be long-running and have
            % diverged config.
            error_logger:info_msg("new node: ~p~n", [Node]),
            spawn(fun() ->
                      % In a spawned process to not hold up nodeup/down.
                      config_pull([Node], 1)
                  end),
            ok;
        {nodedown, Node} ->
            error_logger:info_msg("lost node: ~p~n", [Node])
    after Timeout ->
        config_pull(1)
    end,
    ?MODULE:loop().

% --------------------------------------------------

% Assuming our caller has made this node into an 'empty' node
% that's joinable to another cluster/pool, and assumes caller
% has shutdown or is responsible for higher-level applications
% (eg, emoxi, menelaus) as needed.
%
% After this function finishes, the caller may restart
% higher-level applications, and then it should call
% ns_config:reannounce() to get config-change
% event callbacks asynchronously fired.
%
pool_join(RemoteNode, NewCookie) ->
    OldCookie = ns_node_disco:cookie_get(),
    true = erlang:set_cookie(node(), NewCookie),
    true = erlang:set_cookie(RemoteNode, NewCookie),
    case net_adm:ping(RemoteNode) of
        pong ->
            case ns_config:get_dynamic(RemoteNode) of
                RemoteDynamic when is_list(RemoteDynamic) ->
                    case ns_config:replace(RemoteDynamic) of
                        ok -> % The following adds node() to nodes_wanted.
                              ns_node_disco:nodes_wanted(),
                              ok = ns_config:resave(),
                              ok;
                        E -> pool_join_err(OldCookie, E)
                    end;
                E -> pool_join_err(OldCookie, E)
            end;
        E -> pool_join_err(OldCookie, E)
    end.

pool_join_err(undefined, E) -> {error, E};
pool_join_err(OldCookie, E) -> erlang:set_cookie(node(), OldCookie),
                               {error, E}.

% Should be invoked on a node that remains in the cluster/pool,
% where the leaving RemoteNode is passed in as an argument.
%
pool_leave(RemoteNode) ->
    rpc:call(RemoteNode, ?MODULE, pool_leave, [], 500),
    NewWanted = lists:subtract(nodes_wanted(), [RemoteNode]),
    ns_config:set(nodes_wanted, NewWanted),
    ok.

pool_leave() ->
    cookie_init(),
    ns_config:set(nodes_wanted, [node()]),
    ok.

% --------------------------------------------------

config_push() ->
    config_push(ns_config:get_dynamic(node())).

config_push(RawKVList) ->
    config_push(RawKVList, nodes_actual_other()).

config_push(RawKVList, OtherNodes) ->
    misc:pmap(fun(Node) -> ns_config:set_remote(Node, RawKVList) end,
              OtherNodes, length(OtherNodes), 2000).

config_pull()  -> config_pull(5).
config_pull(N) -> config_pull(misc:shuffle(nodes_actual_other()), N).

config_pull([], _N)    -> ok;
config_pull(_Nodes, 0) -> error;
config_pull([Node | Rest], N) ->
    case (catch ns_config:get_dynamic(Node)) of
        {'EXIT', _, _} -> config_pull(Rest, N - 1);
        {'EXIT', _}    -> config_pull(Rest, N - 1);
        RemoteKVList   -> ns_config:set(RemoteKVList),
                          ok
    end.

