%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-2018 Couchbase, Inc.
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

%% @doc implementation of cluster topology related REST API's

-module(menelaus_web_cluster).

-include_lib("eunit/include/eunit.hrl").
-include("ns_common.hrl").
-include("menelaus_web.hrl").

-export([handle_engage_cluster2/1,
         handle_complete_join/1,
         handle_join/1,
         serve_node_services/1,
         serve_node_services_streaming/1,
         handle_setup_services_post/1,
         handle_rebalance_progress/2,
         handle_eject_post/1,
         handle_add_node/1,
         handle_add_node_to_group/2,
         handle_failover/1,
         handle_start_graceful_failover/1,
         handle_rebalance/1,
         handle_re_add_node/1,
         handle_re_failover/1,
         handle_stop_rebalance/1,
         handle_set_recovery_type/1]).

-import(menelaus_util,
        [reply_json/2,
         reply_json/3,
         reply/2,
         reply_text/3,
         reply_ok/3,
         parse_validate_port_number/1,
         handle_streaming/2]).

handle_engage_cluster2(Req) ->
    Body = Req:recv_body(),
    {struct, NodeKVList} = mochijson2:decode(Body),
    %% a bit kludgy, but 100% correct way to protect ourselves when
    %% everything will restart.
    process_flag(trap_exit, true),
    case ns_cluster:engage_cluster(NodeKVList) of
        {ok, _} ->
            %% NOTE: for 2.1+ cluster compat we may need
            %% something fancier. For now 2.0 is compatible only with
            %% itself and 1.8.x thus no extra work is needed.
            %%
            %% The idea is that engage_cluster/complete_join sequence
            %% is our cluster version compat negotiation. First
            %% cluster sends joinee node it's info in engage_cluster
            %% payload. Node then checks if it can work in that compat
            %% mode (node itself being single node cluster works in
            %% max compat mode it supports, which is perhaps higher
            %% then cluster's). If node supports this mode, it needs
            %% to send back engage_cluster reply with
            %% clusterCompatibility of cluster compat mode. Otherwise
            %% cluster would refuse this node as it runs in higher
            %% compat mode. That could be much much higher future
            %% compat mode. So only joinee knows if it can work in
            %% backwards compatible mode or not. Thus sending back of
            %% 'corrected' clusterCompatibility in engage_cluster
            %% response is our only option.
            %%
            %% NOTE: we don't need to actually switch to lower compat
            %% mode during engage_cluster. Because complete_join will
            %% cause full restart of joinee node, which will cause it
            %% to start back in cluster's compat mode.
            %%
            %% For now we just look if 1.8.x is asking us to join it
            %% and if it is, then we reply with clusterCompatibility
            %% of 1 which is the only thing they'll support
            %%
            %% NOTE: I was thinking about simply sending back
            %% clusterCompatibility of cluster, but that would break
            %% 10.x (i.e. much future version) check of backwards
            %% compatibility with us. I.e. because 2.0 is not checking
            %% cluster's compatibility (there's no need), lying about
            %% our cluster compat mode would not allow cluster to
            %% check we're compatible with it.
            %%
            %% 127.0.0.1 below is a bit subtle. See MB-8404. In
            %% CBSE-385 we saw how mis-configured node that was forced
            %% into 127.0.0.1 address was successfully added to
            %% cluster. And my thinking is "rename node in
            %% node-details output if node is 127.0.0.1" behavior
            %% that's needed for correct client's operation is to
            %% blame here. But given engage cluster is strictly
            %% intra-cluster thing we can return 127.0.0.1 back as
            %% 127.0.0.1 and thus join attempt in CBSE-385 would be
            %% prevented at completeJoin step which would be sent to
            %% 127.0.0.1 (joiner) and bounced.
            {struct, Result} = menelaus_web_node:build_full_node_info(node(), misc:localhost()),
            {_, _} = CompatTuple = lists:keyfind(<<"clusterCompatibility">>, 1, NodeKVList),
            ThreeXCompat = cluster_compat_mode:effective_cluster_compat_version_for(
                             cluster_compat_mode:supported_compat_version()),
            ResultWithCompat =
                case CompatTuple of
                    {_, V} when V < ThreeXCompat ->
                        ?log_info("Lowering our advertised clusterCompatibility in order to enable joining older cluster"),
                        Result3 = lists:keyreplace(<<"clusterCompatibility">>, 1, Result, CompatTuple),
                        lists:keyreplace(clusterCompatibility, 1, Result3, CompatTuple);
                    _ ->
                        Result
                end,
            reply_json(Req, {struct, ResultWithCompat});
        {error, _What, Message, _Nested} ->
            reply_json(Req, [Message], 400)
    end,
    exit(normal).

handle_complete_join(Req) ->
    {struct, NodeKVList} = mochijson2:decode(Req:recv_body()),
    erlang:process_flag(trap_exit, true),
    case ns_cluster:complete_join(NodeKVList) of
        {ok, _} ->
            reply_json(Req, [], 200);
        {error, _What, Message, _Nested} ->
            reply_json(Req, [Message], 400)
    end,
    exit(normal).

handle_join(Req) ->
    %% paths:
    %%  cluster secured, admin logged in:
    %%           after creds work and node join happens,
    %%           200 returned with Location header pointing
    %%           to new /pool/default
    %%  cluster not secured, after node join happens,
    %%           a 200 returned with Location header to new /pool/default,
    %%           401 if request had
    %%  cluster either secured or not:
    %%           a 400 with json error message when join fails for whatever reason
    %%
    %% parameter example: clusterMemberHostIp=192%2E168%2E0%2E1&
    %%                    clusterMemberPort=8091&
    %%                    user=admin&password=admin123
    %%
    case ns_config_auth:is_system_provisioned() of
        true ->
            Msg = <<"Node is already provisioned. To join use controller/addNode api of the cluster">>,
            reply_json(Req, [Msg], 400);
        false ->
            handle_join_clean_node(Req)
    end.

parse_validate_services_list(ServicesList) ->
    KnownServices = ns_cluster_membership:supported_services(),
    ServicePairs = [{erlang:atom_to_list(S), S} || S <- KnownServices],
    ServiceStrings = string:tokens(ServicesList, ","),
    FoundServices = [{SN, lists:keyfind(SN, 1, ServicePairs)} || SN <- ServiceStrings],
    UnknownServices = [SN || {SN, false} <- FoundServices],
    case UnknownServices of
        [_|_] ->
            Msg = io_lib:format("Unknown services: ~p", [UnknownServices]),
            {error, iolist_to_binary(Msg)};
        [] ->
            RV = lists:usort([S || {_, {_, S}} <- FoundServices]),
            case RV of
                [] ->
                    {error, <<"At least one service has to be selected">>};
                _ ->
                    {ok, RV}
            end
    end.

parse_validate_services_list_test() ->
    {error, _} = parse_validate_services_list(""),
    ?assertEqual({ok, [index, kv, n1ql]}, parse_validate_services_list("n1ql,kv,index")),
    {ok, [kv]} = parse_validate_services_list("kv"),
    {error, _} = parse_validate_services_list("n1ql,kv,s"),
    ?assertMatch({error, _}, parse_validate_services_list("neeql,kv")).

parse_join_cluster_params(Params, ThisIsJoin) ->
    Version = proplists:get_value("version", Params, "3.0"),

    OldVersion = (Version =:= "3.0"),

    Hostname = case proplists:get_value("hostname", Params) of
                   undefined ->
                       if
                           ThisIsJoin andalso OldVersion ->
                               %%  this is for backward compatibility
                               ClusterMemberPort = proplists:get_value("clusterMemberPort", Params),
                               ClusterMemberHostIp = proplists:get_value("clusterMemberHostIp", Params),
                               case lists:member(undefined,
                                                 [ClusterMemberPort, ClusterMemberHostIp]) of
                                   true ->
                                       "";
                                   _ ->
                                       lists:concat([ClusterMemberHostIp, ":", ClusterMemberPort])
                               end;
                           true ->
                               ""
                       end;
                   X ->
                       X
               end,

    OtherUser = proplists:get_value("user", Params),
    OtherPswd = proplists:get_value("password", Params),

    Version40 = cluster_compat_mode:compat_mode_string_40(),

    VersionErrors = case Version of
                        "3.0" ->
                            [];
                        %% bound above
                        Version40 ->
                            KnownParams = ["hostname", "version", "user", "password", "services"],
                            UnknownParams = [K || {K, _} <- Params,
                                                  not lists:member(K, KnownParams)],
                            case UnknownParams of
                                [_|_] ->
                                    Msg = io_lib:format("Got unknown parameters: ~p", [UnknownParams]),
                                    [iolist_to_binary(Msg)];
                                [] ->
                                    []
                            end;
                        _ ->
                            [<<"version is not recognized">>]
                    end,

    Services = case proplists:get_value("services", Params) of
                   undefined ->
                       {ok, ns_cluster_membership:default_services()};
                   SvcParams ->
                       case parse_validate_services_list(SvcParams) of
                           {ok, Svcs} ->
                               {ok, Svcs};
                           SvcsError ->
                               SvcsError
                       end
               end,

    BasePList = [{user, OtherUser},
                 {password, OtherPswd}],

    MissingFieldErrors = [iolist_to_binary([atom_to_list(F), <<" is missing">>])
                          || {F, V} <- BasePList,
                             V =:= undefined],

    {HostnameError, ParsedHostnameRV} =
        case (catch parse_hostname(Hostname)) of
            {error, HMsgs} ->
                {HMsgs, undefined};
            {ParsedHost, ParsedPort} when is_list(ParsedHost) ->
                {[], {ParsedHost, ParsedPort}}
        end,

    Errors = MissingFieldErrors ++ VersionErrors ++ HostnameError ++
        case Services of
            {error, ServicesError} ->
                [ServicesError];
            _ ->
                []
        end,
    case Errors of
        [] ->
            {ok, ServicesList} = Services,
            {Host, Port} = ParsedHostnameRV,
            {ok, [{services, ServicesList},
                  {host, Host},
                  {port, Port}
                  | BasePList]};
        _ ->
            {errors, Errors}
    end.

handle_join_clean_node(Req) ->
    Params = Req:parse_post(),

    case parse_join_cluster_params(Params, true) of
        {errors, Errors} ->
            reply_json(Req, Errors, 400);
        {ok, Fields} ->
            OtherHost = proplists:get_value(host, Fields),
            OtherPort = proplists:get_value(port, Fields),
            OtherUser = proplists:get_value(user, Fields),
            OtherPswd = proplists:get_value(password, Fields),
            Services = proplists:get_value(services, Fields),
            handle_join_tail(Req, OtherHost, OtherPort, OtherUser, OtherPswd, Services)
    end.

handle_join_tail(Req, OtherHost, OtherPort, OtherUser, OtherPswd, Services) ->
    process_flag(trap_exit, true),
    RV = case ns_cluster:check_host_connectivity(OtherHost) of
             {ok, MyIP} ->
                 {struct, MyPList} = menelaus_web_node:build_full_node_info(node(), MyIP),
                 Hostname = misc:expect_prop_value(hostname, MyPList),

                 BasePayload = [{<<"hostname">>, Hostname},
                                {<<"user">>, []},
                                {<<"password">>, []}],

                 {Payload, Endpoint} =
                     case Services =:= ns_cluster_membership:default_services() of
                         true ->
                             {BasePayload, "/controller/addNode"};
                         false ->
                             ServicesStr = string:join([erlang:atom_to_list(S) || S <- Services], ","),
                             SVCPayload = [{"version", cluster_compat_mode:compat_mode_string_40()},
                                           {"services", ServicesStr}
                                           | BasePayload],
                             {SVCPayload, "/controller/addNodeV2"}
                     end,


                 RestRV = menelaus_rest:json_request_hilevel(post,
                                                             {OtherHost, OtherPort,
                                                              Endpoint,
                                                              "application/x-www-form-urlencoded",
                                                              mochiweb_util:urlencode(Payload)},
                                                             {OtherUser, OtherPswd}),
                 case RestRV of
                     {error, What, _M, {bad_status, 404, Msg}} ->
                         {error, What, <<"Node attempting to join an older cluster. Some of the selected services are not available.">>, {bad_status, 404, Msg}};
                     Other ->
                         Other
                 end;
             X -> X
         end,

    case RV of
        {ok, _} ->
            reply(Req, 200);
        {client_error, JSON} ->
            reply_json(Req, JSON, 400);
        {error, _What, Message, _Nested} ->
            reply_json(Req, [Message], 400)
    end,
    exit(normal).

%% waits till only one node is left in cluster
do_eject_myself_rec(0, _) ->
    exit(self_eject_failed);
do_eject_myself_rec(IterationsLeft, Period) ->
    MySelf = node(),
    case ns_node_disco:nodes_actual_proper() of
        [MySelf] -> ok;
        _ ->
            timer:sleep(Period),
            do_eject_myself_rec(IterationsLeft-1, Period)
    end.

do_eject_myself() ->
    ns_cluster:leave(),
    do_eject_myself_rec(10, 250).

handle_eject_post(Req) ->
    PostArgs = Req:parse_post(),
    %
    % either Eject a running node, or eject a node which is down.
    %
    % request is a urlencoded form with otpNode
    %
    % responses are 200 when complete
    %               401 if creds were not supplied and are required
    %               403 if creds were supplied and are incorrect
    %               400 if the node to be ejected doesn't exist
    %
    OtpNodeStr = case proplists:get_value("otpNode", PostArgs) of
                     undefined -> undefined;
                     "Self" -> atom_to_list(node());
                     "zzzzForce" ->
                         handle_force_self_eject(Req),
                         exit(normal);
                     X -> X
                 end,
    case OtpNodeStr of
        undefined ->
            reply_text(Req, "Bad Request\n", 400);
        _ ->
            OtpNode = list_to_atom(OtpNodeStr),
            case ns_cluster_membership:get_cluster_membership(OtpNode) of
                active ->
                    reply_text(Req, "Cannot remove active server.\n", 400);
                _ ->
                    do_handle_eject_post(Req, OtpNode)
            end
    end.

handle_force_self_eject(Req) ->
    erlang:process_flag(trap_exit, true),
    ns_cluster:force_eject_self(),
    ns_audit:remove_node(Req, node()),
    reply_text(Req, "done", 200),
    ok.

do_handle_eject_post(Req, OtpNode) ->
    case OtpNode =:= node() of
        true ->
            do_eject_myself(),
            ns_audit:remove_node(Req, node()),
            reply(Req, 200);
        false ->
            case lists:member(OtpNode, ns_node_disco:nodes_wanted()) of
                true ->
                    ns_cluster:leave(OtpNode),
                    ?MENELAUS_WEB_LOG(?NODE_EJECTED, "Node ejected: ~p from node: ~p",
                                      [OtpNode, erlang:node()]),
                    ns_audit:remove_node(Req, OtpNode),
                    reply(Req, 200);
                false ->
                                                % Node doesn't exist.
                    ?MENELAUS_WEB_LOG(0018, "Request to eject nonexistant server failed.  Requested node: ~p",
                                      [OtpNode]),
                    reply_text(Req, "Server does not exist.\n", 400)
            end
    end.

validate_setup_services_post(Req) ->
    Params = Req:parse_post(),
    case ns_config_auth:is_system_provisioned() of
        true ->
            {error, <<"cannot change node services after cluster is provisioned">>};
        _ ->
            ServicesString = proplists:get_value("services", Params, ""),
            case parse_validate_services_list(ServicesString) of
                {ok, Svcs} ->
                    case lists:member(kv, Svcs) of
                        true ->
                            case ns_cluster:enforce_topology_limitation(Svcs) of
                                ok ->
                                    setup_services_check_quota(Svcs, Params);
                                Error ->
                                    Error
                            end;
                        false ->
                            {error, <<"cannot setup first cluster node without kv service">>}
                    end;
                {error, Msg} ->
                    {error, Msg}
            end
    end.

setup_services_check_quota(Services, Params) ->
    Quotas = case proplists:get_value("setDefaultMemQuotas", Params, "false") of
                 "false" ->
                     lists:map(
                       fun(Service) ->
                               {ok, Quota} = memory_quota:get_quota(Service),
                               {Service, Quota}
                       end, memory_quota:aware_services(
                              cluster_compat_mode:get_compat_version()));
                 "true" ->
                     do_update_with_default_quotas(memory_quota:default_quotas(Services))
             end,

    case Quotas of
        {error, _Msg} = E ->
            E;
        _ ->
            case memory_quota:check_this_node_quotas(Services, Quotas) of
                ok ->
                    {ok, Services};
                {error, {total_quota_too_high, _, TotalQuota, MaxAllowed}} ->
                    Msg = io_lib:format("insufficient memory to satisfy memory quota "
                                        "for the services "
                                        "(requested quota is ~bMB, "
                                        "maximum allowed quota for the node is ~bMB)",
                                        [TotalQuota, MaxAllowed]),
                    {error, iolist_to_binary(Msg)}
            end
    end.

do_update_with_default_quotas(Quotas) ->
    do_update_with_default_quotas(Quotas, 10).

do_update_with_default_quotas(_, 0) ->
    {error, <<"Could not update the config with default memory quotas">>};
do_update_with_default_quotas(Quotas, RetriesLeft) ->
    case memory_quota:set_quotas(ns_config:get(), Quotas) of
        ok ->
            Quotas;
        retry_needed ->
            do_update_with_default_quotas(Quotas, RetriesLeft - 1)
    end.

handle_setup_services_post(Req) ->
    case validate_setup_services_post(Req) of
        {error, Error} ->
            reply_json(Req, [Error], 400);
        {ok, Services} ->
            ns_config:set({node, node(), services}, Services),
            ns_audit:setup_node_services(Req, node(), Services),
            reply(Req, 200)
    end.

validate_add_node_params(User, Password) ->
    Candidates = case lists:member(undefined, [User, Password]) of
                     true -> [<<"Missing required parameter.">>];
                     _ -> [case {User, Password} of
                               {[], []} -> true;
                               {[_Head | _], [_PasswordHead | _]} -> true;
                               {[], [_PasswordHead | _]} -> <<"If a username is not specified, a password must not be supplied.">>;
                               _ -> <<"A password must be supplied.">>
                           end]
                 end,
    lists:filter(fun (E) -> E =/= true end, Candidates).

%% erlang R15B03 has http_uri:parse/2 that does the job
%% reimplement after support of R14B04 will be dropped
parse_hostname(Hostname) ->
    do_parse_hostname(misc:trim(Hostname)).

do_parse_hostname([]) ->
    throw({error, [<<"Hostname is required.">>]});
do_parse_hostname(Hostname) ->
    WithoutScheme = case string:str(Hostname, "://") of
                        0 ->
                            Hostname;
                        X ->
                            Scheme = string:sub_string(Hostname, 1, X - 1),
                            case string:to_lower(Scheme) =:= "http" of
                                false ->
                                    throw({error, [list_to_binary("Unsupported protocol " ++ Scheme)]});
                                true ->
                                    string:sub_string(Hostname, X + 3)
                            end
                    end,

    {Host, StringPort} = misc:split_host_port(WithoutScheme, "8091"),
    {Host, parse_validate_port_number(StringPort)}.

handle_add_node(Req) ->
    do_handle_add_node(Req, undefined).

handle_add_node_to_group(GroupUUIDString, Req) ->
    do_handle_add_node(Req, list_to_binary(GroupUUIDString)).

do_handle_add_node(Req, GroupUUID) ->
    %% parameter example: hostname=epsilon.local, user=Administrator, password=asd!23
    Params = Req:parse_post(),

    Parsed = case parse_join_cluster_params(Params, false) of
                 {ok, ParsedKV} ->
                     case validate_add_node_params(proplists:get_value(user, ParsedKV),
                                                   proplists:get_value(password, ParsedKV)) of
                         [] ->
                             {ok, ParsedKV};
                         CredErrors ->
                             {errors, CredErrors}
                     end;
                 {errors, ParseErrors} ->
                     {errors, ParseErrors}
             end,

    case Parsed of
        {ok, KV} ->
            User = proplists:get_value(user, KV),
            Password = proplists:get_value(password, KV),
            Hostname = proplists:get_value(host, KV),
            Port = proplists:get_value(port, KV),
            Services = proplists:get_value(services, KV),
            case ns_cluster:add_node_to_group(
                   Hostname, Port,
                   {User, Password},
                   GroupUUID,
                   Services) of
                {ok, OtpNode} ->
                    ns_audit:add_node(Req, Hostname, Port, User, GroupUUID, Services, OtpNode),
                    reply_json(Req, {struct, [{otpNode, OtpNode}]}, 200);
                {error, unknown_group, Message, _} ->
                    reply_json(Req, [Message], 404);
                {error, _What, Message, _Nested} ->
                    reply_json(Req, [Message], 400)
            end;
        {errors, ErrorList} ->
            reply_json(Req, ErrorList, 400)
    end.

parse_failover_args(Req) ->
    Params = Req:parse_post(),
    NodeArg = proplists:get_value("otpNode", Params, "undefined"),
    Node = (catch list_to_existing_atom(NodeArg)),
    case Node of
        undefined ->
            {error, "No server specified."};
        _ when not is_atom(Node) ->
            {error, "Unknown server given."};
        _ ->
            {ok, Node}
    end.


handle_failover(Req) ->
    case parse_failover_args(Req) of
        {ok, Node} ->
            case ns_cluster_membership:failover(Node) of
                ok ->
                    ns_audit:failover_node(Req, Node, hard),
                    reply(Req, 200);
                rebalance_running ->
                    reply_text(Req, "Rebalance running.", 503);
                in_recovery ->
                    reply_text(Req, "Cluster is in recovery mode.", 503);
                last_node ->
                    reply_text(Req, "Last active node cannot be failed over.", 400);
                unknown_node ->
                    reply_text(Req, "Unknown server given.", 400);
                Other ->
                    reply_text(Req,
                               io_lib:format("Unexpected server error: ~p", [Other]),
                               500)
            end;
        {error, ErrorMsg} ->
            reply_text(Req, ErrorMsg, 400)
    end.

handle_start_graceful_failover(Req) ->
    case parse_failover_args(Req) of
        {ok, Node} ->
            Msg = case ns_orchestrator:start_graceful_failover(Node) of
                      ok ->
                          [];
                      in_progress ->
                          {503, "Rebalance running."};
                      in_recovery ->
                          {503, "Cluster is in recovery mode."};
                      not_graceful ->
                          {400, "Failover cannot be done gracefully (would lose vbuckets)."};
                      non_kv_node ->
                          {400, "Failover cannot be done gracefully for a node without data. Use hard failover."};
                      unknown_node ->
                          {400, "Unknown server given."};
                      last_node ->
                          {400, "Last active node cannot be failed over."};
                      {config_sync_failed, _} ->
                          {500, "Failed to synchronize config to other nodes"};
                      Other ->
                          {500,
                           io_lib:format("Unexpected server error: ~p", [Other])}
                  end,
            case Msg of
                [] ->
                    ns_audit:failover_node(Req, Node, graceful),
                    reply(Req, 200);
                {Code, Text} ->
                    reply_text(Req, Text, Code)
            end;
        {error, ErrorMsg} ->
            reply_text(Req, ErrorMsg, 400)
    end.

handle_rebalance(Req) ->
    Params = Req:parse_post(),
    case string:tokens(proplists:get_value("knownNodes", Params, ""),",") of
        [] ->
            reply_json(Req, {struct, [{empty_known_nodes, 1}]}, 400);
        KnownNodesS ->
            EjectedNodesS = string:tokens(proplists:get_value("ejectedNodes",
                                                              Params, ""), ","),
            UnknownNodes = [S || S <- EjectedNodesS ++ KnownNodesS,
                                try list_to_existing_atom(S), false
                                catch error:badarg -> true end],
            case UnknownNodes of
                [] ->
                    DeltaRecoveryBuckets = case proplists:get_value("deltaRecoveryBuckets", Params) of
                                               undefined -> all;
                                               RawRecoveryBuckets ->
                                                   [BucketName || BucketName <- string:tokens(RawRecoveryBuckets, ",")]
                                           end,
                    do_handle_rebalance(Req, KnownNodesS, EjectedNodesS, DeltaRecoveryBuckets);
                _ ->
                    reply_json(Req, {struct, [{mismatch, 1}]}, 400)
            end
    end.

-spec do_handle_rebalance(any(), [string()], [string()], all | [bucket_name()]) -> any().
do_handle_rebalance(Req, KnownNodesS, EjectedNodesS, DeltaRecoveryBuckets) ->
    EjectedNodes = [list_to_existing_atom(N) || N <- EjectedNodesS],
    KnownNodes = [list_to_existing_atom(N) || N <- KnownNodesS],
    case ns_cluster_membership:start_rebalance(KnownNodes,
                                               EjectedNodes, DeltaRecoveryBuckets) of
        already_balanced ->
            reply(Req, 200);
        in_progress ->
            reply(Req, 200);
        nodes_mismatch ->
            reply_json(Req, {struct, [{mismatch, 1}]}, 400);
        delta_recovery_not_possible ->
            reply_json(Req, {struct, [{deltaRecoveryNotPossible, 1}]}, 400);
        no_active_nodes_left ->
            reply_text(Req, "No active nodes left", 400);
        in_recovery ->
            reply_text(Req, "Cluster is in recovery mode.", 503);
        no_kv_nodes_left ->
            reply_json(Req, {struct, [{noKVNodesLeft, 1}]}, 400);
        ok ->
            ns_audit:rebalance_initiated(Req, KnownNodes, EjectedNodes, DeltaRecoveryBuckets),
            reply(Req, 200)
    end.

handle_rebalance_progress(_PoolId, Req) ->
    Status = case ns_cluster_membership:get_rebalance_status() of
                 {running, PerNode} ->
                     [{status, <<"running">>}
                      | [{atom_to_binary(Node, latin1),
                          {struct, [{progress, Progress}]}} || {Node, Progress} <- PerNode]];
                 _ ->
                     case ns_config:search(rebalance_status) of
                         {value, {none, ErrorMessage}} ->
                             [{status, <<"none">>},
                              {errorMessage, iolist_to_binary(ErrorMessage)}];
                         _ -> [{status, <<"none">>}]
                     end
             end,
    reply_json(Req, {struct, Status}, 200).

handle_stop_rebalance(Req) ->
    Params = Req:parse_qs(),
    case proplists:get_value("onlyIfSafe", Params) =:= "1" of
        true ->
            case ns_cluster_membership:stop_rebalance_if_safe() of
                unsafe ->
                    reply(Req, 400);
                _ -> %% ok | not_rebalancing
                    reply(Req, 200)
            end;
        _ ->
            ns_cluster_membership:stop_rebalance(),
            reply(Req, 200)
    end.

handle_re_add_node(Req) ->
    Params = Req:parse_post(),
    do_handle_set_recovery_type(Req, full, Params).

handle_re_failover(Req) ->
    Params = Req:parse_post(),
    NodeString = proplists:get_value("otpNode", Params, "undefined"),
    case ns_cluster_membership:re_failover(NodeString) of
        ok ->
            ns_audit:failover_node(Req, list_to_existing_atom(NodeString), cancel_recovery),
            reply(Req, 200);
        not_possible ->
            reply(Req, 400)
    end.

serve_node_services(Req) ->
    reply_ok(Req, "application/json", bucket_info_cache:build_node_services()).

serve_node_services_streaming(Req) ->
    handle_streaming(
      fun (_, _) ->
              V = bucket_info_cache:build_node_services(),
              {just_write, {write, V}}
      end, Req).

decode_recovery_type("delta") ->
    delta;
decode_recovery_type("full") ->
    full;
decode_recovery_type(_) ->
    undefined.

handle_set_recovery_type(Req) ->
    Params = Req:parse_post(),
    Type = decode_recovery_type(proplists:get_value("recoveryType", Params)),
    do_handle_set_recovery_type(Req, Type, Params).

do_handle_set_recovery_type(Req, Type, Params) ->
    NodeStr = proplists:get_value("otpNode", Params),

    Node = try
               list_to_existing_atom(NodeStr)
           catch
               error:badarg ->
                   undefined
           end,

    OtpNodeErrorMsg = <<"invalid node name or node can't be used for delta recovery">>,

    NodeSvcs = ns_cluster_membership:node_services(ns_config:latest(), Node),
    NotKVIndex = not lists:member(kv, NodeSvcs) andalso not lists:member(index, NodeSvcs),

    Errors = lists:flatten(
               [case Type of
                    undefined ->
                        [{recoveryType, <<"recovery type must be either 'delta' or 'full'">>}];
                    _ ->
                        []
                end,

                case Node of
                    undefined ->
                        [{otpNode, OtpNodeErrorMsg}];
                    _ ->
                        []
                end,

                case Type =:= delta andalso NotKVIndex of
                    true ->
                        [{otpNode, OtpNodeErrorMsg}];
                    false ->
                        []
                end]),

    case Errors of
        [] ->
            case ns_cluster_membership:update_recovery_type(Node, Type) of
                ok ->
                    ns_audit:enter_node_recovery(Req, Node, Type),
                    reply_json(Req, [], 200);
                bad_node ->
                    reply_json(Req, {struct, [{otpNode, OtpNodeErrorMsg}]}, 400)
            end;
        _ ->
            reply_json(Req, {struct, Errors}, 400)
    end.

-ifdef(EUNIT).

hostname_parsing_test() ->
    Urls = [" \t\r\nhttp://host:1025\n\r\t ",
            "http://host:100",
            "http://host:100000",
            "hTTp://host:8000",
            "ftp://host:600",
            "http://host",
            "127.0.0.1:6000",
            "host:port",
            "aaa:bb:cc",
            " \t\r\nhost\n",
            " "],

    ExpectedResults = [{"host",1025},
                       {error, [<<"The port number must be greater than 1023 and less than 65536.">>]},
                       {error, [<<"The port number must be greater than 1023 and less than 65536.">>]},
                       {"host", 8000},
                       {error, [<<"Unsupported protocol ftp">>]},
                       {"host", 8091},
                       {"127.0.0.1", 6000},
                       {error, [<<"Port must be a number.">>]},
                       {error, [<<"The hostname is malformed. If using an IPv6 address, please enclose the address within '[' and ']'">>]},
                       {"host", 8091},
                       {error, [<<"Hostname is required.">>]}],

    Results = [(catch parse_hostname(X)) || X <- Urls],

    ?assertEqual(ExpectedResults, Results),
    ok.

-endif.
