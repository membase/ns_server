-module(ns_pool).

-export([pool_join/2, pool_leave/1, pool_leave/0]).

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
            case ns_config:get_remote(RemoteNode) of
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
    NewWanted = lists:subtract(ns_node_disco:nodes_wanted(), [RemoteNode]),
    ns_config:set(nodes_wanted, NewWanted),
    ok.

pool_leave() ->
    ns_node_disco:cookie_init(),
    ns_config:set(nodes_wanted, [node()]),
    ok.
