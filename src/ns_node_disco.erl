
-module(ns_node_disco).

%% API
-export([start_link/0, init/0, loop/0]).

start_link() ->
    {ok, spawn_link(?MODULE, init, [])}.

%
% Disco monitoring
%

init() ->
    _NL = init_known_servers(ns_config:search(ns_config:get(), stored_nodes)),
    update_node_list(),
    ok = net_kernel:monitor_nodes(true),
    % the node_disco_conf_events gen_event handler will inform me when
    % relevant configuration changes.
    gen_event:add_handler(ns_config_events, node_disco_conf_events, self()),
    loop().

init_known_servers({value, NodeList}) ->
    error_logger:info_msg("Initializing with ~p~n", [NodeList]),
    lists:filter(fun(N) -> net_adm:ping(N) == pong end, NodeList);
init_known_servers(false) ->
    error_logger:info_msg("Found no initial node list~n", []),
    [].

update_node_list() ->
    ns_config:set(stored_nodes, lists:sort([node() | nodes()])).

loop() ->
    receive
        {nodeup, Node} ->
            error_logger:info_msg("New node:  ~p~n", [Node]);
        {nodedown, Node} ->
            error_logger:info_msg("Lost node:  ~p~n", [Node])
    end,
    update_node_list(),
    ?MODULE:loop().
