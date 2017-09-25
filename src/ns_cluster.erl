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

-define(ADD_NODE_TIMEOUT, ns_config:get_timeout({ns_cluster, add_node}, 160000)).
-define(ENGAGE_TIMEOUT, ns_config:get_timeout({ns_cluster, engage}, 30000)).
-define(COMPLETE_TIMEOUT, ns_config:get_timeout({ns_cluster, complete}, 120000)).
-define(CHANGE_ADDRESS_TIMEOUT, ns_config:get_timeout({ns_cluster, change_address}, 30000)).

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
         force_eject_self/0,
         shun/1,
         start_link/0]).

-export([add_node_to_group/5,
         engage_cluster/1, complete_join/1,
         check_host_connectivity/1, change_address/1,
         enforce_topology_limitation/1,
         rename_marker_path/0,
         sanitize_node_info/1]).

%% debugging & diagnostic export
-export([do_change_address/2]).

-export([counters/0,
         counter_inc/1,
         counter_inc/2]).

-export([alert_key/1]).
-record(state, {}).

%%
%% API
%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add_node_to_group(RemoteAddr, RestPort, Auth, GroupUUID, Services) ->
    RV = gen_server:call(?MODULE, {add_node_to_group, RemoteAddr, RestPort, Auth, GroupUUID, Services},
                         ?ADD_NODE_TIMEOUT),
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
            engage_cluster_not_to_self(NodeKVList)
    end.

engage_cluster_not_to_self(NodeKVList) ->
    case proplists:get_value(<<"clusterCA">>, NodeKVList) of
        undefined ->
            call_engage_cluster(NodeKVList);
        ClusterCA ->
            case ns_server_cert:apply_certificate_chain_from_inbox(ClusterCA) of
                {ok, Props} ->
                    ?log_info("Custom certificate was loaded on the node before joining. Props: ~p",
                              [Props]),
                    call_engage_cluster(NodeKVList);
                {error, Error} ->
                    Message =
                        iolist_to_binary(["Error applying node certificate. ",
                                           ns_error_messages:reload_node_certificate_error(Error)]),
                    {error, apply_cert, Message, {apply_cert, Error}}
            end
    end.

call_engage_cluster(NodeKVList) ->
    gen_server:call(?MODULE, {engage_cluster, NodeKVList}, ?ENGAGE_TIMEOUT).

complete_join(NodeKVList) ->
    gen_server:call(?MODULE, {complete_join, NodeKVList}, ?COMPLETE_TIMEOUT).

-spec change_address(string()) -> ok
                                      | {cannot_resolve, inet:posix()}
                                      | {cannot_listen, inet:posix()}
                                      | not_self_started
                                      | {address_save_failed, any()}
                                      | {address_not_allowed, string()}
                                      | already_part_of_cluster
                                      | not_renamed.
change_address(Address) ->
    case misc:is_good_address(Address) of
        ok ->
            gen_server:call(?MODULE, {change_address, Address}, ?CHANGE_ADDRESS_TIMEOUT);
        Error ->
            Error
    end.

%% @doc Returns proplist of cluster-wide counters.
counters() ->
    ns_config:search(ns_config:latest(), counters, []).

%% @doc Increment a cluster-wide counter.
counter_inc(CounterName) ->
    % We expect counters to be slow moving (num rebalances, num failovers,
    % etc), and favor efficient reads over efficient writes.
    PList = counters(),
    ok = ns_config:set(counters,
                       [{CounterName, proplists:get_value(CounterName, PList, 0) + 1} |
                        proplists:delete(CounterName, PList)]).

counter_inc(Type, Name)
  when is_atom(type), is_atom(Name) ->
    counter_inc(list_to_atom(atom_to_list(Type) ++ "_" ++ atom_to_list(Name))).

%%
%% gen_server handlers
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

sanitize_node_info(NodeKVList) ->
    misc:rewrite_tuples(
      fun ({<<"otpCookie">>, Cookie}) ->
              {stop, {<<"otpCookie">>, ns_cookie_manager:sanitize_cookie(Cookie)}};
          ({otpCookie, Cookie}) ->
              {stop, {otpCookie, ns_cookie_manager:sanitize_cookie(Cookie)}};
          (Other) ->
              {continue, Other}
      end, NodeKVList).

handle_call({add_node_to_group, RemoteAddr, RestPort, Auth, GroupUUID, Services}, _From, State) ->
    ?cluster_debug("handling add_node(~p, ~p, ~p, ..)", [RemoteAddr, RestPort, GroupUUID]),
    RV = do_add_node(RemoteAddr, RestPort, Auth, GroupUUID, Services),
    ?cluster_debug("add_node(~p, ~p, ~p, ..) -> ~p", [RemoteAddr, RestPort, GroupUUID, RV]),
    {reply, RV, State};

handle_call({engage_cluster, NodeKVList}, _From, State) ->
    ?cluster_debug("handling engage_cluster(~p)", [sanitize_node_info(NodeKVList)]),
    RV = do_engage_cluster(NodeKVList),
    ?cluster_debug("engage_cluster(..) -> ~p", [RV]),
    {reply, RV, State};

handle_call({complete_join, NodeKVList}, _From, State) ->
    ?cluster_debug("handling complete_join(~p)", [sanitize_node_info(NodeKVList)]),
    RV = do_complete_join(NodeKVList),
    ?cluster_debug("complete_join(~p) -> ~p", [sanitize_node_info(NodeKVList), RV]),

    case RV of
        %% we failed to start ns_server back; we don't want to stay in this
        %% state, so perform_actual_join has created a marker file indicating
        %% that somebody needs to attempt to start ns_server back; usually
        %% this somebody is ns_cluster:init; so to let it do its job we need
        %% to restart ns_cluster; note that we still reply to the caller
        {error, start_cluster_failed, _, _} ->
            {stop, start_cluster_failed, RV, State};
        _ ->
            {reply, RV, State}
    end;

handle_call({change_address, Address}, _From, State) ->
    ?cluster_info("Changing address to ~p due to client request", [Address]),
    RV = case ns_cluster_membership:system_joinable() of
             true ->
                 %% we're the only node in the cluster; allowing rename
                 do_change_address(Address, true);
             false ->
                 already_part_of_cluster
         end,
    {reply, RV, State}.

handle_cast(leave, State) ->
    ?cluster_log(0001, "Node ~p is leaving cluster.", [node()]),

    misc:create_marker(leave_marker_path()),

    %% empty users storage
    users_storage_sup:stop_replicator(),
    menelaus_users:empty_storage(),

    %% stop nearly everything
    ok = ns_server_cluster_sup:stop_ns_server(),

    stats_archiver:wipe(),

    %% in order to disconnect from rest of nodes we need new cookie
    %% and explicit disconnect_node calls
    {ok, _} = ns_cookie_manager:cookie_init(),

    %% reset_address() below drops user_assigned flag (if any) which makes
    %% it possible for the node to be renamed if necessary
    ok = dist_manager:reset_address(),
    %% and then we clear config. In fact better name would be 'reset',
    %% because as seen above we actually re-initialize default config
    ns_config:clear([directory,
                     %% we preserve rest settings, so if the server runs on a
                     %% custom port, it doesn't revert to the default
                     rest,
                     {node, node(), rest}]),


    %% set_initial here clears vclock on nodes_wanted. Thus making
    %% sure that whatever nodes_wanted we will get through initial
    %% config replication (right after joining cluster next time) will
    %% not conflict with this value.
    ns_config:set_initial(nodes_wanted, [node()]),
    {ok, _} = ns_cookie_manager:cookie_sync(),

    ReplicatorDeleteRV = ns_couchdb_storage:delete_couch_database_files("_replicator"),
    ?cluster_debug("Deleted _replicator db: ~p", [ReplicatorDeleteRV]),

    ?cluster_debug("Leaving cluster", []),

    misc:create_marker(start_marker_path()),
    misc:remove_marker(leave_marker_path()),

    {ok, _} = ns_server_cluster_sup:start_ns_server(),
    ns_ports_setup:restart_memcached(),

    misc:remove_marker(start_marker_path()),

    {noreply, State};
handle_cast(retry_start_ns_server, State) ->
    case ns_server_cluster_sup:start_ns_server() of
        {ok, _} ->
            ok;
        {error, running} ->
            ?log_warning("ns_server is already running. Ignoring."),
            ok;
        Other ->
            exit({failed_to_start_ns_server, Other})
    end,

    ns_ports_setup:restart_memcached(),

    misc:remove_marker(start_marker_path()),

    {noreply, State}.


handle_info(Msg, State) ->
    ?cluster_debug("Unexpected message ~p", [Msg]),
    {noreply, State}.


init([]) ->
    case misc:marker_exists(leave_marker_path()) of
        true ->
            ?log_info("Found marker of in-flight cluster leave. "
                      "Looks like previous leave procedure crashed. "
                      "Going to complete leave cluster procedure."),
            %% we have to do it async because otherwise our parent
            %% supervisor is waiting us to complete init and our call
            %% to terminate ns_server_sup is going to cause deadlock
            gen_server:cast(self(), leave);
        false ->
            case misc:marker_exists(start_marker_path()) of
                true ->
                    ?log_info("Found marker ~p. "
                              "Looks like we failed to restart ns_server "
                              "after leaving or joining a cluster. "
                              "Will try again.", [start_marker_path()]),
                    gen_server:cast(self(), retry_start_ns_server);
                false ->
                    ok
            end
    end,
    {ok, #state{}}.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%


%%
%% API
%%

leave() ->
    RemoteNode = ns_node_disco:random_node(),
    ?cluster_log(?NODE_EJECTED, "Node ~s left cluster", [node()]),
    %% MB-3160: sync any pending config before we leave, to make sure,
    %% say, deactivation of membership isn't lost
    ok = ns_config_rep:ensure_config_seen_by_nodes([RemoteNode]),
    ?cluster_debug("ns_cluster: leaving the cluster from ~p.",
                   [RemoteNode]),
    %% Tell the remote server to tell everyone to shun me.
    rpc:cast(RemoteNode, ?MODULE, shun, [node()]),
    %% Then drop ourselves into a leaving state.
    leave_async().

force_eject_self() ->
    %% first send leave
    gen_server:cast(?MODULE, leave),
    %% then sync. This will return error, but will be processed
    %% strictly after cast
    gen_server:call(?MODULE, {complete_join, []}, infinity),
    ok.

%% Cause another node to leave the cluster if it's up
leave(Node) ->
    ?cluster_debug("Asking node ~p to leave the cluster", [Node]),

    case Node =:= node() of
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
    case RemoteNode =:= node() of
        false ->
            ?cluster_debug("Shunning ~p", [RemoteNode]),
            ok = ns_config:update(
                   fun ({nodes_wanted, V}) ->
                           {update, {nodes_wanted, V -- [RemoteNode]}};
                       ({server_groups, Groups}) ->
                           G2 = [case proplists:get_value(nodes, G) of
                                     Nodes ->
                                         NewNodes = Nodes -- [RemoteNode],
                                         lists:keystore(nodes, 1, G, {nodes, NewNodes})
                                 end || G <- Groups],
                           {update, {server_groups, G2}};
                       ({{node, Node, _}, _})
                         when Node =:= RemoteNode ->
                           delete;
                       (_Other) ->
                           skip
                   end),
            ns_config_rep:ensure_config_pushed();
        true ->
            ?cluster_debug("Asked to shun myself. Leaving cluster.", []),
            leave()
    end.

alert_key(?NODE_JOINED) -> server_joined;
alert_key(?NODE_EJECTED) -> server_left;
alert_key(_) -> all.

check_host_connectivity(OtherHost) ->
    %% connect to epmd at other side
    ConnRV = (catch gen_tcp:connect(OtherHost, 4369, [misc:get_net_family(),
                                                      binary,
                                                      {packet, 0},
                                                      {active, false}], 5000)),
    case ConnRV of
        {ok, Socket} ->
            %% and determine our ip address
            {ok, {IpAddr, _}} = inet:sockname(Socket),
            inet:close(Socket),
            Separator = case misc:get_env_default(ns_server, ipv6, false) of
                            true -> ":";
                            false -> "."
                        end,
            RV = string:join(lists:map(fun erlang:integer_to_list/1,
                                       tuple_to_list(IpAddr)), Separator),
            {ok, RV};
        _ ->
            Reason =
                case ConnRV of
                    {'EXIT', R} ->
                        R;
                    {error, R} ->
                        R
                end,

            M = case ns_error_messages:connection_error_message(Reason, OtherHost, "4369") of
                    undefined ->
                        list_to_binary(io_lib:format("Failed to reach erlang port mapper "
                                                     "at node ~p. Error: ~p", [OtherHost, Reason]));
                    Msg ->
                        iolist_to_binary([<<"Failed to reach erlang port mapper. ">>, Msg])
                end,

            {error, host_connectivity, M, ConnRV}
    end.

-spec do_change_address(string(), boolean()) -> ok | not_renamed |
                                                {address_save_failed, _} | not_self_started.
do_change_address(NewAddr, UserSupplied) ->
    NewAddr1 =
        case UserSupplied of
            false ->
                misc:get_env_default(rename_ip, NewAddr);
            true ->
                NewAddr
        end,

    ?cluster_info("Change of address to ~p is requested.", [NewAddr1]),
    case maybe_rename(NewAddr1, UserSupplied) of
        not_renamed ->
            not_renamed;
        renamed ->
            ns_server_sup:node_name_changed(),
            ?cluster_info("Renamed node. New name is ~p.", [node()]),
            ok;
        Other ->
            Other
    end.

maybe_rename(NewAddr, UserSupplied) ->
    OldName = node(),
    misc:executing_on_new_process(
      fun () ->
              Self = self(),

              OnRename = fun() ->
                                 %% prevent node disco events while we're in the middle
                                 %% of renaming
                                 ns_node_disco:register_node_renaming_txn(Self),

                                 %% prevent breaking remote monitors while we're in the middle
                                 %% of renaming
                                 remote_monitors:register_node_renaming_txn(Self)
                         end,

              case dist_manager:adjust_my_address(NewAddr, UserSupplied, OnRename) of
                  nothing ->
                      ?cluster_debug("Not renaming node.", []),
                      not_renamed;
                  not_self_started ->
                      ?cluster_debug("Didn't rename the node because net_kernel "
                                     "is not self started", []),
                      not_self_started;
                  {address_save_failed, _} = Error ->
                      Error;
                  net_restarted ->
                      ?cluster_debug("Renamed node from ~p to ~p.", [OldName, node()]),
                      renamed
              end
      end).

check_add_possible(Body) ->
    case ns_config_auth:is_system_provisioned() of
        false -> {error, system_not_provisioned,
                  <<"Adding nodes to not provisioned nodes is not allowed.">>,
                  system_not_provisioned};
        true ->
            Body()
    end.

do_add_node(RemoteAddr, RestPort, Auth, GroupUUID, Services) ->
    check_add_possible(
      fun () ->
              do_add_node_allowed(RemoteAddr, RestPort, Auth,
                                  GroupUUID, Services)
      end).

should_change_address() ->
    %% adjust our name if we're alone
    ns_node_disco:nodes_wanted() =:= [node()] andalso
        not dist_manager:using_user_supplied_address().

do_add_node_allowed(RemoteAddr, RestPort, Auth, GroupUUID, Services) ->
    case check_host_connectivity(RemoteAddr) of
        {ok, MyIP} ->
            R = case should_change_address() of
                    true ->
                        case do_change_address(MyIP, false) of
                            {address_save_failed, _} = E ->
                                E;
                            not_self_started ->
                                ?cluster_debug("Haven't changed address because of not_self_started condition", []),
                                ok;
                            not_renamed ->
                                ok;
                            ok ->
                                ok
                        end;
                    _ ->
                        ok
                end,
            case R of
                ok ->
                    do_add_node_with_connectivity(RemoteAddr, RestPort, Auth,
                                                  GroupUUID, Services);
                {address_save_failed, Error} = Nested ->
                    Msg = io_lib:format("Could not save address after rename: ~p",
                                        [Error]),
                    {error, rename_failed, iolist_to_binary(Msg), Nested}
            end;
        X -> X
    end.

do_add_node_with_connectivity(RemoteAddr, RestPort, Auth, GroupUUID, Services) ->
    {struct, NodeInfo} = menelaus_web:build_full_node_info(node(), "127.0.0.1"),
    Props = [{<<"requestedTargetNodeHostname">>, list_to_binary(RemoteAddr)},
             {<<"requestedServices">>, Services}]
        ++ NodeInfo,

    Props1 =
        case ns_server_cert:cluster_ca() of
            {CAProps, _, _} ->
                [{<<"clusterCA">>, proplists:get_value(pem, CAProps)} | Props];
            _ ->
                Props
        end,

    ?cluster_debug("Posting node info to engage_cluster on ~p:~n~p",
                   [{RemoteAddr, RestPort}, {sanitize_node_info(Props1)}]),
    RV = menelaus_rest:json_request_hilevel(post,
                                            {RemoteAddr, RestPort, "/engageCluster2",
                                             "application/json",
                                             mochijson2:encode({Props1})},
                                            Auth),
    ?cluster_debug("Reply from engage_cluster on ~p:~n~p",
                   [{RemoteAddr, RestPort}, sanitize_node_info(RV)]),

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
                do_add_node_engaged(NodeKVList, Auth, GroupUUID, Services)
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
    expect_integer(PropName, RV).

expect_integer(PropName, Value) ->
    case is_integer(Value) of
        true -> Value;
        false -> erlang:exit({unexpected_json, not_integer, PropName})
    end.

call_port_please(Name, Host) ->
    %% When the 'Host' parameter is the actual hostname the epmd:port_please API
    %% implementation uses "inet" protocol by default. This will fail if the
    %% host is configured with IPv6. But if we pass in the IP Address instead of
    %% hostname the API does the right thing. Hence passing the IP Address.
    {ok, IpAddr} = inet:getaddr(Host, misc:get_net_family()),
    case erl_epmd:port_please(Name, IpAddr, 5000) of
        {port, Port, _Version} -> Port;
        X -> X
    end.

verify_otp_connectivity(OtpNode) ->
    {Name, Host} = misc:node_name_host(OtpNode),
    Port = call_port_please(Name, Host),
    ?cluster_debug("port_please(~p, ~p) = ~p", [Name, Host, Port]),
    case is_integer(Port) of
        false ->
            {error, connect_node,
             ns_error_messages:verify_otp_connectivity_port_error(OtpNode, Port),
             {connect_node, OtpNode, Port}};
        true ->
            case gen_tcp:connect(Host, Port,
                                 [misc:get_net_family(), binary,
                                  {packet, 0}, {active, false}],
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

do_add_node_engaged(NodeKVList, Auth, GroupUUID, Services) ->
    OtpNode = expect_json_property_atom(<<"otpNode">>, NodeKVList),
    RV = verify_otp_connectivity(OtpNode),
    case RV of
        ok ->
            case check_can_add_node(NodeKVList) of
                ok ->
                    %% TODO: only add services if possible
                    %% TODO: consider getting list of supported
                    %% services from NodeKVList
                    node_add_transaction(OtpNode, GroupUUID, Services,
                                         fun () ->
                                                 do_add_node_engaged_inner(NodeKVList, OtpNode, Auth, Services)
                                         end);
                Error -> Error
            end;
        X -> X
    end.

check_can_add_node(NodeKVList) ->
    JoineeClusterCompatVersion = expect_json_property_integer(<<"clusterCompatibility">>, NodeKVList),
    JoineeNode = expect_json_property_atom(<<"otpNode">>, NodeKVList),

    MyCompatVersion = misc:expect_prop_value(cluster_compatibility_version, dict:fetch(node(), ns_doctor:get_nodes())),
    case JoineeClusterCompatVersion =:= MyCompatVersion of
        true -> case expect_json_property_binary(<<"version">>, NodeKVList) of
                    <<"1.",_/binary>> = Version ->
                        {error, incompatible_cluster_version,
                         ns_error_messages:too_old_version_error(JoineeNode, Version),
                         incompatible_cluster_version};
                    _ ->
                        ok
                end;
        false -> {error, incompatible_cluster_version,
                  ns_error_messages:incompatible_cluster_version_error(MyCompatVersion,
                                                                       JoineeClusterCompatVersion,
                                                                       JoineeNode),
                  {incompatible_cluster_version, MyCompatVersion, JoineeClusterCompatVersion}}
    end.

do_add_node_engaged_inner(NodeKVList, OtpNode, Auth, Services) ->
    HostnameRaw = expect_json_property_list(<<"hostname">>, NodeKVList),
    [Hostname, Port] = case string:tokens(HostnameRaw, ":") of
                           [_, _] = Pair -> Pair;
                           [H] -> [H, "8091"];
                           _ -> erlang:exit({unexpected_json, malformed_hostname, HostnameRaw})
                       end,

    {struct, MyNodeKVList} = menelaus_web:build_full_node_info(node(), "127.0.0.1"),
    Struct = {struct, [{<<"targetNode">>, OtpNode},
                       {<<"requestedServices">>, Services}
                       | MyNodeKVList]},

    ?cluster_debug("Posting the following to complete_join on ~p:~n~p",
                   [HostnameRaw, sanitize_node_info(Struct)]),
    RV = menelaus_rest:json_request_hilevel(post,
                                            {Hostname, Port, "/completeJoin",
                                             "application/json",
                                             mochijson2:encode(Struct)},
                                            Auth,
                                            [{timeout, ?COMPLETE_TIMEOUT},
                                             {connect_timeout, ?COMPLETE_TIMEOUT}]),
    ?cluster_debug("Reply from complete_join on ~p:~n~p",
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

do_node_add_transaction(Cfg, SetFn, Node, NWanted, Services, GroupUUID) ->
    NewNWanted = lists:usort([Node | NWanted]),
    Cfg1 = SetFn(nodes_wanted, NewNWanted, Cfg),
    Cfg2 = SetFn({node, Node, membership}, inactiveAdded, Cfg1),
    CfgPreGroups = SetFn({node, Node, services}, Services, Cfg2),
    case ns_config:search(Cfg, cluster_compat_version, undefined) of
        [_A, _B] = CompatVersion when CompatVersion >= ?VERSION_25 ->
            {value, Groups} = ns_config:search(Cfg, server_groups),
            MaybeGroup0 = [G || G <- Groups,
                                proplists:get_value(uuid, G) =:= GroupUUID],
            MaybeGroup = case MaybeGroup0 of
                             [] ->
                                 case GroupUUID of
                                     undefined ->
                                         [hd(Groups)];
                                     _ ->
                                         []
                                 end;
                             _ ->
                                 true = (undefined =/= GroupUUID),
                                 MaybeGroup0
                         end,
            case MaybeGroup of
                [] ->
                    {abort, notfound};
                [TheGroup] ->
                    GroupNodes = proplists:get_value(nodes, TheGroup),
                    true = (is_list(GroupNodes)),
                    NewGroupNodes = lists:usort([Node | GroupNodes]),
                    NewGroup = lists:keystore(nodes, 1, TheGroup, {nodes, NewGroupNodes}),
                    NewGroups = lists:usort([NewGroup | (Groups -- MaybeGroup)]),
                    Cfg3 = SetFn(server_groups, NewGroups, CfgPreGroups),
                    {commit, Cfg3}
            end;
        _ ->
            %% we're pre 2.5 compat mode. Not touching server groups
            {commit, CfgPreGroups}
    end.

node_add_transaction(Node, GroupUUID, Services, Body) ->
    TXNRV = ns_config:run_txn(
              fun (Cfg, SetFn) ->
                      {value, NWanted} = ns_config:search(Cfg, nodes_wanted),
                      case lists:member(Node, NWanted) of
                          true ->
                              {abort, node_present};
                          false ->
                              do_node_add_transaction(Cfg, SetFn, Node, NWanted, Services, GroupUUID)
                      end
              end),
    case TXNRV of
        {commit, _} ->
            node_add_transaction_finish(Node, GroupUUID, Body);
        {abort, notfound} ->
            M = iolist_to_binary([<<"Could not find group with uuid: ">>, GroupUUID]),
            {error, unknown_group, M, {unknown_group, GroupUUID}};
        {abort, node_present} ->
            M = iolist_to_binary([<<"Node already exists in cluster: ">>,
                                  atom_to_list(Node)]),
            {error, node_present, M, {node_present, Node}};
        retry_needed ->
            erlang:error(exceeded_retries)
    end.

node_add_transaction_finish(Node, GroupUUID, Body) ->
    ?cluster_info("Started node add transaction by adding node ~p to nodes_wanted (group: ~s)",
                  [Node, GroupUUID]),
    try Body() of
        {ok, _} = X -> X;
        Crap ->
            ?cluster_error("Add transaction of ~p failed because of ~p",
                           [Node, Crap]),
            shun(Node),
            Crap
    catch
        Type:What ->
            ?cluster_error("Add transaction of ~p failed because of exception ~p",
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
    Node = expect_json_property_atom(<<"otpNode">>, NodeKVList),

    case Version of
        <<"1.",_/binary>> ->
            {error, incompatible_cluster_version,
             ns_error_messages:too_old_version_error(Node, Version),
             incompatible_cluster_version};
        _ ->
            do_engage_cluster_check_compat_version(Node, Version, NodeKVList)
    end.

do_engage_cluster_check_compat_version(Node, Version, NodeKVList) ->
    ActualCompatibility = expect_json_property_integer(<<"clusterCompatibility">>, NodeKVList),
    MinSupportedCompatVersion = cluster_compat_mode:min_supported_compat_version(),
    MinSupportedCompatibility =
        cluster_compat_mode:effective_cluster_compat_version_for(MinSupportedCompatVersion),

    case ActualCompatibility < MinSupportedCompatibility of
        true ->
            {error, incompatible_cluster_version,
             ns_error_messages:too_old_version_error(Node, Version),
             incompatible_cluster_version};
        false ->
            do_engage_cluster_check_services(NodeKVList)
    end.

get_requested_services(KVList) ->
    Default = ns_cluster_membership:default_services(),
    do_get_requested_services(<<"requestedServices">>, KVList, Default).

do_get_requested_services(Key, KVList, Default) ->
    case lists:keyfind(Key, 1, KVList) of
        false ->
            {ok, Default};
        {_, List} ->
            case is_list(List) of
                false ->
                    erlang:exit({unexpected_json, not_list, Key});
                _ ->
                    case [[] || B <- List, not is_binary(B)] =:= [] of
                        false ->
                            erlang:exit({unexpected_json, not_list, Key});
                        true ->
                            try
                                {ok, [binary_to_existing_atom(S, latin1) || S <- List]}
                            catch
                                error:badarg ->
                                    {bad_services, List}
                            end
                    end
            end
    end.

community_allowed_topologies() ->
    KvOnly = [kv],
    AllServices40 = ns_cluster_membership:supported_services_for_version(?VERSION_40),
    AllServices = ns_cluster_membership:supported_services(),

    [KvOnly, lists:sort(AllServices40), lists:sort(AllServices)].

enforce_topology_limitation(Services) ->
    case cluster_compat_mode:is_enterprise() of
        true ->
            ok;
        false ->
            SortedServices = lists:sort(Services),
            SupportedCombinations = community_allowed_topologies(),
            case lists:member(SortedServices, SupportedCombinations) of
                true ->
                    ok;
                false ->
                    {error, ns_error_messages:topology_limitation_error(SupportedCombinations)}
            end
    end.

do_engage_cluster_check_services(NodeKVList) ->
    SupportedServices = ns_cluster_membership:supported_services(),
    case get_requested_services(NodeKVList) of
        {ok, Services} ->
            case Services -- SupportedServices of
                [] ->
                    case enforce_topology_limitation(Services) of
                        {error, Msg} ->
                            {error, incompatible_services, Msg, incompatible_services};
                        ok ->
                            do_engage_cluster_inner(NodeKVList, Services)
                    end;
                _ ->
                    unsupported_services_error(SupportedServices, Services)
            end;
        {bad_services, RawServices} ->
            unsupported_services_error(SupportedServices, RawServices)
    end.

unsupported_services_error(Supported, Requested) ->
    {error, incompatible_services,
     ns_error_messages:unsupported_services_error(Supported, Requested),
     incompatible_services}.

do_engage_cluster_inner(NodeKVList, Services) ->
    OtpNode = expect_json_property_atom(<<"otpNode">>, NodeKVList),
    MaybeTargetHost = proplists:get_value(<<"requestedTargetNodeHostname">>, NodeKVList),
    {_, Host} = misc:node_name_host(OtpNode),
    case check_host_connectivity(Host) of
        {ok, MyIP} ->
            {Address, UserSupplied} =
                case MaybeTargetHost of
                    undefined ->
                        {MyIP, false};
                    _ ->
                        TargetHost = binary_to_list(MaybeTargetHost),
                        {TargetHost, true}
                end,

            case do_engage_cluster_inner_check_address(Address, UserSupplied) of
                ok ->
                    do_engage_cluster_inner_tail(NodeKVList, Address, UserSupplied, Services);
                Error ->
                    Error
            end;
        X -> X
    end.

do_engage_cluster_inner_check_address(_Address, false) ->
    ok;
do_engage_cluster_inner_check_address(Address, true) ->
    case misc:is_good_address(Address) of
        ok ->
            ok;
        {ErrorType, _} = Error ->
            Msg0 = case Error of
                       {cannot_resolve, Errno} ->
                           io_lib:format("Address \"~s\" could not be resolved: ~p",
                                         [Address, Errno]);
                       {cannot_listen, Errno} ->
                           io_lib:format("Could not listen on address \"~s\": ~p",
                                         [Address, Errno]);
                       {address_not_allowed, ErrorMsg} ->
                           io_lib:format("Requested address \"~s\" is not allowed: ~s",
                                         [Address, ErrorMsg])
                   end,

            Msg = iolist_to_binary(Msg0),
            {error, ErrorType, Msg, Error}
    end.

do_engage_cluster_inner_tail(NodeKVList, Address, UserSupplied, Services) ->
    case do_change_address(Address, UserSupplied) of
        {address_save_failed, Error1} = Nested ->
            Msg = io_lib:format("Could not save address after rename: ~p",
                                [Error1]),
            {error, rename_failed, iolist_to_binary(Msg), Nested};
        _ ->
            %% we re-init node's cookie to support joining cloned
            %% nodes. If we don't do that cluster will be able to
            %% connect to this node too soon. And then initial set of
            %% nodes_wanted by node thats added to cluster may
            %% 'pollute' cluster's version and cause issues. See
            %% MB-4476 for details.
            ns_cookie_manager:cookie_init(),
            check_can_join_to(NodeKVList, Services)
    end.

check_memory_size(NodeKVList, Services) ->
    KvQuota = expect_json_property_integer(<<"memoryQuota">>, NodeKVList),
    IndexQuota =
        case lists:keyfind(<<"indexMemoryQuota">>, 1, NodeKVList) of
            {_, V} ->
                expect_integer(<<"indexMemoryQuota">>, V);
            false ->
                undefined
        end,
    FTSQuota =
        case lists:keyfind(<<"ftsMemoryQuota">>, 1, NodeKVList) of
            {_, V2} ->
                expect_integer(<<"ftsMemoryQuota">>, V2);
            false ->
                undefined
        end,

    Quotas1 = [{kv, KvQuota}],
    Quotas0 =
        case IndexQuota of
            undefined ->
                Quotas1;
            _ ->
                [{index, IndexQuota} | Quotas1]
        end,
    Quotas =
        case FTSQuota of
            undefined ->
                Quotas0;
            _ ->
                [{fts, FTSQuota} | Quotas0]
        end,

    case ns_storage_conf:check_this_node_quotas(Services, Quotas) of
        ok ->
            ok;
        {error, {total_quota_too_high, _, TotalQuota, MaxQuota}} ->
            Error = {error, bad_memory_size, [{max, MaxQuota},
                                              {totalQuota, TotalQuota}]},
            {error, bad_memory_size,
             ns_error_messages:bad_memory_size_error(Services, TotalQuota, MaxQuota),
             Error}
    end.

check_can_join_to(NodeKVList, Services) ->
    case check_memory_size(NodeKVList, Services) of
        ok -> {ok, ok};
        Error -> Error
    end.

-spec do_complete_join([{binary(), term()}]) -> {ok, ok} | {error, atom(), binary(), term()}.
do_complete_join(NodeKVList) ->
    try
        OtpNode = expect_json_property_atom(<<"otpNode">>, NodeKVList),
        OtpCookie = expect_json_property_atom(<<"otpCookie">>, NodeKVList),
        MyNode = expect_json_property_atom(<<"targetNode">>, NodeKVList),

        {ok, Services} = get_requested_services(NodeKVList),
        case check_can_join_to(NodeKVList, Services) of
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

    %% empty users storage
    menelaus_users:empty_storage(),

    %% Pull the rug out from under the app
    misc:create_marker(start_marker_path()),
    ok = ns_server_cluster_sup:stop_ns_server(),
    ns_log:delete_log(),
    Status = try
        ?cluster_debug("ns_cluster: joining cluster. Child has exited.", []),

        RV = ns_couchdb_storage:delete_couch_database_files("_replicator"),
        ?cluster_debug("Deleted _replicator db: ~p.", [RV]),
        case RV =:= ok of
            true ->
                ok;
            false ->
                throw({could_not_delete_replicator_db, RV})
        end,

        MyNode = node(),
        %% Generate new node UUID while joining a cluster.
        %% We want to prevent situations where multiple nodes in
        %% the same cluster end up having same node uuid because they
        %% were created from same virtual machine image.
        ns_config:regenerate_node_uuid(),

        %% For the keys that are being preserved and have vclocks,
        %% we will just update_vclock so that these keys get stamped
        %% with new node uuid vclock.
        ns_config:update(fun ({directory,_}) ->
                                 skip;
                             ({otp, _}) ->
                                 {update, {otp, [{cookie, NewCookie}]}};
                             ({nodes_wanted, _}) ->
                                 {set_initial, {nodes_wanted, [node(), RemoteNode]}};
                             ({cluster_compat_mode, _}) ->
                                 {set_initial, {cluster_compat_mode, undefined}};
                             ({{node, _, services}, _}) ->
                                 erase;
                             ({{node, Node, membership}, _} = P) when Node =:= MyNode ->
                                 {set_initial, P};
                             ({{node, Node, _}, _} = Pair) when Node =:= MyNode ->
                                 %% update for the sake of incrementing the
                                 %% vclock
                                 {update, Pair};
                             (_) ->
                                 erase
                         end),

        ns_config:merge_dynamic_and_static(),
        ?cluster_debug("pre-join cleaned config is:~n~p", [ns_config_log:sanitize(ns_config:get())]),

        {ok, _Cookie} = ns_cookie_manager:cookie_sync(),
        %% Let's verify connectivity.
        Connected = net_kernel:connect_node(RemoteNode),
        ?cluster_debug("Connection from ~p to ~p:  ~p",
                       [node(), RemoteNode, Connected]),

        ok = ns_config_rep:pull_from_one_node_directly(RemoteNode),
        ?cluster_debug("pre-join merged config is:~n~p", [ns_config_log:sanitize(ns_config:get())]),

        {ok, ok}
    catch
        Type:Error ->
            Stack = erlang:get_stacktrace(),

            ?cluster_error("Error during join: ~p", [{Type, Error, Stack}]),
            {ok, _} = ns_server_cluster_sup:start_ns_server(),
            misc:remove_marker(start_marker_path()),

            erlang:raise(Type, Error, Stack)
    end,
    ?cluster_debug("Join status: ~p, starting ns_server_cluster back",
                   [Status]),
    Status2 = case ns_server_cluster_sup:start_ns_server() of
                  {error, _} = E ->
                      {error, start_cluster_failed,
                       <<"Failed to start ns_server cluster processes back. Logs might have more details.">>,
                       E};
                  {ok, _} ->
                      misc:remove_marker(start_marker_path()),
                      Status
              end,

    case Status2 of
        {ok, _} ->
            ?cluster_log(?NODE_JOINED, "Node ~s joined cluster", [node()]);
        _ ->
            ?cluster_error("Failed to join cluster because of: ~p", [Status2])
    end,
    Status2.

leave_marker_path() ->
    path_config:component_path(data, "leave_marker").

start_marker_path() ->
    path_config:component_path(data, "start_marker").

rename_marker_path() ->
    path_config:component_path(data, "rename_marker").
