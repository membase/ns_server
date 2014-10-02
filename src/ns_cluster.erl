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

-define(ADD_NODE_TIMEOUT, 160000).
-define(ENGAGE_TIMEOUT, 30000).
-define(COMPLETE_TIMEOUT, 120000).

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

-export([add_node/3,
         add_node_to_group/4,
         engage_cluster/1, complete_join/1,
         check_host_connectivity/1, change_address/1]).

%% debugging & diagnostic export
-export([do_change_address/2]).

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

add_node_to_group(RemoteAddr, RestPort, Auth, GroupUUID) ->
    RV = gen_server:call(?MODULE, {add_node_to_group, RemoteAddr, RestPort, Auth, GroupUUID}, ?ADD_NODE_TIMEOUT),
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

-spec change_address(string()) -> ok
                                      | {cannot_resolve, inet:posix()}
                                      | {cannot_listen, inet:posix()}
                                      | not_self_started
                                      | {address_save_failed, any()}
                                      | {address_not_allowed, string()}
                                      | already_part_of_cluster.
change_address(Address) ->
    case misc:is_good_address(Address) of
        ok ->
            gen_server:call(?MODULE, {change_address, Address});
        Error ->
            Error
    end.

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
    ?cluster_debug("handling add_node(~p, ~p, ..)", [RemoteAddr, RestPort]),
    RV = do_add_node(RemoteAddr, RestPort, Auth, undefined),
    ?cluster_debug("add_node(~p, ~p, ..) -> ~p", [RemoteAddr, RestPort, RV]),
    {reply, RV, State};

handle_call({add_node_to_group, RemoteAddr, RestPort, Auth, GroupUUID}, _From, State) ->
    ?cluster_debug("handling add_node(~p, ~p, ~p, ..)", [RemoteAddr, RestPort, GroupUUID]),
    RV = do_add_node(RemoteAddr, RestPort, Auth, GroupUUID),
    ?cluster_debug("add_node(~p, ~p, ~p, ..) -> ~p", [RemoteAddr, RestPort, GroupUUID, RV]),
    {reply, RV, State};

handle_call({engage_cluster, NodeKVList}, _From, State) ->
    ?cluster_debug("handling engage_cluster(~p)", [NodeKVList]),
    RV = do_engage_cluster(NodeKVList),
    ?cluster_debug("engage_cluster(..) -> ~p", [RV]),
    {reply, RV, State};

handle_call({complete_join, NodeKVList}, _From, State) ->
    ?cluster_debug("handling complete_join(~p)", [NodeKVList]),
    RV = do_complete_join(NodeKVList),
    ?cluster_debug("complete_join(~p) -> ~p", [NodeKVList, RV]),
    {reply, RV, State};

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

    ok = misc:write_file(leave_marker_path(), <<"">>),

    %% first thing we do is stopping nearly everything
    ok = ns_server_cluster_sup:stop_cluster(),

    stats_archiver:wipe(),

    %% in order to disconnect from rest of nodes we need new cookie
    %% and explicit disconnect_node calls
    NewCookie = ns_cookie_manager:cookie_gen(),
    erlang:set_cookie(node(), NewCookie),
    lists:foreach(fun erlang:disconnect_node/1, nodes()),

    %% we will preserve rest settings, so we get them before resetting
    %% config
    Config = ns_config:get(),
    RestConf = ns_config:search(Config, {node, node(), rest}),
    GlobalRestConf = ns_config:search(Config, rest),

    %% The ordering here is quite subtle. So be careful.
    %%
    %% At the time of this writing ns_config:clear([directory]) below
    %% behaves weirdly, but correctly.
    %%
    %% It will wipe dynamic config, then save it, then reload
    %% config. And as part of reloading config it will reload static
    %% config and re-generate default config. And it will even
    %% re-trigger config upgrade.
    %%
    %% And also as part of loading config it will do our usual merging
    %% of all configs into dynamic config.
    %%
    %% This means that if we intend to reset our node name, we have to
    %% do it _before_ clearing config. So that when it's generating
    %% default config (with tons of per-node keys that are really
    %% important) it must already have correct node().
    %%
    %% clear() itself does not depend on per-node keys and all
    %% services are stopped at this point
    %%
    %% So reset_address() below drops node's manually assigned
    %% hostname if any and assigns 127.0.0.1 marking it as automatic.
    net_restarted = dist_manager:reset_address(),
    %% and then we clear config. In fact better name would be 'reset',
    %% because as seen above we actually re-initialize default config
    ns_config:clear([directory]),

    %% we restore our rest settings
    case GlobalRestConf of
        false -> false;
        {value, GlobalRestConf1} -> ns_config:set(rest, GlobalRestConf1)
    end,
    case RestConf of
        false -> false;
        {value, RestConf1} -> ns_config:set({node, node(), rest}, RestConf1)
    end,

    %% set_initial here clears vclock on nodes_wanted. Thus making
    %% sure that whatever nodes_wanted we will get through initial
    %% config replication (right after joining cluster next time) will
    %% not conflict with this value.
    ns_config:set_initial(nodes_wanted, [node()]),
    ns_cookie_manager:cookie_sync(),

    ReplicatorDeleteRV = ns_couchdb_storage:delete_couch_database(<<"_replicator">>),
    ?cluster_debug("Deleted _replicator db: ~p", [ReplicatorDeleteRV]),

    ?cluster_debug("Leaving cluster", []),
    timer:sleep(1000),

    ok = file:delete(leave_marker_path()),
    {ok, _} = ns_server_cluster_sup:start_cluster(),
    ns_ports_setup:restart_memcached(),
    {noreply, State}.



handle_info(Msg, State) ->
    ?cluster_debug("Unexpected message ~p", [Msg]),
    {noreply, State}.


init([]) ->
    case file:read_file_info(leave_marker_path()) of
        {ok, _} ->
            ?log_info("found marker of in-flight cluster leave. Looks like previous leave procedure crashed. Going to complete leave cluster procedure"),
            %% we have to do it async because otherwise our parent
            %% supervisor is waiting us to complete init and our call
            %% to terminate ns_server_sup is going to cause deadlock
            gen_server:cast(self(), leave);
        _ ->
            ok
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
    ns_config_rep:push(),
    ok = ns_config_rep:synchronize_remote([RemoteNode]),
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
    Cluster30 = cluster_compat_mode:is_cluster_30(),

    case RemoteNode == node() of
        false ->
            ?cluster_debug("Shunning ~p", [RemoteNode]),
            ok = ns_config:update(
                   fun ({nodes_wanted, V}, _) ->
                           {nodes_wanted, V -- [RemoteNode]};
                       ({server_groups, Groups}, _) ->
                           G2 = [case proplists:get_value(nodes, G) of
                                     Nodes ->
                                         NewNodes = Nodes -- [RemoteNode],
                                         lists:keystore(nodes, 1, G, {nodes, NewNodes})
                                 end || G <- Groups],
                           {server_groups, G2};
                       ({{node, Node, _}, _}, {SoftDelete, _})
                         when Node =:= RemoteNode andalso Cluster30 ->
                           SoftDelete;
                       (Other, _) ->
                           Other
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

-spec do_change_address(string(), boolean()) -> ok | {address_save_failed, _} | not_self_started.
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
            ok;
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
              %% prevent node disco events while we're in the middle
              %% of renaming
              ns_node_disco:register_node_renaming_txn(self()),
              case dist_manager:adjust_my_address(NewAddr, UserSupplied) of
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
                      master_activity_events:note_name_changed(),
                      NewName = node(),

                      %% update new node name on child couchdb node
                      ns_couchdb_config_rep:update_ns_server_node_name(NewName),

                      ?cluster_debug("Renaming node from ~p to ~p.", [OldName, NewName]),
                      rename_node_in_config(OldName, NewName),
                      renamed
              end
      end).

rename_node_in_config(Old, New) ->
    ns_config:update(fun ({K, V} = Pair, _) ->
                             NewK = misc:rewrite_value(Old, New, K),
                             NewV = misc:rewrite_value(Old, New, V),
                             if
                                 NewK =/= K orelse NewV =/= V ->
                                     ?cluster_debug("renaming node conf ~p -> ~p:~n  ~p ->~n  ~p",
                                                    [K, NewK, ns_config_log:sanitize(V),
                                                     ns_config_log:sanitize(NewV)]),
                                     {NewK, NewV};
                                 true ->
                                     Pair
                             end
                     end),
    ns_config:sync_announcements(),
    ns_config_rep:push(),
    ns_config_rep:synchronize_remote(ns_node_disco:nodes_actual_other()).


check_add_possible(Body) ->
    case menelaus_web:is_system_provisioned() of
        false -> {error, system_not_provisioned,
                  <<"Adding nodes to not provisioned nodes is not allowed.">>,
                  system_not_provisioned};
        true ->
            Body()
    end.

do_add_node(RemoteAddr, RestPort, Auth, GroupUUID) ->
    check_add_possible(fun () ->
                               do_add_node_allowed(RemoteAddr, RestPort, Auth, GroupUUID)
                       end).

should_change_address() ->
    %% adjust our name if we're alone
    ns_node_disco:nodes_wanted() =:= [node()] andalso
        not dist_manager:using_user_supplied_address().

do_add_node_allowed(RemoteAddr, RestPort, Auth, GroupUUID) ->
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
                            ok ->
                                ok
                        end;
                    _ ->
                        ok
                end,
            case R of
                ok ->
                    do_add_node_with_connectivity(RemoteAddr, RestPort, Auth, GroupUUID);
                {address_save_failed, Error} = Nested ->
                    Msg = io_lib:format("Could not save address after rename: ~p",
                                        [Error]),
                    {error, rename_failed, iolist_to_binary(Msg), Nested}
            end;
        X -> X
    end.

do_add_node_with_connectivity(RemoteAddr, RestPort, Auth, GroupUUID) ->
    {struct, NodeInfo} = menelaus_web:build_full_node_info(node(), "127.0.0.1"),
    Struct = {struct, [{<<"requestedTargetNodeHostname">>, list_to_binary(RemoteAddr)}
                       | NodeInfo]},

    ?cluster_debug("Posting node info to engage_cluster on ~p:~n~p",
                   [{RemoteAddr, RestPort}, Struct]),
    RV = menelaus_rest:json_request_hilevel(post,
                                            {RemoteAddr, RestPort, "/engageCluster2",
                                             "application/json",
                                             mochijson2:encode(Struct)},
                                            Auth),
    ?cluster_debug("Reply from engage_cluster on ~p:~n~p",
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
                do_add_node_engaged(NodeKVList, Auth, GroupUUID)
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
    ?cluster_debug("port_please(~p, ~p) = ~p", [Name, Host, Port]),
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

do_add_node_engaged(NodeKVList, Auth, GroupUUID) ->
    OtpNode = expect_json_property_atom(<<"otpNode">>, NodeKVList),
    RV = verify_otp_connectivity(OtpNode),
    case RV of
        ok ->
            case check_can_add_node(NodeKVList) of
                ok ->
                    node_add_transaction(OtpNode, GroupUUID,
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
                    <<"1.",_/binary>> = Version ->
                        {error, incompatible_cluster_version,
                         iolist_to_binary(io_lib:format("Joining ~s node to this cluster is not supported. " ++
                                                        "Upgrade node to Couchbase Server version 2 or greater and retry.", [Version])),
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

    ?cluster_debug("Posting the following to complete_join on ~p:~n~p",
                   [HostnameRaw, Struct]),
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

node_add_transaction(Node, GroupUUID, Body) ->
    TXNRV = ns_config:run_txn(
              fun (Cfg, SetFn) ->
                      {value, NWanted} = ns_config:search(Cfg, nodes_wanted),
                      NewNWanted = lists:usort([Node | NWanted]),
                      Cfg1 = SetFn(nodes_wanted, NewNWanted, Cfg),
                      Cfg2 = SetFn({node, Node, membership}, inactiveAdded, Cfg1),
                      case ns_config:search(Cfg, cluster_compat_version, undefined) of
                          [_A, _B] = CompatVersion when CompatVersion >= [2, 5] ->
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
                                      Cfg3 = SetFn(server_groups, NewGroups, Cfg2),
                                      {commit, Cfg3}
                              end;
                          _ ->
                              %% we're pre 2.5 compat mode. Not touching server groups
                              {commit, Cfg2}
                      end
              end),
    case TXNRV of
        {commit, _} ->
            node_add_transaction_finish(Node, GroupUUID, Body);
        {abort, notfound} ->
            M = iolist_to_binary([<<"Could not find group with uuid: ">>, GroupUUID]),
            {error, unknown_group, M, {unknown_group, GroupUUID}};
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
    MaybeError = case Version of
                     <<"1.",_/binary>> = Version ->
                         {error, incompatible_cluster_version,
                          iolist_to_binary(io_lib:format("Joining ~s cluster is not supported. " ++
                                                         "Upgrade node to Couchbase Server version 2 or greater and retry.", [Version])),
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
                    do_engage_cluster_inner_tail(NodeKVList, Address, UserSupplied);
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

do_engage_cluster_inner_tail(NodeKVList, Address, UserSupplied) ->
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
            check_can_join_to(NodeKVList)
    end.

check_memory_size(NodeKVList) ->
    Quota = expect_json_property_integer(<<"memoryQuota">>, NodeKVList),
    MemoryFuzzyness = case (catch list_to_integer(os:getenv("MEMBASE_RAM_FUZZYNESS"))) of
                          X when is_integer(X) -> X;
                          _ -> 50
                      end,
    MaxMemoryMB = ns_storage_conf:allowed_node_quota_max_for_joined_nodes(),
    if
        Quota =< MaxMemoryMB + MemoryFuzzyness ->
            ok;
        true ->
            ThisMegs = element(1, ns_storage_conf:this_node_memory_data()) div ?MIB,
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

-spec do_complete_join([{binary(), term()}]) -> {ok, ok} | {error, atom(), binary(), term()}.
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

        RV = ns_couchdb_storage:delete_couch_database(<<"_replicator">>),
        ?cluster_debug("Deleted _replicator db: ~p.", [RV]),
        case RV =:= ok orelse RV =:= not_found of
            true ->
                ok;
            false ->
                throw({could_not_delete_replicator_db, RV})
        end,

        MyNode = node(),
        ns_config:update(fun ({directory,_} = X, _) -> X;
                             ({otp, _}, _) -> {otp, [{cookie, NewCookie}]};
                             ({nodes_wanted, _} = X, _) -> X;
                             ({{node, _, membership}, _}, {_, BlackSpot}) -> BlackSpot;
                             ({{node, Node, _}, _} = X, _) when Node =:= MyNode -> X;
                             (_, {_, BlackSpot}) -> BlackSpot
                         end),
        ns_config:set_initial(nodes_wanted, [node(), RemoteNode]),
        ns_config:set_initial(cluster_compat_version, undefined),
        ?cluster_debug("pre-join cleaned config is:~n~p", [ns_config:get()]),
        {ok, _Cookie} = ns_cookie_manager:cookie_sync(),
        %% Let's verify connectivity.
        Connected = net_kernel:connect_node(RemoteNode),
        ?cluster_debug("Connection from ~p to ~p:  ~p",
                       [node(), RemoteNode, Connected]),
        {ok, ok}
    catch
        Type:Error ->
            Stack = erlang:get_stacktrace(),

            ?cluster_error("Error during join: ~p", [{Type, Error, Stack}]),
            {ok, _} = ns_server_cluster_sup:start_cluster(),

            erlang:raise(Type, Error, Stack)
    end,
    ?cluster_debug("Join status: ~p, starting ns_server_cluster back",
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
            ?cluster_error("Failed to join cluster because of: ~p",
                           [Status2]),
            Status2
    end.

leave_marker_path() ->
    path_config:component_path(data, "leave_marker").
