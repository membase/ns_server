% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_node_disco).

%% API
-export([start_link/0,
         init/0,
         nodes_wanted/0, nodes_wanted_raw/0,
         nodes_wanted_updated/0, nodes_wanted_updated/1,
         nodes_actual/0, nodes_actual_proper/0,
         cookie_init/0, cookie_get/0, cookie_set/1, cookie_sync/0,
         loop/0]).

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
    lists:subtract(Curr, Diff).

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
    ns_config:set(otp, [{cookie, Cookie}]).

% Gets our wanted otp cookie (might be =/= our actual otp cookie).
%
cookie_get() ->
    ns_config:search_prop(ns_config:get(), otp, cookie).

% Makes our wanted otp cookie =:= to our actual cookie.
% Will generate a cookie if needed for the first time.
%
cookie_sync() ->
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
            error_logger:info_msg("New node:  ~p~n", [Node]);
        {nodedown, Node} ->
            error_logger:info_msg("Lost node:  ~p~n", [Node])
    end,
    % update_node_list(),
    ?MODULE:loop().

