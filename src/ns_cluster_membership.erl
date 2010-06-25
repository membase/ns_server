% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_cluster_membership).

-export([get_nodes_cluster_membership/0,
         get_nodes_cluster_membership/1,
         get_cluster_membership/1,
         activate/1,
         add_node/4,
         deactivate/1,
         engage_cluster/1,
         engage_cluster/2,
         failover/1,
         handle_add_node_request/2,
         join_cluster/4,
         re_add_node/1,
         system_joinable/0,
         start_rebalance/2,
         stop_rebalance/0,
         get_rebalance_status/0,
         is_balanced/0
        ]).

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
-define(REST_FAILED, 7).
%% category warn
-define(PREPARE_JOIN_FAILED, 32).
%% categeory info. Starts from 256 - 32
-define(JOINED_CLUSTER, 224).

get_nodes_cluster_membership() ->
    get_nodes_cluster_membership(ns_node_disco:nodes_wanted()).

get_nodes_cluster_membership(Nodes) ->
    [{Node, get_cluster_membership(Node)} || Node <- Nodes].

get_cluster_membership(Node) ->
    case ns_config:search({node, Node, membership}) of
        {value, Value} ->
             Value;
        _ ->
            inactiveAdded
    end.

engage_cluster(RemoteIP) ->
    engage_cluster(RemoteIP, []).

%% called on cluster node with IP of node to be added
%%
%% If cluster is single node cluster, then it might need to change
%% erlang node name, before other node joins it. This function
%% implements it. It also checks that other node ip is indeed reachable.
engage_cluster(RemoteIP, Options) ->
    case ns_cluster:prepare_join_to(RemoteIP) of
        {ok, MyAddr} ->
            MyNode = node(),
            case ns_node_disco:nodes_wanted() of
                [MyNode] ->
                    %% we're alone, so adjust our name
                    ns_cluster:change_my_address(MyAddr);
                %% not alone, keep present config
                _ -> ok
            end;
        {error, Reason} ->
            case lists:member(raw_error, Options) of
                true -> {error, prepare_failed, Reason}; % compatible with handle_join_rest_failure
                _ ->
                    ErrorMsg = io_lib:format("Failed to reach erlang port mapper at your node. Error: ~p", [Reason]),
                    {error_msg, ErrorMsg}
            end
    end.

add_node(OtherHost, OtherPort, OtherUser, OtherPswd) ->
    Res = case engage_cluster(OtherHost, [raw_error, restart]) of
              ok ->
                  URL = menelaus_rest:rest_url(OtherHost, OtherPort, "/addNodeRequest"),
                  case menelaus_rest:json_request(post,
                                                  {URL, [], "application/x-www-form-urlencoded",
                                                   mochiweb_util:urlencode([{<<"otpNode">>, node()},
                                                                            {<<"otpCookie">>, erlang:get_cookie()}])},
                                                  {OtherUser, OtherPswd}) of
                      {ok, {struct, KVList}} ->
                          Value = menelaus_util:expect_prop_value(<<"otpNode">>, KVList),
                          {ok, list_to_atom(binary_to_list(Value))};
                      {error, _} = E -> E
                  end;
              X -> X
          end,
    case Res of
        {ok, _} = OK -> OK;
        Error -> handle_join_rest_failure(Error, OtherHost, OtherPort)
    end.

handle_add_node_request(OtpNode, OtpCookie) ->
    case system_joinable() of
        true -> % When a user wants to add a node to an existing cluster, this
                % codepath is called on the to-be-added node.
                [_Local, Hostname] = string:tokens(atom_to_list(OtpNode), "@"),
                case engage_cluster(Hostname) of
                    ok -> ns_cluster:join(OtpNode, OtpCookie);
                    X -> X
                end;
         false -> {error, system_not_addable}
    end.

handle_join_rest_failure(ReturnValue, OtherHost, OtherPort) ->
    case ReturnValue of
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
            Msg = io_lib:format("Failed to resolve address for ~p.  The hostname may be incorrect or not resolvable.", [OtherHost]),
            {error, [list_to_binary(Msg)]};
        {error, timeout} ->
            ns_log:log(?MODULE, ?TIMEDOUT, "During node join, timeout connecting to ~p on port ~p from node ~p.", [OtherHost, OtherPort, node()]),
            {error, [list_to_binary(io_lib:format("Timeout connecting to ~p on port ~p.  "
                                                  "This could be due to an incorrect host/port combination or a "
                                                  "firewall configured between the two nodes.", [OtherHost, OtherPort]))]};
        Other ->
            Handled = case Other of
                          {error, {_HttpInfo, _HeadersInfo, Body}} ->
                              DecodedErrors = mochijson2:decode(Body),
                              ns_log:log(?MODULE, ?REST_FAILED,
                                         "During node join, the remote host ~p on port ~p returned failure.~nError encountered was: ~p",
                                         [OtherHost, OtherPort, DecodedErrors]),
                              {error, [<<"Got error response from remote node.  An error has been logged which may contain more information.">>]};
                          _ -> false
                      end,
            case Handled of
                false ->
                    ns_log:log(?MODULE, ?REST_ERROR,
                               "During node join, the remote host ~p on port ~p did not return a REST response.~nError encountered was: ~p",
                               [OtherHost, OtherPort, Other]),
                    {error, [<<"Invalid response from remote node.  An error has been logged which may contain more information.">>]};
                X -> X
            end
    end.

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
        {error, system_not_joinable} ->
            %% We are not an 'empty' node, so user should first remove
            %% buckets, etc.
            {error, [list_to_binary("Your server cannot join this cluster because you have existing buckets configured on this server. Please remove them before joining a cluster.")]};
        OtherError -> handle_join_rest_failure(OtherError, OtherHost, OtherPort)
    end.

system_joinable() ->
    ns_node_disco:nodes_wanted() =:= [node()].

handle_join_inner(OtherHost, OtherPort, OtherUser, OtherPswd) ->
    case system_joinable() of
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
    ns_cluster:change_my_address(MyIP),
    case ns_cluster:join(OtpNode, OtpCookie) of
        ok -> ns_log:log(?MODULE, ?JOINED_CLUSTER, "Joined cluster at node: ~p with cookie: ~p from node: ~p",
                         [OtpNode, OtpCookie, erlang:node()]),
                                                % No need to restart here, as our ns_config event watcher
                                                % will do it if our rest config changes.
              ok;
        Any -> ns_log:log(?MODULE, ?OTHER_ERROR, "Unexpected error encountered during cluster join ~p", [Any]),
               {internal_error, [list_to_binary("Unexpected error encountered during cluster join.")]}
    end.

get_rebalance_status() ->
    ns_orchestrator:rebalance_progress("default").

start_rebalance(KnownNodes, EjectedNodes) ->
    case {lists:sort(ns_node_disco:nodes_wanted()),
          lists:sort(KnownNodes)} of
        {X, X} ->
            MaybeKeepNodes = KnownNodes -- EjectedNodes,
            FailedNodes = [N || {N, State} <-
                                    get_nodes_cluster_membership(MaybeKeepNodes),
                                State == inactiveFailed],
            KeepNodes = MaybeKeepNodes -- FailedNodes,
            activate(KeepNodes),
            ns_orchestrator:start_rebalance("default", KeepNodes,
                                            EjectedNodes ++ FailedNodes);
        _ -> nodes_mismatch
    end.

activate(Nodes) ->
    ns_config:set([{{node, Node, membership}, active} ||
                      Node <- Nodes]).

deactivate(Nodes) ->
    %% TODO: we should have a way to delete keys
    ns_config:set([{{node, Node, membership}, inactiveAdded}
                   || Node <- Nodes]).


stop_rebalance() ->
    ns_orchestrator:stop_rebalance("default").

is_balanced() ->
    not ns_orchestrator:needs_rebalance("default").

failover(Node) ->
    ok = ns_orchestrator:failover("default", Node),
    ns_config:set({node, Node, membership}, inactiveFailed).

re_add_node(Node) ->
    ns_config:set({node, Node, membership}, inactiveAdded).

ns_log_cat(Number) ->
    case (Number rem 256) div 32 of
        0 -> crit;
        1 -> warn;
        _ -> info
    end.

ns_log_code_string(_) ->
    "message".
