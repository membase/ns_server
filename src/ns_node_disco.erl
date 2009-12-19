
-module(ns_node_disco).

-behaviour(gen_event).
%% API
-export([start_link/0, begin_disco/0, loop/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {disco}).

start_link() ->
    {ok, spawn_link(?MODULE, begin_disco, [])}.

init(DiscoPid) ->
    {ok, #state{disco=DiscoPid}}.

handle_event(Event, State) ->
    error_logger:info_msg("Config change:  ~p~n", [Event]),
    {ok, State}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%
% Disco monitoring
%

begin_disco() ->
    _NL = init_known_servers(ns_config:search(ns_config:get(), stored_nodes)),
    update_node_list(),
    ok = net_kernel:monitor_nodes(true),
    gen_event:add_handler(ns_config_events, ?MODULE, self()),
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
