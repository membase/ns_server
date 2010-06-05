% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_cluster_membership).

-export([get_nodes_cluster_membership/0,
         get_nodes_cluster_membership/1,
         get_cluster_membership/1,
         add_node/4,
         engage_cluster/1,
         join_cluster/4]).

-export([ns_log_cat/1,
         ns_log_code_string/1]).

%% category critical
-define(MISSING_COOKIE, 0).
-define(MISSING_OTP_NODE, 1).
-define(CONNREFUSED, 2).
-define(NXDOMAIN, 3).
-define(TIMEDOUT, 4).
-define(REST_ERROR, 5).
-define(OTHER_ERROR, 6).
%% category warn
-define(PREPARE_JOIN_FAILED, 32).
%% categeory info. Starts from 256 - 32
-define(JOINED_CLUSTER, 224).

get_nodes_cluster_membership() ->
    get_nodes_cluster_membership(ns_node_disco:nodes_wanted()).

get_nodes_cluster_membership(Nodes) ->
    lists:map(fun (Node) ->
                      {Node, get_cluster_membership(Node)}
                end, Nodes).

get_cluster_membership(Node) ->
    case ns_config:search({node, Node, membership}) of
        {value, Value} -> Value;
        _ -> inactiveAdded
    end.

%% called on cluster node with IP of node to be added
%%
%% If cluster is single node cluster, then it might need to change
%% erlang node name, before other node joins it. This function
%% implements it. It also checks that other node ip is indeed reachable.
engage_cluster(RemoteIP) ->
    case ns_cluster:prepare_join_to(RemoteIP) of
        {ok, MyAddr} ->
            MyNode = node(),
            case ns_node_disco:nodes_wanted() of
                [MyNode] ->
                    %% we're alone, so adjust our name
                    case dist_manager:adjust_my_address(MyAddr) of
                        nothing -> ok;
                        net_restarted ->
                            %% and potentially restart services
                            PrevInitStatus = ns_config:search_prop(ns_config:get(),
                                                                   init_status,
                                                                   value, ""),
                            ns_cluster:leave_sync(),
                            ns_config:set(init_status, [{value, PrevInitStatus}]),
                            ok
                    end;
                %% not alone, keep present config
                _ -> ok
            end;
        {error, Reason} ->
            ErrorMsg = io_lib:format("Failed to reach erlang port mapper at your node. Error: ~p", Reason),
            {failed, ErrorMsg}
    end.

%% TODO
add_node(OtherHost, OtherPort, OtherUser, OtherPswd) ->
    ok.

join_cluster(OtherHost, OtherPort, OtherUser, OtherPswd) ->
    case handle_join_inner(OtherHost, OtherPort, OtherUser, OtherPswd) of
        {ok, undefined, _, _} ->
            ns_log:log(?MODULE, ?MISSING_COOKIE, "During node join, remote node (~p:~p) returned an invalid response: missing otpCookie (from node ~p).",
                       [OtherHost, OtherPort, node()]),
            {error, [list_to_binary("Invalid response from remote node, missing otpCookie.")]};
        {ok, _, undefined, _} ->
            ns_log:log(?MODULE, ?MISSING_OTP_NODE, "During node join, remote node (~p:~p) returned an invalid response: missing otpNode (from node ~p).",
                       [OtherHost, OtherPort, node()]),
            {error, [list_to_binary("Invalid response from remote node, missing otpNode.")]};
        {ok, Node, Cookie, MyIP} ->
            handle_join(list_to_atom(binary_to_list(Node)),
                        list_to_atom(binary_to_list(Cookie)),
                        MyIP);
        {error, prepare_failed, Reason} ->
            ns_log:log(?MODULE, ?PREPARE_JOIN_FAILED,
                       "During node join, could not connect to port mapper at ~p with reason ~p", [OtherHost, Reason]),
            {error, [list_to_binary(io_lib:format("Could not connect port mapper at ~p (tcp port 4369). With error Reason ~p. "
                                                  "This could be due to "
                                                  "firewall configured between the two nodes.", [OtherHost, Reason]))]};
        {error, econnrefused} ->
            ns_log:log(?MODULE, ?CONNREFUSED, "During node join, could not connect to ~p on port ~p from node ~p.", [OtherHost, OtherPort, node()]),
            {error, [list_to_binary(io_lib:format("Could not connect to ~p on port ~p.  "
                                                  "This could be due to an incorrect host/port combination or a "
                                                  "firewall configured between the two nodes.", [OtherHost, OtherPort]))]};
        {error, nxdomain} ->
            ns_log:log(?MODULE, ?NXDOMAIN, "During node join, failed to resolve host ~p on port ~p from node ~p.", [OtherHost, OtherPort, node()]),
            {error, [list_to_binary(io_lib:format("Failed to resolve address for ~p.  The hostname may be incorrect or not resolvable.", [OtherHost]))]};
        {error, timeout} ->
            ns_log:log(?MODULE, ?TIMEDOUT, "During node join, timeout connecting to ~p on port ~p from node ~p.", [OtherHost, OtherPort, node()]),
            {error, [list_to_binary(io_lib:format("Timeout connecting to ~p on port ~p.  "
                                                  "This could be due to an incorrect host/port combination or a "
                                                  "firewall configured between the two nodes.", [OtherHost, OtherPort]))]};
        {error, system_not_joinable} ->
            %% We are not an 'empty' node, so user should first remove
            %% buckets, etc.
            {error, [list_to_binary("Your server cannot join this cluster because you have existing buckets configured on this server. Please remove them before joining a cluster.")]};
        Any ->
            ns_log:log(?MODULE, ?REST_ERROR, "During node join, the remote host ~p on port ~p did not return a REST response.  Error encountered was: ~p",
                       [OtherHost, OtherPort, Any]),
            {error, [list_to_binary("Invalid response from remote node.  An error has been logged which may contain more information.")]}
    end.

handle_join_inner(OtherHost, OtherPort, OtherUser, OtherPswd) ->
    case tgen:system_joinable() of
        true ->
            case ns_cluster:prepare_join_to(OtherHost) of
                {ok, MyIP} ->
                    case menelaus_rest:rest_engage_cluster(OtherHost, OtherPort,
                                                           {OtherUser, OtherPswd},
                                                           MyIP) of
                        {ok, Node, Cookie} -> {ok, Node, Cookie, MyIP};
                        X -> X
                    end;
                {error, Reason} ->
                    {error, prepare_failed, Reason}
            end;
        false ->
            {error, system_not_joinable}
    end.

handle_join(OtpNode, OtpCookie, MyIP) ->
    dist_manager:adjust_my_address(MyIP),
    case ns_cluster:join(OtpNode, OtpCookie) of
        ok -> ns_log:log(?MODULE, ?JOINED_CLUSTER, "Joined cluster at node: ~p with cookie: ~p from node: ~p",
                         [OtpNode, OtpCookie, erlang:node()]),
                                                % No need to restart here, as our ns_config event watcher
                                                % will do it if our rest config changes.
              ok;
        Any -> ns_log:log(?MODULE, ?OTHER_ERROR, "Unexpected error encountered during cluster join ~p", [Any]),
               {internal_error, [list_to_binary("Unexpected error encountered during cluster join.")]}
    end.

ns_log_cat(Number) ->
    case (Number rem 256) div 32 of
        0 -> crit;
        1 -> warn;
        _ -> info
    end.

ns_log_code_string(_) ->
    "message".
