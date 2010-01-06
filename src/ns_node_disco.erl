% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_node_disco).

%% API
-export([start_link/0,
         init/0,
         nodes_wanted/0, nodes_wanted_updated/0, nodes_wanted_updated/1,
         nodes_actual/0, nodes_actual_proper/0,
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
    NodeList = lists:sort(NodeListIn),
    error_logger:info_msg("nodes_wanted updated ~p~n", [NodeList]),
    lists:filter(fun(N) -> net_adm:ping(N) == pong end, NodeList).

nodes_wanted() ->
    case ns_config:search(ns_config:get(), nodes_wanted) of
        {value, NodeList} -> lists:sort(NodeList);
        false             -> []
    end.

% Returns all nodes that we see.

nodes_actual() ->
    lists:sort([node() | nodes()]).

% Returns a subset of the nodes_wanted() that we see.

nodes_actual_proper() ->
    % TODO: Track flapping nodes and attenuate.
    %
    Curr = nodes_actual(),
    Want = nodes_wanted(),
    Diff = lists:subtract(Curr, Want),
    lists:subtract(Curr, Diff).

cookie_sync() ->
    case ns_config:search_prop(ns_config:get(), otp, cookie) of
        undefined ->
            case erlang:get_cookie() of
                nocookie ->
                    % TODO: We should have length(nodes_wanted) == 0 or 1,
                    %       so, we should check that assumption.
                    {A1,A2,A3} = now(),
                    random:seed(A1, A2, A3),
                    NewCookie = list_to_atom(misc:rand_str(16)),
                    ns_log:log(?MODULE, 0001, "generated otp cookie: ~p",
                               [NewCookie]),
                    ns_config:set(otp, [{cookie, NewCookie}]),
                    {ok, init, generated};
                CurrCookie ->
                    ns_log:log(?MODULE, 0002, "inheriting otp cookie: ~p",
                               [CurrCookie]),
                    ns_config:set(otp, [{cookie, CurrCookie}]),
                    {ok, init}
            end;
        WantedCookie ->
            case erlang:get_cookie() of
                WantedCookie -> {ok, same};
                _ ->
                    ns_log:log(?MODULE, 0003, "setting otp cookie: ~p",
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
