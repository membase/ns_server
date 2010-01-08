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
         config_push/0, config_push/1, config_pull/0,
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

nodes_wanted_updated() ->
    nodes_wanted_updated(nodes_wanted()).

nodes_wanted_updated(NodeListIn) ->
    cookie_sync(),
    NodeList = lists:usort(NodeListIn),
    error_logger:info_msg("nodes_wanted updated ~p~n", [NodeList]),
    lists:filter(fun(N) -> net_adm:ping(N) == pong end, NodeList).

nodes_wanted_raw() ->
    case ns_config:search(ns_config:get(), nodes_wanted) of
        {value, L} -> lists:usort(L);
        false      -> []
    end.

nodes_wanted() ->
    % Add ourselves to nodes_wanted, if not already.
    W1 = nodes_wanted_raw(),
    W2 = lists:usort([node() | W1]),
    case W2 =/= W1 of
        true  -> ns_config:set(nodes_wanted, W2);
        false -> ok
    end,
    W2.

% Returns all nodes that we see.

nodes_actual() ->
    lists:usort([node() | nodes()]).

% Returns a subset of the nodes_wanted() that we see.

nodes_actual_proper() ->
    % TODO: Track flapping nodes and attenuate.
    %
    Curr = nodes_actual(),
    Want = nodes_wanted(),
    Diff = lists:subtract(Curr, Want),
    lists:usort(lists:subtract(Curr, Diff)).

% Returns nodes_actual_proper(), but with self node() filtered out.

nodes_actual_other() ->
    lists:subtract(ns_node_disco:nodes_actual_proper(), [node()]).

cookie_init() ->
    {A1,A2,A3} = now(),
    random:seed(A1, A2, A3),
    NewCookie = list_to_atom(misc:rand_str(16)),
    ns_log:log(?MODULE, 0001, "otp cookie generated: ~p",
               [NewCookie]),
    cookie_set(NewCookie).

% Gets our wanted otp cookie.
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

loop() ->
    receive
        {nodeup, Node} ->
            error_logger:info_msg("new node: ~p~n", [Node]);
        {nodedown, Node} ->
            error_logger:info_msg("lost node: ~p~n", [Node])
    end,
    % TODO: Need to update_node_list(),
    ?MODULE:loop().

% --------------------------------------------------

pool_join(RemoteNode, NewCookie) ->
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

config_push() ->
    Dynamic = ns_config:get_dynamic(node()),
    config_push(Dynamic).

config_push(RawKVList) ->
    Nodes = nodes_actual_other(),
    misc:pmap(fun(Node) -> ns_config:set_remote(Node, RawKVList) end,
              Nodes, 0, 2000),
    Nodes.

config_pull() ->
    config_pull(misc:shuffle(nodes_actual_other()), 5).

config_pull([], _N)    -> ok;
config_pull(_Nodes, 0) -> ok;
config_pull([Node | Rest], N) ->
    case (catch ns_config:get_dynamic(Node)) of
        {'EXIT', _, _} -> config_pull(Rest, N - 1);
        {'EXIT', _}    -> config_pull(Rest, N - 1);
        RemoteKVList   -> ns_config:replace(RemoteKVList)
    end.

