%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

-module(ns_cluster).

-export([join/2, leave/1, leave/0,
         join_params/0]).

% Assuming our caller has made this node into an 'empty' node
% that's joinable to another cluster, and assumes caller
% has shutdown or is responsible for higher-level applications
% (eg, emoxi, menelaus) as needed.
%
% After this function finishes, the caller may restart
% higher-level applications, and then it should call
% ns_config:reannounce() to get config-change
% event callbacks asynchronously fired.
%
join(RemoteNode, NewCookie) ->
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
                              ok = ns_config:reannounce(),
                              ok;
                        E -> join_err(OldCookie, E)
                    end;
                E -> join_err(OldCookie, E)
            end;
        E -> join_err(OldCookie, E)
    end.

join_err(undefined, E) -> {error, E};
join_err(OldCookie, E) -> erlang:set_cookie(node(), OldCookie),
                          {error, E}.

% Should be invoked on a node that remains in the cluster,
% where the leaving RemoteNode is passed in as an argument.
%
leave(RemoteNode) ->
    catch(rpc:call(RemoteNode, ?MODULE, leave, [], 500)),
    NewWanted = lists:subtract(ns_node_disco:nodes_wanted(), [RemoteNode]),
    ns_config:set(nodes_wanted, NewWanted),
    ok.

leave() ->
    ns_log:log(?MODULE, 0001, "leaving cluster"),
    % First, change our cookie to stop talking with the rest
    % of the cluster.
    erlang:set_cookie(node(), ns_node_disco:cookie_gen()),
    % Next, go through proper ns_config cookie & config changing.
    ns_node_disco:cookie_init(),
    ns_config:set(nodes_wanted, [node()]),
    ok.

% Parameters to pass to join() to allow a remote node to join to
% me, mostly for more convenient debugging/development.

join_params() ->
    [node(), ns_node_disco:cookie_get()].
