%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(ns_cluster).

-behaviour(gen_server).

-include("ns_common.hrl").

-define(UNUSED_NODE_JOIN_REQUEST, 2).
-define(NODE_JOINED, 3).
-define(NODE_EJECTED, 4).
-define(NODE_JOIN_FAILED, 5).

-define(ADD_NODE_TIMEOUT, 30000).
-define(ENGAGE_TIMEOUT, 30000).
-define(COMPLETE_TIMEOUT, 30000).

-define(cluster_log(Code, Fmt, Args),
        ale:xlog(?USER_LOGGER, ns_log_sink:get_loglevel(?MODULE, Code),
                 {?MODULE, Code}, Fmt, Args)).

-define(cluster_debug(Fmt, Args), ale:debug(?CLUSTER_LOGGER, Fmt, Args)).
-define(cluster_info(Fmt, Args), ale:info(?CLUSTER_LOGGER, Fmt, Args)).
-define(cluster_warning(Fmt, Args), ale:warn(?CLUSTER_LOGGER, Fmt, Args)).
-define(cluster_error(Fmt, Args), ale:error(?CLUSTER_LOGGER, Fmt, Args)).

%% gen_server callbacks
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1,
         terminate/2]).

%% API
-export([leave/0,
         leave/1,
         leave_async/0,
         shun/1,
         start_link/0]).

-export([add_node/3, engage_cluster/1, complete_join/1, check_host_connectivity/1]).

%% debugging & diagnostic export
-export([do_change_address/1]).

-export([counters/0,
         counter_inc/1]).

-export([alert_key/1]).
-record(state, {}).

%%
%% API
%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add_node(RemoteAddr, RestPort, Auth) ->
    RV = gen_server:call(?MODULE, {add_node, RemoteAddr, RestPort, Auth}, ?ADD_NODE_TIMEOUT),
    case RV of
        {error, _What, Message, _Nested} ->
            ?cluster_log(?NODE_JOIN_FAILED, "Failed to add node ~s:~w to cluster. ~s",
                         [RemoteAddr, RestPort, Message]);
        _ -> ok
    end,
    RV.

engage_cluster(NodeKVList) ->
    MyNode = node(),
    RawOtpNode = proplists:get_value(<<"otpNode">>, NodeKVList, <<"undefined">>),
    case binary_to_atom(RawOtpNode, latin1) of
        MyNode ->
            {error, self_join,
             <<"Joining node to itself is not allowed.">>, {self_join, MyNode}};
        _ ->
            gen_server:call(?MODULE, {engage_cluster, NodeKVList}, ?ENGAGE_TIMEOUT)
    end.

complete_join(NodeKVList) ->
    gen_server:call(?MODULE, {complete_join, NodeKVList}, ?COMPLETE_TIMEOUT).

%% @doc Returns proplist of cluster-wide counters.
counters() ->
    case ns_config:search(counters) of
        {value, PList} -> PList;
        false -> []
    end.

%% @doc Increment a cluster-wide counter.
counter_inc(CounterName) ->
    % We expect counters to be slow moving (num rebalances, num failovers,
    % etc), and favor efficient reads over efficient writes.
    PList = counters(),
    ok = ns_config:set(counters,
                       [{CounterName, proplists:get_value(CounterName, PList, 0) + 1} |
                        proplists:delete(CounterName, PList)]).

%%
%% gen_server handlers
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call({add_node, RemoteAddr, RestPort, Auth}, _From, State) ->
    ?cluster_debug("handling add_node(~p, ~p, ..)~n", [RemoteAddr, RestPort]),
    RV = do_add_node(RemoteAddr, RestPort, Auth),
    ?cluster_debug("add_node(~p, ~p, ..) -> ~p~n", [RemoteAddr, RestPort, RV]),
    {reply, RV, State};

handle_call({engage_cluster, NodeKVList}, _From, State) ->
    ?cluster_debug("handling engage_cluster(~p)~n", [NodeKVList]),
    RV = do_engage_cluster(NodeKVList),
    ?cluster_debug("engage_cluster(..) -> ~p~n", [RV]),
    {reply, RV, State};

handle_call({complete_join, NodeKVList}, _From, State) ->
    ?cluster_debug("handling complete_join(~p)~n", [NodeKVList]),
    RV = do_complete_join(NodeKVList),
    ?cluster_debug("complete_join(~p) -> ~p~n", [NodeKVList, RV]),
    {reply, RV, State}.

handle_cast(leave, State) ->
    ?cluster_log(0001, "Node ~p is leaving cluster.", [node()]),
    ok = ns_server_cluster_sup:stop_cluster(),
    mb_mnesia:wipe(),
    NewCookie = ns_cookie_manager:cookie_gen(),
    erlang:set_cookie(node(), NewCookie),
    lists:foreach(fun erlang:disconnect_node/1, nodes()),
    Config = ns_config:get(),

    RestConf = ns_config:search(Config, {node, node(), rest}),
    GlobalRestConf = ns_config:search(Config, rest),
    ns_config:clear([directory]),
    case GlobalRestConf of
        false -> false;
        {value, GlobalRestConf1} -> ns_config:set(rest, GlobalRestConf1)
    end,
    case RestConf of
        false -> false;
        {value, RestConf1} -> ns_config:set({node, node(), rest}, RestConf1)
    end,
    ns_config:set_initial(nodes_wanted, [node()]),
    ns_cookie_manager:cookie_sync(),
    ?cluster_debug("Leaving cluster", []),
    timer:sleep(1000),
    {ok, _} = ns_server_cluster_sup:start_cluster(),
    {noreply, State}.



handle_info(Msg, State) ->
    ?cluster_debug("Unexpected message ~p", [Msg]),
    {noreply, State}.


init([]) ->
    {ok, #state{}}.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

rename_node(Old, New) ->
    ns_config:update(fun ({K, V} = Pair) ->
                             NewK = misc:rewrite_value(Old, New, K),
                             NewV = misc:rewrite_value(Old, New, V),
                             if
                                 NewK =/= K orelse NewV =/= V ->
                                     ?cluster_debug(
                                       "renaming node conf ~p -> ~p:~n  ~p ->~n  ~p",
                                       [K, NewK, V, NewV]),
                                     {NewK, NewV};
                                 true ->
                                     Pair
                             end
                     end, erlang:make_ref()).

%%
%% API
%%

leave() ->
    RemoteNode = ns_node_disco:random_node(),
    ?cluster_log(?NODE_EJECTED, "Node ~s left cluster", [node()]),
    %% MB-3160: sync any pending config before we leave, to make sure,
    %% say, deactivation of membership isn't lost
    ns_config_rep:push(),
    ok = ns_config_rep:synchronize_remote([RemoteNode]),
    ?cluster_debug("ns_cluster: leaving the cluster from ~p.",
                   [RemoteNode]),
    %% Tell the remote server to tell everyone to shun me.
    rpc:cast(RemoteNode, ?MODULE, shun, [node()]),
    %% Then drop ourselves into a leaving state.
    leave_async().

%% Cause another node to leave the cluster if it's up
leave(Node) ->
    ?cluster_debug("Asking node ~p to leave the cluster", [Node]),

    case Node == node() of
        true ->
            leave();
        false ->
            %% Will never fail, but may not reach the destination
            gen_server:cast({?MODULE, Node}, leave),
            shun(Node)
    end.

%% @doc Just trigger the leave code; don't get another node to shun us.
leave_async() ->
    gen_server:cast(?MODULE, leave).

%% Note that shun does *not* cause the other node to reset its config!
shun(RemoteNode) ->
    case RemoteNode == node() of
        false ->
            ?cluster_debug("Shunning ~p", [RemoteNode]),
            ns_config:update_key(nodes_wanted,
                                 fun (X) ->
                                         X -- [RemoteNode]
                                 end),
            ns_config_rep:push();
        true ->
            ?cluster_debug("Asked to shun myself. Leaving cluster.", []),
            leave()
    end.

alert_key(?NODE_JOINED) -> server_joined;
alert_key(?NODE_EJECTED) -> server_left;
alert_key(_) -> all.

check_host_connectivity(OtherHost) ->
    %% connect to epmd at other side
    case gen_tcp:connect(OtherHost, 4369,
                         [binary, {packet, 0}, {active, false}],
                         5000) of
        {ok, Socket} ->
            %% and determine our ip address
            {ok, {IpAddr, _}} = inet:sockname(Socket),
            inet:close(Socket),
            RV = string:join(lists:map(fun erlang:integer_to_list/1,
                                       tuple_to_list(IpAddr)), "."),
            {ok, RV};
        {error, Reason} = X ->
            M = case ns_error_messages:connection_error_message(Reason, OtherHost, "4369") of
                    undefined ->
                        list_to_binary(io_lib:format("Failed to reach erlang port mapper "
                                                     "at node ~p. Error: ~p", [OtherHost, Reason]));
                    Msg ->
                        iolist_to_binary([<<"Failed to reach erlang port mapper. ">>, Msg])
                end,
            {error, host_connectivity, M, X}
    end.

do_change_address(NewAddr) ->
    MyNode = node(),
    NewAddr1 = misc:get_env_default(rename_ip, NewAddr),
    case misc:node_name_host(MyNode) of
        {_, NewAddr1} ->
            %% Don't do anything if we already have the right address.
            ok;
        {_, _} ->
            ?cluster_info("Decided to change address to ~p~n", [NewAddr1]),
            case mb_mnesia:maybe_rename(NewAddr1) of
                false ->
                    ok;
                true ->
                    rename_node(MyNode, node()),
                    ns_server_sup:node_name_changed(),
                    ?cluster_info("Renamed node. New name is ~p.~n", [node()]),
                    ok
            end,
            ok
    end.

check_add_possible(Body) ->
    case menelaus_web:is_system_provisioned() of
        false -> {error, system_not_provisioned,
                  <<"Adding nodes to not provisioned nodes is not allowed.">>,
                  system_not_provisioned};
        true ->
            Body()
    end.

do_add_node(RemoteAddr, RestPort, Auth) ->
    check_add_possible(fun () ->
                               do_add_node_allowed(RemoteAddr, RestPort, Auth)
                       end).

should_change_address() ->
    %% adjust our name if we're alone
    ns_node_disco:nodes_wanted() =:= [node()].

do_add_node_allowed(RemoteAddr, RestPort, Auth) ->
    case check_host_connectivity(RemoteAddr) of
        {ok, MyIP} ->
            case should_change_address() of
                true -> do_change_address(MyIP);
                _ -> ok
            end,
            do_add_node_with_connectivity(RemoteAddr, RestPort, Auth);
        X -> X
    end.

do_add_node_with_connectivity(RemoteAddr, RestPort, Auth) ->
    Struct = menelaus_web:build_full_node_info(node(), "127.0.0.1"),

    ?cluster_debug("Posting node info to engage_cluster on ~p:~n~p~n",
                   [{RemoteAddr, RestPort}, Struct]),
    RV = menelaus_rest:json_request_hilevel(post,
                                            {RemoteAddr, RestPort, "/engageCluster2",
                                             "application/json",
                                             mochijson2:encode(Struct)},
                                            Auth),
    ?cluster_debug("Reply from engage_cluster on ~p:~n~p~n",
                   [{RemoteAddr, RestPort}, RV]),

    ExtendedRV = case RV of
                     {client_error, [Message]} = JSONErr when is_binary(Message) ->
                         {error, rest_error, Message, JSONErr};
                     {client_error, _} = JSONErr ->
                         {error, rest_error,
                          ns_error_messages:engage_cluster_json_error(undefined), JSONErr};
                     X -> X
                 end,

    case ExtendedRV of
        {ok, {struct, NodeKVList}} ->
            try
                do_add_node_engaged(NodeKVList, Auth)
            catch
                exit:{unexpected_json, _Where, _Field} = Exc ->
                    JsonMsg = ns_error_messages:engage_cluster_json_error(Exc),
                    {error, engage_cluster_bad_json, JsonMsg, Exc}
            end;
        {ok, JSON} ->
            {error, engage_cluster_bad_json,
             ns_error_messages:engage_cluster_json_error(undefined),
             {struct_expected, JSON}};
        {error, _What, Msg, _Nested} = E ->
            M = iolist_to_binary([<<"Prepare join failed. ">>, Msg]),
            {error, engage_cluster, M, E}
    end.

expect_json_property_base(PropName, KVList) ->
    case lists:keyfind(PropName, 1, KVList) of
        false ->
            erlang:exit({unexpected_json, missing_property, PropName});
        Tuple -> element(2, Tuple)
    end.

expect_json_property_binary(PropName, KVList) ->
    RV = expect_json_property_base(PropName, KVList),
    case is_binary(RV) of
        true -> RV;
        _ -> erlang:exit({unexpected_json, not_binary, PropName})
    end.

expect_json_property_list(PropName, KVList) ->
    binary_to_list(expect_json_property_binary(PropName, KVList)).

expect_json_property_atom(PropName, KVList) ->
    binary_to_atom(expect_json_property_binary(PropName, KVList), latin1).

expect_json_property_integer(PropName, KVList) ->
    RV = expect_json_property_base(PropName, KVList),
    case is_integer(RV) of
        true -> RV;
        _ -> erlang:exit({unexpected_json, not_integer, PropName})
    end.

call_port_please(Name, Host) ->
    case erl_epmd:port_please(Name, Host, 5000) of
        {port, Port, _Version} -> Port;
        X -> X
    end.

verify_otp_connectivity(OtpNode) ->
    {Name, Host} = misc:node_name_host(OtpNode),
    Port = call_port_please(Name, Host),
    ?cluster_debug("port_please(~p, ~p) = ~p~n", [Name, Host, Port]),
    case is_integer(Port) of
        false ->
            {error, connect_node,
             ns_error_messages:verify_otp_connectivity_port_error(OtpNode, Port),
             {connect_node, OtpNode, Port}};
        true ->
            case gen_tcp:connect(Host, Port,
                                 [binary, {packet, 0}, {active, false}],
                                 5000) of
                {ok, Socket} ->
                    inet:close(Socket),
                    ok;
                {error, Reason} = X ->
                    {error, connect_node,
                     ns_error_messages:verify_otp_connectivity_connection_error(Reason, OtpNode, Host, Port),
                     X}
            end
    end.

do_add_node_engaged(NodeKVList, Auth) ->
    OtpNode = expect_json_property_atom(<<"otpNode">>, NodeKVList),
    RV = verify_otp_connectivity(OtpNode),
    case RV of
        ok ->
            case check_can_add_node(NodeKVList) of
                ok ->
                    node_add_transaction(OtpNode,
                                         fun () ->
                                                 do_add_node_engaged_inner(NodeKVList, OtpNode, Auth)
                                         end);
                Error -> Error
            end;
        X -> X
    end.

check_can_add_node(NodeKVList) ->
    JoineeClusterCompatVersion = expect_json_property_integer(<<"clusterCompatibility">>, NodeKVList),
    MyCompatVersion = misc:expect_prop_value(cluster_compatibility_version, dict:fetch(node(), ns_doctor:get_nodes())),
    case JoineeClusterCompatVersion =:= MyCompatVersion of
        true -> case expect_json_property_binary(<<"version">>, NodeKVList) of
                    <<"1.6.", _/binary>> ->
                        {error, incompatible_cluster_version,
                         <<"Joining 1.6.x node to this cluster does not work">>,
                         incompatible_cluster_version};
                    <<"1.7.2",_/binary>> ->
                        ok;
                    <<"1.7.",_/binary>> = Version ->
                        {error, incompatible_cluster_version,
                         iolist_to_binary(io_lib:format("Joining ~s node to this cluster does not work", [Version])),
                         incompatible_cluster_version};
                    _ ->
                        ok
                end;
        false -> {error, incompatible_cluster_version,
                  ns_error_messages:incompatible_cluster_version_error(MyCompatVersion,
                                                                       JoineeClusterCompatVersion,
                                                                       expect_json_property_atom(<<"otpNode">>, NodeKVList)),
                  {incompatible_cluster_version, MyCompatVersion, JoineeClusterCompatVersion}}
    end.

do_add_node_engaged_inner(NodeKVList, OtpNode, Auth) ->
    HostnameRaw = expect_json_property_list(<<"hostname">>, NodeKVList),
    [Hostname, Port] = case string:tokens(HostnameRaw, ":") of
                           [_, _] = Pair -> Pair;
                           [H] -> [H, "8091"];
                           _ -> erlang:exit({unexpected_json, malformed_hostname, HostnameRaw})
                       end,

    {struct, MyNodeKVList} = menelaus_web:build_full_node_info(node(), "127.0.0.1"),
    Struct = {struct, [{<<"targetNode">>, OtpNode}
                       | MyNodeKVList]},

    ?cluster_debug("Posting the following to complete_join on ~p:~n~p~n",
                   [HostnameRaw, Struct]),
    RV = menelaus_rest:json_request_hilevel(post,
                                            {Hostname, Port, "/completeJoin",
                                             "application/json",
                                             mochijson2:encode(Struct)},
                                            Auth),
    ?cluster_debug("Reply from complete_join on ~p:~n~p~n",
                   [HostnameRaw, RV]),

    ExtendedRV = case RV of
                     {client_error, [Message]} = JSONErr when is_binary(Message) ->
                         {error, rest_error, Message, JSONErr};
                     {client_error, _} = JSONErr ->
                         {error, rest_error,
                          <<"REST call returned invalid json.">>, JSONErr};
                     X -> X
                 end,

    case ExtendedRV of
        {ok, _} -> {ok, OtpNode};
        {error, _Where, Msg, _Nested} = E ->
            M = iolist_to_binary([<<"Join completion call failed. ">>, Msg]),
            {error, complete_join, M, E}
    end.

node_add_transaction(Node, Body) ->
    Fun = fun(X) ->
                  lists:usort([Node | X])
          end,
    ns_config:update_key(nodes_wanted, Fun),
    ns_config:set({node, Node, membership}, inactiveAdded),
    ?cluster_info("Started node add transaction by adding node ~p to nodes_wanted~n",
                  [Node]),
    try Body() of
        {ok, _} = X -> X;
        Crap ->
            ?cluster_error("Add transaction of ~p failed because of ~p~n",
                           [Node, Crap]),
            shun(Node),
            Crap
    catch
        Type:What ->
            ?cluster_error("Add transaction of ~p failed because of exception ~p~n",
                           [Node, {Type, What, erlang:get_stacktrace()}]),
            shun(Node),
            erlang:Type(What),
            erlang:error(cannot_happen)
    end.

do_engage_cluster(NodeKVList) ->
    try
        case ns_cluster_membership:system_joinable() of
            false ->
                {error, system_not_joinable,
                 <<"Node is already part of cluster.">>, system_not_joinable};
            true ->
                do_engage_cluster_check_compatibility(NodeKVList)
        end
    catch
        exit:{unexpected_json, _, _} = Exc ->
            {error, unexpected_json,
             ns_error_messages:engage_cluster_json_error(Exc),
             Exc}
    end.

do_engage_cluster_check_compatibility(NodeKVList) ->
    Version = expect_json_property_binary(<<"version">>, NodeKVList),
    MaybeError = case Version of
                     <<"1.6.", _/binary>> ->
                         {error, incompatible_cluster_version,
                          <<"Joining 1.6 cluster does not work">>,
                          incompatible_cluster_version};
                     <<"1.7.2",_/binary>> ->
                         ok;
                     <<"1.7.",_/binary>> = Version ->
                         {error, incompatible_cluster_version,
                          iolist_to_binary(io_lib:format("Joining ~s cluster does not work", [Version])),
                          incompatible_cluster_version};
                     _ ->
                         ok
                 end,
    case MaybeError of
        ok ->
            do_engage_cluster_inner(NodeKVList);
        _ ->
            MaybeError
    end.


do_engage_cluster_inner(NodeKVList) ->
    OtpNode = expect_json_property_atom(<<"otpNode">>, NodeKVList),
    {_, Host} = misc:node_name_host(OtpNode),
    case check_host_connectivity(Host) of
        {ok, MyIP} ->
            case should_change_address() of
                true -> do_change_address(MyIP);
                _ -> ok
            end,
            %% we re-init node's cookie to support joining cloned
            %% nodes. If we don't do that cluster will be able to
            %% connect to this node too soon. And then initial set of
            %% nodes_wanted by node thats added to cluster may
            %% 'pollute' cluster's version and cause issues. See
            %% MB-4476 for details.
            ns_cookie_manager:cookie_init(),
            check_can_join_to(NodeKVList);
        X -> X
    end.

check_memory_size(NodeKVList) ->
    Quota = expect_json_property_integer(<<"memoryQuota">>, NodeKVList),
    MemoryFuzzyness = case (catch list_to_integer(os:getenv("MEMBASE_RAM_FUZZYNESS"))) of
                          X when is_integer(X) -> X;
                          _ -> 50
                      end,
    {_MinMemoryMB, MaxMemoryMB, _} = ns_storage_conf:allowed_node_quota_range_for_joined_nodes(),
    if
        Quota =< MaxMemoryMB + MemoryFuzzyness ->
            ok;
        true ->
            ThisMegs = element(1, ns_storage_conf:this_node_memory_data()) div 1048576,
            Error = {error, bad_memory_size, [{this, ThisMegs},
                                              {quota, Quota}]},
            {error, bad_memory_size,
             ns_error_messages:bad_memory_size_error(ThisMegs, Quota), Error}
    end.

check_can_join_to(NodeKVList) ->
    case check_memory_size(NodeKVList) of
        ok -> {ok, ok};
        Error -> Error
    end.

-spec do_complete_join([{binary(), term()}]) -> ok | {error, atom(), binary(), term()}.
do_complete_join(NodeKVList) ->
    try
        OtpNode = expect_json_property_atom(<<"otpNode">>, NodeKVList),
        OtpCookie = expect_json_property_atom(<<"otpCookie">>, NodeKVList),
        MyNode = expect_json_property_atom(<<"targetNode">>, NodeKVList),
        case check_can_join_to(NodeKVList) of
            {ok, _} ->
                case ns_cluster_membership:system_joinable() andalso MyNode =:= node() of
                    false ->
                        {error, join_race_detected,
                         <<"Node is already part of cluster.">>, system_not_joinable};
                    true ->
                        perform_actual_join(OtpNode, OtpCookie)
                end;
            Error -> Error
        end
    catch exit:{unexpected_json, _Where, _Field} = Exc ->
            {error, engage_cluster_bad_json,
             ns_error_messages:engage_cluster_json_error(undefined),
             Exc}
    end.


perform_actual_join(RemoteNode, NewCookie) ->
    ?cluster_log(0002, "Node ~p is joining cluster via node ~p.",
                 [node(), RemoteNode]),
    %% let ns_memcached know that we don't need to preserve data at all
    ns_config:set(i_am_a_dead_man, true),
    %% Pull the rug out from under the app
    ok = ns_server_cluster_sup:stop_cluster(),
    ns_log:delete_log(),
    Status = try
        ?cluster_debug("ns_cluster: joining cluster. Child has exited.", []),

        BlackSpot = make_ref(),
        MyNode = node(),
        ns_config:update(fun ({directory,_} = X) -> X;
                             ({otp, _}) -> {otp, [{cookie, NewCookie}]};
                             ({nodes_wanted, _} = X) -> X;
                             ({{node, _, membership}, _}) -> BlackSpot;
                             ({{node, Node, _}, _} = X) when Node =:= MyNode -> X;
                             (_) -> BlackSpot
                         end, BlackSpot),
        ns_config:set_initial(nodes_wanted, [node(), RemoteNode]),
        ?cluster_debug("pre-join cleaned config is:~n~p", [ns_config:get()]),
        {ok, _Cookie} = ns_cookie_manager:cookie_sync(),
        %% Let's verify connectivity.
        Connected = net_kernel:connect_node(RemoteNode),
        ?cluster_debug("Connection from ~p to ~p:  ~p",
                       [node(), RemoteNode, Connected]),
        {ok, ok}
    catch
        Type:Error ->
            ?cluster_error("Error during join: ~p",
                           [{Type, Error, erlang:get_stacktrace()}]),
            {ok, _} = ns_server_cluster_sup:start_cluster(),
            erlang:Type(Error)
    end,
    ?cluster_debug("Join status: ~p, starting ns_server_cluster back~n",
                   [Status]),
    Status2 = case ns_server_cluster_sup:start_cluster() of
                  {error, _} = E ->
                      {error, start_cluster_failed,
                       <<"Failed to start ns_server cluster processes back. Logs might have more details.">>,
                       E};
                  _ -> Status
              end,
    case Status2 of
        {ok, _} ->
            ?cluster_log(?NODE_JOINED, "Node ~s joined cluster",
                         [node()]),
            Status2;
        _ ->
            ?cluster_error("Failed to join cluster because of: ~p~n",
                           [Status2]),
            Status2
    end.
