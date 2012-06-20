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
%% @doc Web server for menelaus.

-module(menelaus_web_buckets).

-author('NorthScale <info@northscale.com>').

-include("menelaus_web.hrl").
-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([all_accessible_bucket_names/2,
         checking_bucket_access/4,
         handle_bucket_list/2,
         handle_bucket_info/5,
         build_bucket_node_infos/4,
         build_bucket_node_infos/5,
         handle_sasl_buckets_streaming/2,
         handle_bucket_info_streaming/3,
         handle_bucket_delete/3,
         handle_bucket_update/3,
         handle_bucket_create/2,
         handle_bucket_flush/3,
         handle_setup_default_bucket_post/1,
         parse_bucket_params/5,
         handle_compact_bucket/3,
         handle_compact_databases/3,
         handle_compact_view/4]).

-import(menelaus_util,
        [server_header/0,
         reply_json/2,
         concat_url_path/1,
         reply_json/3]).

all_accessible_buckets(_PoolId, Req) ->
    BucketsAll = ns_bucket:get_buckets(),
    menelaus_auth:filter_accessible_buckets(BucketsAll, Req).

all_accessible_bucket_names(PoolId, Req) ->
    [Name || {Name, _Config} <- all_accessible_buckets(PoolId, Req)].

checking_bucket_access(_PoolId, Id, Req, Body) ->
    E404 = make_ref(),
    try
        BucketTuple = case lists:keyfind(Id, 1, ns_bucket:get_buckets()) of
                          false -> exit(E404);
                          X -> X
                      end,
        case menelaus_auth:is_bucket_accessible(BucketTuple, Req) of
            true -> apply(Body, [fakepool, element(2, BucketTuple)]);
            _ -> menelaus_auth:require_auth(Req)
        end
    catch
        exit:E404 ->
            Req:respond({404, server_header(), "Requested resource not found.\r\n"})
    end.

handle_bucket_list(Id, Req) ->
    BucketNames = lists:sort(fun (A,B) -> A =< B end,
                             all_accessible_bucket_names(fakepool, Req)),
    LocalAddr = menelaus_util:local_addr(Req),
    BucketsInfo = [build_bucket_info(Id, Name, undefined, LocalAddr)
                   || Name <- BucketNames],
    reply_json(Req, BucketsInfo).

handle_bucket_info(PoolId, Id, Req, _Pool, Bucket) ->
    reply_json(Req, build_bucket_info(PoolId, Id, Bucket,
                                      menelaus_util:local_addr(Req))).

build_bucket_node_infos(BucketName, BucketConfig, InfoLevel, LocalAddr) ->
    build_bucket_node_infos(BucketName, BucketConfig, InfoLevel, LocalAddr, false).

build_bucket_node_infos(BucketName, BucketConfig, InfoLevel, LocalAddr, IncludeOtp) ->
    %% Only list nodes this bucket is mapped to
    F = menelaus_web:build_nodes_info_fun(IncludeOtp, InfoLevel, LocalAddr),
    misc:randomize(),
    [F(N, BucketName) || N <- misc:shuffle(proplists:get_value(servers, BucketConfig, []))].

build_bucket_info(PoolId, Id, Bucket, LocalAddr) ->
    build_bucket_info(PoolId, Id, Bucket, normal, LocalAddr).

build_bucket_info(PoolId, Id, undefined, InfoLevel, LocalAddr) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Id),
    build_bucket_info(PoolId, Id, BucketConfig, InfoLevel, LocalAddr);
build_bucket_info(PoolId, Id, BucketConfig, InfoLevel, LocalAddr) ->
    Nodes = build_bucket_node_infos(Id, BucketConfig, InfoLevel, LocalAddr),
    StatsUri = list_to_binary(concat_url_path(["pools", PoolId, "buckets", Id, "stats"])),
    StatsDirectoryUri = iolist_to_binary([StatsUri, <<"Directory">>]),
    NodeStatsListURI = iolist_to_binary(concat_url_path(["pools", PoolId, "buckets", Id, "nodes"])),
    BucketCaps = [{bucketCapabilitiesVer, ''}
                  | case ns_bucket:bucket_type(BucketConfig) of
                        membase -> [{bucketCapabilities, [touch, couchapi]}];
                        memcached -> [{bucketCapabilities, []}]
                    end],


    Suffix = case InfoLevel of
                 stable -> BucketCaps;
                 normal ->
                     [{replicaNumber, ns_bucket:num_replicas(BucketConfig)},
                      {quota, {struct, [{ram, ns_bucket:ram_quota(BucketConfig)},
                                        {rawRAM, ns_bucket:raw_ram_quota(BucketConfig)}]}},
                      {basicStats, {struct, menelaus_stats:basic_stats(Id)}}
                     | BucketCaps]
             end,
    BucketType = ns_bucket:bucket_type(BucketConfig),
    %% Only list nodes this bucket is mapped to
    %% Leave vBucketServerMap key out for memcached buckets; this is
    %% how Enyim decides to use ketama
    Suffix1 = case BucketType of
                  membase ->
                      [{vBucketServerMap, ns_bucket:json_map_from_config(
                                            LocalAddr, BucketConfig)} |
                       Suffix];
                  memcached ->
                      Suffix
              end,
    {struct, [{name, list_to_binary(Id)},
              {bucketType, BucketType},
              {authType, misc:expect_prop_value(auth_type, BucketConfig)},
              {saslPassword, list_to_binary(proplists:get_value(sasl_password, BucketConfig, ""))},
              {proxyPort, proplists:get_value(moxi_port, BucketConfig, 0)},
              {replicaIndex, proplists:get_value(replica_index, BucketConfig, true)},
              {uri, list_to_binary(concat_url_path(["pools", PoolId, "buckets", Id]))},
              {streamingUri, list_to_binary(concat_url_path(["pools", PoolId, "bucketsStreaming", Id]))},
              {controllers, [{flush, list_to_binary(concat_url_path(["pools", PoolId,
                                                                     "buckets", Id, "controller", "doFlush"]))},
                             {compactAll, list_to_binary(concat_url_path(["pools", PoolId,
                                                                          "buckets", Id, "controller", "compactBucket"]))},
                             {compactDB, list_to_binary(concat_url_path(["pools", PoolId,
                                                                         "buckets", Id, "controller", "compactDatabases"]))}]},
              {nodes, Nodes},
              {stats, {struct, [{uri, StatsUri},
                                {directoryURI, StatsDirectoryUri},
                                {nodeStatsListURI, NodeStatsListURI}]}},
              {nodeLocator, ns_bucket:node_locator(BucketConfig)},
              {autoCompactionSettings, case proplists:get_value(autocompaction, BucketConfig) of
                                           undefined -> false;
                                           false -> false;
                                           ACSettings -> menelaus_web:build_auto_compaction_settings(ACSettings)
                                       end},
              {fastWarmupSettings,
               case proplists:get_value(fast_warmup, BucketConfig) of
                   undefined ->
                       false;
                   false ->
                       false;
                   FWSettings ->
                       menelaus_web:build_fast_warmup_settings(FWSettings)
               end}
              | Suffix1]}.

handle_sasl_buckets_streaming(_PoolId, Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    F = fun (_) ->
                Config = ns_config:get(),
                SASLBuckets = lists:filter(
                                fun ({_, BucketInfo}) ->
                                        ns_bucket:auth_type(BucketInfo) =:= sasl
                                end, ns_bucket:get_buckets(Config)),
                List =
                    lists:map(
                      fun ({Name, BucketInfo}) ->
                              BucketNodes =
                                  [begin
                                       Hostname = list_to_binary(menelaus_web:build_node_hostname(Config, N, LocalAddr)),
                                       DirectPort = ns_config:search_node_prop(N, Config, memcached, port),
                                       ProxyPort = ns_config:search_node_prop(N, Config, moxi, port),
                                       {struct, [{hostname, Hostname},
                                                 {ports, {struct, [{direct, DirectPort},
                                                                   {proxy, ProxyPort}]}}]}
                                   end || N <- ns_bucket:bucket_nodes(BucketInfo)],
                              VBM = case ns_bucket:bucket_type(BucketInfo) of
                                        membase ->
                                            [{vBucketServerMap,
                                             ns_bucket:json_map_from_config(
                                               LocalAddr, BucketInfo)}];
                                        memcached ->
                                            []
                                    end,
                              {struct, [{name, list_to_binary(Name)},
                                        {nodeLocator,
                                         ns_bucket:node_locator(BucketInfo)},
                                        {saslPassword,
                                         list_to_binary(
                                           proplists:get_value(
                                             sasl_password, BucketInfo,
                                             ""))},
                                        {nodes, BucketNodes} | VBM]}
                      end, SASLBuckets),
                {just_write, {struct, [{buckets, List}]}}
        end,
    menelaus_web:handle_streaming(F, Req, undefined).

handle_bucket_info_streaming(PoolId, Id, Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    F = fun(_InfoLevel) ->
                case ns_bucket:get_bucket(Id) of
                    {ok, BucketConfig} ->
                        build_bucket_info(PoolId, Id, BucketConfig, stable, LocalAddr);
                    not_present ->
                        exit(normal)
                end
        end,
    menelaus_web:handle_streaming(F, Req, undefined).

handle_bucket_delete(_PoolId, BucketId, Req) ->
    case ns_orchestrator:delete_bucket(BucketId) of
        ok ->
            ?MENELAUS_WEB_LOG(?BUCKET_DELETED, "Deleted bucket \"~s\"~n", [BucketId]),
            Req:respond({200, server_header(), []});
        rebalance_running ->
            reply_json(Req, {struct, [{'_', <<"Cannot delete buckets during rebalance">>}]}, 503);
        {exit, {not_found, _}, _} ->
            Req:respond({404, server_header(), "The bucket to be deleted was not found.\r\n"})
    end.

respond_bucket_created(Req, PoolId, BucketId) ->
    Req:respond({202, [{"Location", concat_url_path(["pools", PoolId, "buckets", BucketId])}
                       | server_header()],
                 ""}).

%% returns pprop list with only props useful for ns_bucket
extract_bucket_props(BucketId, Props) ->
    ImportantProps = [X || X <- [lists:keyfind(Y, 1, Props) || Y <- [num_replicas, replica_index, ram_quota, auth_type,
                                                                     sasl_password, moxi_port,
                                                                     autocompaction, fast_warmup]],
                           X =/= false],
    case BucketId of
        "default" -> lists:keyreplace(auth_type, 1,
                                      [{sasl_password, ""} | lists:keydelete(sasl_password, 1, ImportantProps)],
                                      {auth_type, sasl});
        _ -> ImportantProps
    end.

handle_bucket_update(_PoolId, BucketId, Req) ->
    Params = Req:parse_post(),
    handle_bucket_update_inner(BucketId, Req, Params, 32).

handle_bucket_update_inner(_BucketId, _Req, _Params, 0) ->
    exit(bucket_update_loop);
handle_bucket_update_inner(BucketId, Req, Params, Limit) ->
    ValidateOnly = (proplists:get_value("just_validate", Req:parse_qs()) =:= "1"),
    case {ValidateOnly,
          parse_bucket_params(false,
                              BucketId,
                              Params,
                              ns_bucket:get_buckets(),
                              extended_cluster_storage_info())} of
        {_, {errors, Errors, JSONSummaries}} ->
            RV = {struct, [{errors, {struct, Errors}},
                           {summaries, {struct, JSONSummaries}}]},
            reply_json(Req, RV, 400);
        {false, {ok, ParsedProps, _}} ->
            BucketType = proplists:get_value(bucketType, ParsedProps),
            UpdatedProps = extract_bucket_props(BucketId, ParsedProps),
            case ns_bucket:update_bucket_props(BucketType, BucketId, UpdatedProps) of
                ok ->
                    ale:info(?USER_LOGGER, "Updated bucket ~s (of type ~s) properties:~n~p",
                             [BucketId, BucketType, lists:keydelete(sasl_password, 1, UpdatedProps)]),
                    Req:respond({200, server_header(), []});
                {exit, {not_found, _}, _} ->
                    %% if this happens then our validation raced, so repeat everything
                    handle_bucket_update_inner(BucketId, Req, Params, Limit-1)
            end;
        {true, {ok, ParsedProps, JSONSummaries}} ->
            FinalErrors = perform_warnings_validation(ParsedProps, []),
            reply_json(Req, {struct, [{errors, {struct, FinalErrors}},
                                      {summaries, {struct, JSONSummaries}}]},
                       case FinalErrors of
                           [] -> 202;
                           _ -> 400
                       end)
    end.

do_bucket_create(Name, ParsedProps) ->
    BucketType = proplists:get_value(bucketType, ParsedProps),
    BucketProps = extract_bucket_props(Name, ParsedProps),
    menelaus_web:maybe_cleanup_old_buckets(),
    case ns_orchestrator:create_bucket(BucketType, Name, BucketProps) of
        ok ->
            ?MENELAUS_WEB_LOG(?BUCKET_CREATED, "Created bucket \"~s\" of type: ~s~n~p",
                              [Name, BucketType, lists:keydelete(sasl_password, 1, BucketProps)]),
            ok;
        {error, {already_exists, _}} ->
            {errors, [{name, <<"Bucket with given name already exists">>}]};
        {error, {still_exists, _}} ->
            {errors_500, [{name, <<"Bucket with given name still exists">>}]};
        {error, {port_conflict, _}} ->
            {errors, [{proxyPort, <<"A bucket is already using this port">>}]};
        {error, {invalid_name, _}} ->
            {errors, [{name, <<"Name is invalid.">>}]};
        rebalance_running ->
            {errors_500, [{'_', <<"Cannot create buckets during rebalance">>}]}
    end.

handle_bucket_create(PoolId, Req) ->
    Params = Req:parse_post(),
    Name = proplists:get_value("name", Params),
    ValidateOnly = (proplists:get_value("just_validate", Req:parse_qs()) =:= "1"),
    case {ValidateOnly,
          parse_bucket_params(true,
                              Name,
                              Params,
                              ns_bucket:get_buckets(),
                              extended_cluster_storage_info())} of
        {_, {errors, Errors, JSONSummaries}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}},
                                      {summaries, {struct, JSONSummaries}}]}, 400);
        {false, {ok, ParsedProps, _}} ->
            case do_bucket_create(Name, ParsedProps) of
                ok ->
                    respond_bucket_created(Req, PoolId, Name);
                {errors, Errors} ->
                    reply_json(Req, {struct, Errors}, 400);
                {errors_500, Errors} ->
                    reply_json(Req, {struct, Errors}, 503)
            end;
        {true, {ok, ParsedProps, JSONSummaries}} ->
            FinalErrors = perform_warnings_validation(ParsedProps, []),
            reply_json(Req, {struct, [{errors, {struct, FinalErrors}},
                                      {summaries, {struct, JSONSummaries}}]},
                       case FinalErrors of
                           [] -> 200;
                           _ -> 400
                       end)
    end.

perform_warnings_validation(ParsedProps, Errors) ->
    Errors ++ case proplists:get_value(num_replicas, ParsedProps) of
        undefined ->
            [];
        X ->
            ActiveCount = length(ns_cluster_membership:active_nodes()),
            if
                ActiveCount =< X ->
                    Msg = <<"Warning, you do not have enough servers to support this number of replicas.">>,
                    [{replicaNumber, Msg}];
                true ->
                    []
            end
    end.

handle_bucket_flush(PoolId, Id, Req) ->
    ?MENELAUS_WEB_LOG(0005, "Flushing pool ~p bucket ~p from node ~p",
                      [PoolId, Id, erlang:node()]),
    Nodes = ns_node_disco:nodes_wanted(),
    {Results, []} = rpc:multicall(Nodes, ns_memcached, flush, [Id],
                                  ?MULTICALL_DEFAULT_TIMEOUT),
    case lists:all(fun(A) -> A =:= ok end, Results) of
        true ->
            Req:respond({200, server_header(), []});
        false ->
            Req:respond({503, server_header(), "Unexpected error flushing buckets"})
    end.

handle_setup_default_bucket_post(Req) ->
    Params = Req:parse_post(),
    ValidateOnly = (proplists:get_value("just_validate", Req:parse_qs()) =:= "1"),
    case {ValidateOnly,
          parse_bucket_params_for_setup_default_bucket(Params,
                                                       extended_cluster_storage_info())} of
        {_, {errors, Errors, JSONSummaries}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}},
                                      {summaries, {struct, JSONSummaries}}]}, 400);
        {false, {ok, ParsedProps, _}} ->
            ns_orchestrator:delete_bucket("default"),
            case do_bucket_create("default", ParsedProps) of
                ok ->
                    respond_bucket_created(Req, "default", "default");
                {errors, Errors} ->
                    reply_json(Req, {struct, Errors}, 400);
                {errors_500, Errors} ->
                    reply_json(Req, {struct, Errors}, 503)
            end;
        {true, {ok, _, JSONSummaries}} ->
            reply_json(Req, {struct, [{errors, {struct, []}},
                                      {summaries, {struct, JSONSummaries}}]}, 200)
    end.

-record(ram_summary, {
          total,                                % total cluster quota
          other_buckets,
          per_node,                             % per node quota of this bucket
          nodes_count,                          % node count of this bucket
          this_alloc,
          this_used,                            % part of this bucket which is used already
          free}).                               % total - other_buckets - this_alloc.
                                                % So it's: Amount of cluster quota available for allocation

-record(hdd_summary, {
          total,                                % total cluster disk space
          other_data,                           % disk space used by something other than our data
          other_buckets,                        % space used for other buckets
          this_used,                            % space already used by this bucket
          free}).                               % total - other_data - other_buckets - this_alloc
                                                % So it's kind of: Amount of cluster disk space available of allocation,
                                                % but with a number of 'but's.

parse_bucket_params_for_setup_default_bucket(Params, ClusterStorageTotals) ->
    UsageGetter = fun (_, _) ->
                          0
                  end,
    NodeCount = proplists:get_value(nodesCount, ClusterStorageTotals),
    RamTotals = proplists:get_value(ram, ClusterStorageTotals),
    OldQuotaUsed = proplists:get_value(quotaUsed, RamTotals),
    NewQuotaUsed = OldQuotaUsed - (default_node_ram_quota() * NodeCount),
    NewRamTotals = lists:keyreplace(quotaUsed, 1, RamTotals,
                                    {quotaUsed, NewQuotaUsed}),
    NewClusterTotals = lists:keyreplace(ram, 1, ClusterStorageTotals,
                                        {ram, NewRamTotals}),

    RV = parse_bucket_params_without_warnings(true, "default",
                                              [{"authType", "sasl"}, {"saslPassword", ""} | Params],
                                              [],
                                              NewClusterTotals,
                                              UsageGetter),
    case RV of
        {ok, _, _} = X -> X;
        {errors, Errors, Summaries, _} -> {errors, Errors, Summaries}
    end.

default_node_ram_quota() ->
    Buckets = ns_bucket:get_buckets(ns_config:get()),
    case lists:keyfind("default", 1, Buckets) of
        {"default", Props} ->
            proplists:get_value(ram_quota, Props);
        _ ->
            0
    end.

parse_bucket_params(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals) ->
    RV = parse_bucket_params_without_warnings(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals),
    case RV of
        {ok, _, _} = X -> X;
        {errors, Errors, Summaries, OKs} ->
            {errors, perform_warnings_validation(OKs, Errors), Summaries}
    end.

parse_bucket_params_without_warnings(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals) ->
    UsageGetter = fun (ram, Name) ->
                          menelaus_stats:bucket_ram_usage(Name);
                      (hdd, all) ->
                          {hdd, HDDStats} = lists:keyfind(hdd, 1, ClusterStorageTotals),
                          {usedByData, V} = lists:keyfind(usedByData, 1, HDDStats),
                          V;
                      (hdd, Name) ->
                          menelaus_stats:bucket_disk_usage(Name)
                  end,
    parse_bucket_params_without_warnings(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals, UsageGetter).

parse_bucket_params_without_warnings(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals, UsageGetter) ->
    {OKs, Errors} = basic_bucket_params_screening(IsNew, BucketName,
                                                  Params, AllBuckets),
    CurrentBucket = proplists:get_value(currentBucket, OKs),
    HasRAMQuota = lists:keyfind(ram_quota, 1, OKs) =/= false,
    RAMSummary = if
                     HasRAMQuota ->
                         interpret_ram_quota(CurrentBucket, OKs, ClusterStorageTotals, UsageGetter);
                     true ->
                         interpret_ram_quota(CurrentBucket,
                                             [{ram_quota, 0} | OKs],
                                             ClusterStorageTotals,
                                             UsageGetter)
                 end,
    HDDSummary = interpret_hdd_quota(CurrentBucket, OKs, ClusterStorageTotals, UsageGetter),
    JSONSummaries = [X || X <- [{ramSummary, {struct, ram_summary_to_proplist(RAMSummary)}},
                                {hddSummary, {struct, hdd_summary_to_proplist(HDDSummary)}}],
                          X =/= undefined],
    Errors2 = case {CurrentBucket, IsNew} of
                  {undefined, _} -> Errors;
                  {_, true} -> Errors;
                  {_, false} ->
                      case {proplists:get_value(bucketType, OKs),
                            ns_bucket:bucket_type(CurrentBucket)} of
                          {undefined, _} -> Errors;
                          {NewType, NewType} -> Errors;
                          {_NewType, _OldType} ->
                              [{bucketType, <<"Cannot change bucket type.">>}
                               | Errors]
                      end
              end,
    RAMErrors =
        if
            RAMSummary#ram_summary.free < 0 ->
                [{ramQuotaMB, <<"RAM quota specified is too large to be provisioned into this cluster.">>}];
            RAMSummary#ram_summary.this_alloc < RAMSummary#ram_summary.this_used ->
                [{ramQuotaMB, <<"RAM quota cannot be set below current usage.">>}];
            true ->
                []
        end,
    TotalErrors = RAMErrors ++ Errors2,
    if
        TotalErrors =:= [] ->
            {ok, OKs, JSONSummaries};
        true ->
            {errors, TotalErrors, JSONSummaries, OKs}
    end.

basic_bucket_params_screening(IsNew, BucketName, Params, AllBuckets) ->
    BucketConfig = case lists:keyfind(BucketName, 1, AllBuckets) of
                       false -> false;
                       {_, V} -> V
                   end,
    AuthType = case proplists:get_value("authType", Params) of
                   "none" -> none;
                   "sasl" -> sasl;
                   undefined when BucketConfig =/= false ->
                       ns_bucket:auth_type(BucketConfig);
                   _ -> {crap, <<"invalid authType">>} % this is not for end users
               end,
    case {IsNew, BucketConfig, AuthType} of
        {false, false, _} ->
            {[], [{name, <<"Bucket with given name doesn't exist">>}]};
        {_, _, {crap, Crap}} ->
            {[], [{authType, Crap}]};
        _ -> basic_bucket_params_screening_tail(IsNew, BucketName, Params,
                                                BucketConfig, AuthType)
    end.

basic_bucket_params_screening_tail(IsNew, BucketName, Params, BucketConfig, AuthType) ->
    Candidates0 = [{ok, name, BucketName},
                   {ok, auth_type, AuthType},
                   case IsNew of
                       true ->
                           case BucketConfig of
                               false ->
                                   %% we'll give error on missing bucket name later
                                   case BucketName =:= undefined orelse ns_bucket:is_valid_bucket_name(BucketName) of
                                       false ->
                                           {error, name, <<"Bucket name can only contain characters in range A-Z, a-z, 0-9 as well as underscore, period, dash & percent. Consult the documentation.">>};
                                       _ ->
                                           undefined
                                   end;
                               _ ->
                                   {error, name, <<"Bucket with given name already exists">>}
                           end;
                       _ ->
                           true = (BucketConfig =/= false),
                           {ok, currentBucket, BucketConfig}
                   end,
                   case BucketName of
                       [] ->
                           {error, name, <<"Bucket name cannot be empty">>};
                       undefined ->
                           {error, name, <<"Bucket name needs to be specified">>};
                       _ -> undefined
                   end,
                   case AuthType of
                       none ->
                           ProxyPort = proplists:get_value("proxyPort", Params),
                           case ProxyPort of
                               undefined when BucketConfig =/= false ->
                                   case ns_bucket:auth_type(BucketConfig) of
                                       AuthType -> nothing;
                                       _ ->
                                           {error, proxyPort,
                                            <<"port is missing">>}
                                   end;
                               _ ->
                                   case menelaus_util:parse_validate_number(ProxyPort,
                                                                            1025, 65535) of
                                       {ok, PP} ->
                                           case ns_bucket:is_port_free(BucketName, PP) of
                                               true ->
                                                   {ok, moxi_port, PP};
                                               false ->
                                                   {error, proxyPort,
                                                    <<"port is already in use">>}
                                           end;
                                       _ -> {error, proxyPort,
                                             <<"port is invalid">>}
                                   end
                           end;
                       sasl ->
                           SaslPassword = proplists:get_value("saslPassword", Params, ""),
                           case SaslPassword of
                               undefined when BucketConfig =/= false ->
                                   case ns_bucket:auth_type(BucketConfig) of
                                       AuthType -> nothing;
                                       _ -> {error, saslPassword, <<"sasl password is missing">>}
                                   end;
                               _ ->
                                   {ok, sasl_password, SaslPassword}
                           end
                   end,
                   parse_validate_ram_quota(proplists:get_value("ramQuotaMB", Params),
                                            BucketConfig)],
    BucketType = if
                     (not IsNew) andalso BucketConfig =/= false ->
                         ns_bucket:bucket_type(BucketConfig);
                     true ->
                         case proplists:get_value("bucketType", Params) of
                             "memcached" -> memcached;
                             "membase" -> membase;
                             "couchbase" -> membase;
                             undefined -> membase;
                             _ -> invalid
                         end
                 end,
    QuotaSizeError = case lists:keyfind(ram_quota, 2, Candidates0) of
                         {ok, ram_quota, RAMQuotaMB} ->
                             {MinQuota, Msg}
                                 = case BucketType of
                                       membase ->
                                           Q = misc:get_env_default(membase_min_ram_quota, 100),
                                           Qv = list_to_binary(integer_to_list(Q)),
                                           {Q, <<"RAM quota cannot be less than ", Qv/binary, " MB">>};
                                       memcached ->
                                           Q = misc:get_env_default(memcached_min_ram_quota, 64),
                                           Qv = list_to_binary(integer_to_list(Q)),
                                           {Q, <<"RAM quota cannot be less than ", Qv/binary, " MB">>};
                                       _ -> {0, <<"">>}
                                   end,
                             if
                                 RAMQuotaMB < MinQuota * 1048576 ->
                                     {error, ramQuotaMB, Msg};
                                 IsNew =/= true andalso BucketConfig =/= false andalso BucketType =:= memcached ->
                                     case ns_bucket:raw_ram_quota(BucketConfig) of
                                         RAMQuotaMB -> ok;
                                         _ ->
                                             {error, ramQuotaMB, <<"cannot change quota of memcached buckets">>}
                                     end;
                                 true ->
                                     ok
                             end;
                         _ -> ok
                     end,
    Candidates1 = [QuotaSizeError | Candidates0],
    Candidates2 = case menelaus_web:parse_validate_bucket_auto_compaction_settings(Params) of
                      nothing -> Candidates1;
                      false -> [{ok, autocompaction, false} | Candidates1];
                      {errors, Errors} ->
                          [{error, F, M} || {F, M} <- Errors] ++ Candidates1;
                      {ok, ACSettings} ->
                          [{ok, autocompaction, ACSettings} | Candidates1]
                  end,
    Candidates3 =
        case menelaus_web:parse_validate_bucket_fast_warmup_settings(Params) of
            nothing ->
                Candidates2;
            false ->
                [{ok, fast_warmup, false} | Candidates2];
            {errors, FWErrors} ->
                [{error, F, M} || {F, M} <- FWErrors] ++ Candidates2;
            {ok, FWSettings} ->
                [{ok, fast_warmup, FWSettings} | Candidates2]
        end,
    Candidates = case BucketType of
                     memcached ->
                         [{ok, bucketType, memcached}
                          | Candidates3];
                     membase ->
                         [{ok, bucketType, membase},
                          case IsNew of
                              true -> parse_validate_replicas_number(proplists:get_value("replicaNumber", Params));
                              _ -> undefined
                          end,
                          case IsNew of
                              true ->
                                  parse_validate_replica_index(proplists:get_value("replicaIndex", Params, "1"));
                              false ->
                                  undefined
                          end
                          | Candidates3];
                     _ ->
                         [{error, bucketType, <<"invalid bucket type">>}
                          | Candidates3]
                 end,
    {[{K,V} || {ok, K, V} <- Candidates],
     [{K,V} || {error, K, V} <- Candidates]}.

-define(PRAM(K, KO), {KO, V#ram_summary.K}).
ram_summary_to_proplist(V) ->
    [?PRAM(total, total),
     ?PRAM(other_buckets, otherBuckets),
     ?PRAM(nodes_count, nodesCount),
     ?PRAM(per_node, perNodeMegs),
     ?PRAM(this_alloc, thisAlloc),
     ?PRAM(this_used, thisUsed),
     ?PRAM(free, free)].

interpret_ram_quota(CurrentBucket, ParsedProps, ClusterStorageTotals, UsageGetter) ->
    RAMQuota = proplists:get_value(ram_quota, ParsedProps),
    NodesCount = proplists:get_value(nodesCount, ClusterStorageTotals),
    ParsedQuota = RAMQuota * NodesCount,
    PerNode = RAMQuota div 1048576,
    ClusterTotals = proplists:get_value(ram, ClusterStorageTotals),
    OtherBuckets = proplists:get_value(quotaUsed, ClusterTotals)
        - case CurrentBucket of
              [_|_] ->
                  ns_bucket:ram_quota(CurrentBucket);
              _ ->
                  0
          end,
    ThisUsed = case CurrentBucket of
                   [_|_] ->
                       UsageGetter(ram, proplists:get_value(name, ParsedProps));
                   _ -> 0
               end,
    Total = proplists:get_value(quotaTotal, ClusterTotals),
    #ram_summary{total = Total,
                 other_buckets = OtherBuckets,
                 nodes_count = NodesCount,
                 per_node = PerNode,
                 this_alloc = ParsedQuota,
                 this_used = ThisUsed,
                 free = Total - OtherBuckets - ParsedQuota}.

-define(PHDD(K, KO), {KO, V#hdd_summary.K}).
hdd_summary_to_proplist(V) ->
    [?PHDD(total, total),
     ?PHDD(other_data, otherData),
     ?PHDD(other_buckets, otherBuckets),
     ?PHDD(this_used, thisUsed),
     ?PHDD(free, free)].

interpret_hdd_quota(CurrentBucket, ParsedProps, ClusterStorageTotals, UsageGetter) ->
    ClusterTotals = proplists:get_value(hdd, ClusterStorageTotals),
    UsedByUs = UsageGetter(hdd, all),
    ThisUsed = case CurrentBucket of
                   [_|_] ->
                       UsageGetter(hdd, proplists:get_value(name, ParsedProps));
                   _ -> 0
               end,
    OtherData = proplists:get_value(used, ClusterTotals) - UsedByUs,
    OtherBuckets = UsedByUs - ThisUsed,
    Total = proplists:get_value(total, ClusterTotals),
    #hdd_summary{total = Total,
                 other_data = OtherData,
                 other_buckets = OtherBuckets,
                 this_used = ThisUsed,
                 free = Total - OtherData - OtherBuckets}.

parse_validate_replicas_number(NumReplicas) ->
    case menelaus_util:parse_validate_number(NumReplicas, 0, 3) of
        invalid ->
            {error, replicaNumber, <<"The replica number must be specified and must be a non-negative integer.">>};
        too_small ->
            {error, replicaNumber, <<"The replica number cannot be negative.">>};
        too_large ->
            {error, replicaNumber, <<"Replica number larger than 3 is not supported.">>};
        {ok, X} -> {ok, num_replicas, X}
    end.

parse_validate_replica_index("0") -> {ok, replica_index, false};
parse_validate_replica_index("1") -> {ok, replica_index, true};
parse_validate_replica_index(_ReplicaValue) -> {error, replicaIndex, <<"replicaIndex can only be 1 or 0">>}.

parse_validate_ram_quota(undefined, BucketConfig) when BucketConfig =/= false ->
    ns_bucket:raw_ram_quota(BucketConfig);
parse_validate_ram_quota(Value, _BucketConfig) ->
    case menelaus_util:parse_validate_number(Value, 0, undefined) of
        invalid ->
            {error, ramQuotaMB, <<"The RAM Quota must be specified and must be a positive integer.">>};
        too_small ->
            {error, ramQuotaMB, <<"The RAM Quota cannot be negative.">>};
        {ok, X} -> {ok, ram_quota, X * 1048576}
    end.

extended_cluster_storage_info() ->
    [{nodesCount, length(ns_cluster_membership:active_nodes())}
     | ns_storage_conf:cluster_storage_info()].


handle_compact_bucket(_PoolId, Bucket, Req) ->
    ok = compaction_daemon:force_compact_bucket(Bucket),
    Req:respond({200, server_header(), []}).

handle_compact_databases(_PoolId, Bucket, Req) ->
    ok = compaction_daemon:force_compact_db_files(Bucket),
    Req:respond({200, server_header(), []}).

handle_compact_view(_PoolId, Bucket, DDocId, Req) ->
    ok = compaction_daemon:force_compact_view(Bucket, DDocId),
    Req:respond({200, server_header(), []}).

-ifdef(EUNIT).
basic_bucket_params_screening_test() ->
    AllBuckets = [{"mcd",
                   [{type, memcached},
                    {num_vbuckets, 16},
                    {num_replicas, 1},
                    {ram_quota, 76 * 1048576},
                    {auth_type, none},
                    {moxi_port, 33333}]},
                  {"default",
                   [{type, membase},
                    {num_vbuckets, 16},
                    {num_replicas, 1},
                    {ram_quota, 512 * 1048576},
                    {auth_type, sasl},
                    {sasl_password, ""}]},
                  {"third",
                   [{type, membase},
                    {num_vbuckets, 16},
                    {num_replicas, 1},
                    {ram_quota, 768 * 1048576},
                    {auth_type, sasl},
                    {sasl_password, "asdasd"}]}],
    %% it is possible to create bucket with ok params
    {_OK1, E1} = basic_bucket_params_screening(true, "mcd",
                                               [{"bucketType", "membase"},
                                                {"authType", "sasl"}, {"saslPassword", ""},
                                                {"ramQuotaMB", "400"}, {"replicaNumber", "2"}],
                                               tl(AllBuckets)),
    [] = E1,

    %% it is not possible to create bucket with duplicate name
    {_OK2, E2} = basic_bucket_params_screening(true, "mcd",
                                              [{"bucketType", "membase"},
                                               {"authType", "sasl"}, {"saslPassword", ""},
                                               {"ramQuotaMB", "400"}, {"replicaNumber", "2"}],
                                              AllBuckets),
    true = lists:member(name, proplists:get_keys(E2)), % mcd is already present

    %% it is not possible to update missing bucket. And specific format of errors
    {OK3, E3} = basic_bucket_params_screening(false, "missing",
                                              [{"bucketType", "membase"},
                                               {"authType", "sasl"}, {"saslPassword", ""},
                                               {"ramQuotaMB", "400"}, {"replicaNumber", "2"}],
                                              AllBuckets),
    [] = OK3,
    [name] = proplists:get_keys(E3),

    %% it is not possible to update missing bucket. And specific format of errors
    {OK4, E4} = basic_bucket_params_screening(false, "missing",
                                              [],
                                              AllBuckets),
    [] = OK4,
    [name] = proplists:get_keys(E4),

    %% it is not possible to update missing bucket. And specific format of errors
    {OK5, E5} = basic_bucket_params_screening(false, "missing",
                                              [{"authType", "some"}],
                                              AllBuckets),
    [] = OK5,
    [name] = proplists:get_keys(E5),

    %% it is possible to update only some fields
    {OK6, E6} = basic_bucket_params_screening(false, "third",
                                              [{"bucketType", "membase"},
                                               {"saslPassword", "password"}],
                                              AllBuckets),
    {sasl_password, "password"} = lists:keyfind(sasl_password, 1, OK6),
    {auth_type, sasl} = lists:keyfind(auth_type, 1, OK6),
    [] = E6,

    %% its not possible to update memcached bucket ram quota
    {_OK7, E7} = basic_bucket_params_screening(false, "mcd",
                                               [{"bucketType", "membase"},
                                                {"authType", "sasl"}, {"saslPassword", ""},
                                                {"ramQuotaMB", "1024"}, {"replicaNumber", "2"}],
                                               AllBuckets),
    ?assertEqual(true, lists:member(ramQuotaMB, proplists:get_keys(E7))),

    {_OK8, E8} = basic_bucket_params_screening(true, undefined,
                                               [{"bucketType", "membase"},
                                                {"authType", "sasl"}, {"saslPassword", ""},
                                                {"ramQuotaMB", "400"}, {"replicaNumber", "2"}],
                                               AllBuckets),
    ?assertEqual([{name, <<"Bucket name needs to be specified">>}], E8),

    {_OK9, E9} = basic_bucket_params_screening(false, undefined,
                                               [{"bucketType", "membase"},
                                                {"authType", "sasl"}, {"saslPassword", ""},
                                                {"ramQuotaMB", "400"}, {"replicaNumber", "2"}],
                                               AllBuckets),
    ?assertEqual([{name, <<"Bucket with given name doesn't exist">>}], E9),

    ok.

-endif.
