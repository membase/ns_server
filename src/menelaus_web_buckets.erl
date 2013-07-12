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
-include("couch_db.hrl").
-include("ns_stats.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([all_accessible_bucket_names/2,
         checking_bucket_access/4,
         checking_bucket_uuid/4,
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
         parse_bucket_params/5,
         handle_compact_bucket/3,
         handle_purge_compact_bucket/3,
         handle_cancel_bucket_compaction/3,
         handle_compact_databases/3,
         handle_cancel_databases_compaction/3,
         handle_compact_view/4,
         handle_cancel_view_compaction/4,
         handle_ddocs_list/5,
         handle_set_ddoc_update_min_changes/4,
         handle_local_random_key/3]).

-import(menelaus_util,
        [server_header/0,
         reply_json/2,
         concat_url_path/1,
         bin_concat_path/1,
         bin_concat_path/2,
         reply_json/3]).

all_accessible_buckets(_PoolId, Req) ->
    BucketsAll = ns_bucket:get_buckets(),
    menelaus_auth:filter_accessible_buckets(BucketsAll, Req).

all_accessible_bucket_names(PoolId, Req) ->
    [Name || {Name, _Config} <- all_accessible_buckets(PoolId, Req)].

checking_bucket_access(_PoolId, Id, Req, Body) ->
    E404 = make_ref(),
    try
        BucketTuple =
            case ns_bucket:get_bucket(Id) of
                not_present ->
                    exit(E404);
                {ok, V} ->
                    {Id, V}
            end,

        case menelaus_auth:is_bucket_accessible(BucketTuple, Req) of
            true -> apply(Body, [fakepool, element(2, BucketTuple)]);
            _ -> menelaus_auth:require_auth(Req)
        end
    catch
        exit:E404 ->
            Req:respond({404, server_header(), "Requested resource not found.\r\n"})
    end.

checking_bucket_uuid(_PoolId, Req, BucketConfig, Body) ->
    ReqUUID0 = proplists:get_value("bucket_uuid", Req:parse_qs()),
    case ReqUUID0 =/= undefined of
        true ->
            ReqUUID = list_to_binary(ReqUUID0),
            BucketUUID = proplists:get_value(uuid, BucketConfig),

            case BucketUUID =:= undefined orelse BucketUUID =:= ReqUUID of
                true ->
                    Body();
                false ->
                    Req:respond({404, server_header(),
                                 "Bucket uuid does not match the requested.\r\n"})
            end;
        false ->
            Body()
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
    Nodes = proplists:get_value(servers, BucketConfig, []),
    %% NOTE: there's potential inconsistency here between BucketConfig
    %% and (potentially more up-to-date) vbuckets dict. Given that
    %% nodes list is mostly informational I find it ok.
    Dict = case vbucket_map_mirror:node_vbuckets_dict_or_not_present(BucketName) of
               not_present -> dict:new();
               no_map -> dict:new();
               DV -> DV
           end,
    add_couch_api_base_loop(Nodes, BucketName, LocalAddr, F, Dict, [], []).


add_couch_api_base_loop([], _BucketName, _LocalAddr, _F, _Dict, CAPINodes, NonCAPINodes) ->
    misc:shuffle(CAPINodes) ++ NonCAPINodes;
add_couch_api_base_loop([Node | RestNodes], BucketName, LocalAddr, F, Dict, CAPINodes, NonCAPINodes) ->
    {struct, KV} = F(Node, BucketName),
    case dict:find(Node, Dict) of
        {ok, V} when V =/= [] ->
            S = {struct, maybe_add_couch_api_base(BucketName, KV, Node, LocalAddr)},
            add_couch_api_base_loop(RestNodes, BucketName, LocalAddr, F, Dict, [S | CAPINodes], NonCAPINodes);
        _ ->
            S = {struct, KV},
            add_couch_api_base_loop(RestNodes, BucketName, LocalAddr, F, Dict, CAPINodes, [S | NonCAPINodes])
    end.

maybe_add_couch_api_base(BucketName, KV, Node, LocalAddr) ->
    case cluster_compat_mode:is_cluster_20() of
        true ->
            case capi_utils:capi_bucket_url_bin(Node, BucketName, LocalAddr) of
                undefined -> KV;
                CapiBucketUrl ->
                    [{couchApiBase, CapiBucketUrl} | KV]
            end;
        false ->
            KV
    end.

build_bucket_info(PoolId, Id, Bucket, LocalAddr) ->
    build_bucket_info(PoolId, Id, Bucket, normal, LocalAddr).

build_bucket_info(PoolId, Id, undefined, InfoLevel, LocalAddr) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Id),
    build_bucket_info(PoolId, Id, BucketConfig, InfoLevel, LocalAddr);
build_bucket_info(PoolId, Id, BucketConfig, InfoLevel, LocalAddr) ->
    Nodes = build_bucket_node_infos(Id, BucketConfig, InfoLevel, LocalAddr),
    StatsUri = bin_concat_path(["pools", PoolId, "buckets", Id, "stats"]),
    StatsDirectoryUri = iolist_to_binary([StatsUri, <<"Directory">>]),
    NodeStatsListURI = bin_concat_path(["pools", PoolId, "buckets", Id, "nodes"]),
    DDocsURI = bin_concat_path(["pools", PoolId, "buckets", Id, "ddocs"]),
    BucketCaps = build_bucket_capabilities(BucketConfig),

    MaybeBucketUUID = proplists:get_value(uuid, BucketConfig),
    QSProps = case MaybeBucketUUID of
                  undefined ->
                      [];
                  _ ->
                      [{"bucket_uuid", MaybeBucketUUID}]
              end,

    BuildUUIDURI = fun (Segments) ->
                           bin_concat_path(Segments, QSProps)
                   end,

    Suffix = case InfoLevel of
                 stable -> BucketCaps;
                 normal ->
                     [{replicaNumber, ns_bucket:num_replicas(BucketConfig)},
                      {threadsNumber, proplists:get_value(num_threads, BucketConfig, 3)},
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

    Suffix2 = case MaybeBucketUUID of
                  undefined ->
                      Suffix1;
                  _ ->
                      [{uuid, MaybeBucketUUID} | Suffix1]
              end,

    FlushEnabled = proplists:get_value(flush_enabled, BucketConfig, false),
    MaybeFlushController =
        case FlushEnabled of
            true ->
                [{flush, bin_concat_path(["pools", PoolId,
                                          "buckets", Id, "controller", "doFlush"])}];
            false ->
                []
        end,

    {struct, [{name, list_to_binary(Id)},
              {bucketType, BucketType},
              {authType, misc:expect_prop_value(auth_type, BucketConfig)},
              {saslPassword, list_to_binary(proplists:get_value(sasl_password, BucketConfig, ""))},
              {proxyPort, proplists:get_value(moxi_port, BucketConfig, 0)},
              {replicaIndex, proplists:get_value(replica_index, BucketConfig, true)},
              {uri, BuildUUIDURI(["pools", PoolId, "buckets", Id])},
              {streamingUri, BuildUUIDURI(["pools", PoolId, "bucketsStreaming", Id])},
              {localRandomKeyUri, bin_concat_path(["pools", PoolId,
                                                   "buckets", Id, "localRandomKey"])},
              {controllers,
               MaybeFlushController ++
                   [{compactAll, bin_concat_path(["pools", PoolId,
                                                  "buckets", Id, "controller", "compactBucket"])},
                    {compactDB, bin_concat_path(["pools", PoolId,
                                                 "buckets", Id, "controller", "compactDatabases"])},
                    {purgeDeletes, bin_concat_path(["pools", PoolId,
                                                    "buckets", Id, "controller", "unsafePurgeBucket"])},
                    {startRecovery, bin_concat_path(["pools", PoolId,
                                                     "buckets", Id, "controller", "startRecovery"])}]},
              {nodes, Nodes},
              {stats, {struct, [{uri, StatsUri},
                                {directoryURI, StatsDirectoryUri},
                                {nodeStatsListURI, NodeStatsListURI}]}},
              {ddocs, {struct, [{uri, DDocsURI}]}},
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
              | Suffix2]}.

build_bucket_capabilities(BucketConfig) ->
    Caps =
        case ns_bucket:bucket_type(BucketConfig) of
            membase ->
                case cluster_compat_mode:is_cluster_20() of
                    true ->
                        [touch, couchapi];
                    false ->
                        []
                end;
            memcached ->
                []
        end,

    [{bucketCapabilitiesVer, ''},
     {bucketCapabilities, Caps}].

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
            reply_json(Req, {struct, [{'_', <<"Cannot delete buckets during rebalance.\r\n">>}]}, 503);
        in_recovery ->
            reply_json(Req, {struct, [{'_', <<"Cannot delete buckets when cluster is in recovery mode.\r\n">>}]}, 503);
        {shutdown_failed, _} ->
            reply_json(Req, {struct, [{'_', <<"Bucket deletion not yet complete, but will continue.\r\n">>}]}, 500);
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
                                                                     autocompaction, fast_warmup,
                                                                     flush_enabled, num_threads]],
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
            {errors_500, [{'_', <<"Bucket with given name still exists">>}]};
        {error, {port_conflict, _}} ->
            {errors, [{proxyPort, <<"A bucket is already using this port">>}]};
        {error, {invalid_name, _}} ->
            {errors, [{name, <<"Name is invalid.">>}]};
        rebalance_running ->
            {errors_500, [{'_', <<"Cannot create buckets during rebalance">>}]};
        in_recovery ->
            {errors_500, [{'_', <<"Cannot create buckets when cluster is in recovery mode">>}]}
    end.

handle_bucket_create(PoolId, Req) ->
    Params = Req:parse_post(),
    Name = proplists:get_value("name", Params),
    ValidateOnly = (proplists:get_value("just_validate", Req:parse_qs()) =:= "1"),
    IgnoreWarnings = (proplists:get_value("ignore_warnings", Req:parse_qs()) =:= "1"),
    MaxBuckets = ns_config_ets_dup:unreliable_read_key(max_bucket_count, 10),
    case length(ns_bucket:get_buckets()) >= MaxBuckets of
        true ->
            reply_json(Req, {struct, [{'_', iolist_to_binary(io_lib:format("Cannot create more than ~w buckets", [MaxBuckets]))}]}, 400);
        false ->
            case {ValidateOnly, IgnoreWarnings,
                  parse_bucket_params(true,
                                      Name,
                                      Params,
                                      ns_bucket:get_buckets(),
                                      extended_cluster_storage_info(),
                                      IgnoreWarnings)} of
                {_, _, {errors, Errors, JSONSummaries}} ->
                    reply_json(Req, {struct, [{errors, {struct, Errors}},
                                              {summaries, {struct, JSONSummaries}}]}, 400);
                {false, _, {ok, ParsedProps, _}} ->
                    case do_bucket_create(Name, ParsedProps) of
                        ok ->
                            respond_bucket_created(Req, PoolId, Name);
                        {errors, Errors} ->
                            reply_json(Req, {struct, Errors}, 400);
                        {errors_500, Errors} ->
                            reply_json(Req, {struct, Errors}, 503)
                    end;
                {true, true, {ok, _, JSONSummaries}} ->
                    reply_json(Req, {struct, [{errors, {struct, []}},
                                              {summaries, {struct, JSONSummaries}}]}, 200);
                {true, false, {ok, ParsedProps, JSONSummaries}} ->
                    FinalErrors = perform_warnings_validation(ParsedProps, []),
                    reply_json(Req, {struct, [{errors, {struct, FinalErrors}},
                                              {summaries, {struct, JSONSummaries}}]},
                               case FinalErrors of
                                   [] -> 200;
                                   _ -> 400
                               end)
            end
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

handle_bucket_flush(_PoolId, Id, Req) ->
    XDCRDocs = xdc_rdoc_replication_srv:find_all_replication_docs(),
    case lists:any(
           fun (PList) ->
                   erlang:binary_to_list(proplists:get_value(source, PList)) =:= Id
           end, XDCRDocs) of
        false ->
            do_handle_bucket_flush(Id, Req);
        true ->
            reply_json(Req, {struct, [{'_', <<"Cannot flush buckets with outgoing XDCR">>}]}, 503)
    end.

do_handle_bucket_flush(Id, Req) ->
    case ns_orchestrator:flush_bucket(Id) of
        ok ->
            Req:respond({200, server_header(), []});
        rebalance_running ->
            reply_json(Req, {struct, [{'_', <<"Cannot flush buckets during rebalance">>}]}, 503);
        in_recovery ->
            reply_json(Req, {struct, [{'_', <<"Cannot flush buckets when cluster is in recovery mode">>}]}, 503);
        bucket_not_found ->
            Req:respond({404, server_header(), []});
        flush_disabled ->
            reply_json(Req, {struct, [{'_', <<"Flush is disabled for the bucket">>}]}, 400);
        OtherError ->
            Msg = io_lib:format("Got error: ~p", [OtherError]),
            Req:respond({503, server_header(), Msg})
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

parse_bucket_params(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals) ->
    parse_bucket_params(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals, false).

parse_bucket_params(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals, IgnoreWarnings) ->
    RV = parse_bucket_params_without_warnings(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals),
    case {IgnoreWarnings, RV} of
        {_, {ok, _, _} = X} -> X;
        {false, {errors, Errors, Summaries, OKs}} ->
            {errors, perform_warnings_validation(OKs, Errors), Summaries};
	{true, {errors, Errors, Summaries, _}} ->
            {errors, Errors, Summaries}
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
                                                BucketConfig, AuthType, AllBuckets)
    end.

basic_bucket_params_screening_tail(IsNew, BucketName, Params, BucketConfig, AuthType, AllBuckets) ->
    Candidates0 = [{ok, name, BucketName},
                   {ok, auth_type, AuthType},
                   parse_validate_flush_enabled(proplists:get_value("flushEnabled", Params, "0")),
                   case IsNew of
                       true ->
                           case BucketConfig of
                               false ->
                                   %% we'll give error on missing bucket name later
                                   case BucketName =:= undefined orelse ns_bucket:is_valid_bucket_name(BucketName) of
                                       false ->
                                           {error, name, <<"Bucket name can only contain characters in range A-Z, a-z, 0-9 as well as underscore, period, dash & percent. Consult the documentation.">>};
                                       _ ->
                                           %% we have to check for conflict here because we were looking for BucketConfig using case sensetive search (in basic_bucket_params_screening/4)
                                           %% but we do not allow buckets with the same names in a different register
                                           case BucketName =/= undefined andalso ns_bucket:name_conflict(BucketName, AllBuckets) of
                                               false ->
                                                  undefined;
                                               _ ->
                                                  {error, name, <<"Bucket with given name already exists">>}
                                           end
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
                          | Candidates1];
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
                          end,
                          parse_validate_threads_number(proplists:get_value("threadsNumber", Params))
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

parse_validate_flush_enabled("0") -> {ok, flush_enabled, false};
parse_validate_flush_enabled("1") -> {ok, flush_enabled, true};
parse_validate_flush_enabled(_ReplicaValue) -> {error, flushEnabled, <<"flushEnabled can only be 1 or 0">>}.

parse_validate_threads_number(undefined) ->
    {ok, num_threads, 3};
parse_validate_threads_number(NumThreads) ->
    case menelaus_util:parse_validate_number(NumThreads, 2, 8) of
        invalid ->
            {error, threadsNumber,
             <<"The number of threads must be an integer between 2 and 8">>};
        too_small ->
            {error, threadsNumber,
             <<"The number of threads can't be less than 2">>};
        too_large ->
            {error, threadsNumber,
             <<"The number of threads can't be greater than 8">>};
        {ok, X} ->
            {ok, num_threads, X}
    end.

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

handle_purge_compact_bucket(_PoolId, Bucket, Req) ->
    ok = compaction_daemon:force_purge_compact_bucket(Bucket),
    Req:respond({200, server_header(), []}).

handle_cancel_bucket_compaction(_PoolId, Bucket, Req) ->
    ok = compaction_daemon:cancel_forced_bucket_compaction(Bucket),
    Req:respond({200, server_header(), []}).

handle_compact_databases(_PoolId, Bucket, Req) ->
    ok = compaction_daemon:force_compact_db_files(Bucket),
    Req:respond({200, server_header(), []}).

handle_cancel_databases_compaction(_PoolId, Bucket, Req) ->
    ok = compaction_daemon:cancel_forced_db_compaction(Bucket),
    Req:respond({200, server_header(), []}).

handle_compact_view(_PoolId, Bucket, DDocId, Req) ->
    ok = compaction_daemon:force_compact_view(Bucket, DDocId),
    Req:respond({200, server_header(), []}).

handle_cancel_view_compaction(_PoolId, Bucket, DDocId, Req) ->
    ok = compaction_daemon:cancel_forced_view_compaction(Bucket, DDocId),
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

    %% it is not possible to create bucket with duplicate name in different register
    {_OK10, E10} = basic_bucket_params_screening(true, "Mcd",
                                              [{"bucketType", "membase"},
                                               {"authType", "sasl"}, {"saslPassword", ""},
                                               {"ramQuotaMB", "400"}, {"replicaNumber", "2"}],
                                              AllBuckets),
    ?assertEqual([{name, <<"Bucket with given name already exists">>}], E10),

    ok.

-endif.

handle_ddocs_list(PoolId, BucketName, Req, _, BucketConfig) ->
    FoundBucket = ns_bucket:bucket_type(BucketConfig) =:= membase
        andalso lists:member(node(), ns_bucket:bucket_nodes(BucketConfig)),
    case FoundBucket of
        true ->
            do_handle_ddocs_list(PoolId, BucketName, Req);
        _ ->
            reply_json(Req, {struct, [{error, no_ddocs_service}]}, 400)
    end.

do_handle_ddocs_list(PoolId, Bucket, Req) ->
    DDocs = capi_ddoc_replication_srv:sorted_full_live_ddocs(Bucket),
    RV = [begin
              Id = capi_utils:extract_doc_id(Doc),
              {struct, [{doc, capi_utils:couch_doc_to_mochi_json(Doc)},
                        {controllers, {struct, [{compact, bin_concat_path(["pools", PoolId, "buckets", Bucket, "ddocs", Id, "controller", "compactView"])},
                                                {setUpdateMinChanges,
                                                 bin_concat_path(["pools", PoolId, "buckets", Bucket,
                                                                  "ddocs", Id, "controller", "setUpdateMinChanges"])}]}}]}
          end || Doc <- DDocs],
    reply_json(Req, {struct, [{rows, RV}]}).

handle_set_ddoc_update_min_changes(_PoolId, Bucket, DDocIdStr, Req) ->
    DDocId = list_to_binary(DDocIdStr),

    capi_frontend:with_subdb(
      Bucket, <<"master">>,
      fun (MasterDb) ->
              case couch_db:open_doc(MasterDb, DDocId, [ejson_body]) of
                  {ok, #doc{body={Body}} = DDoc} ->
                      {Options0} = proplists:get_value(<<"options">>, Body, {[]}),
                      Params = Req:parse_post(),

                      {Options1, Errors} =
                          lists:foldl(
                            fun (Key, {AccOptions, AccErrors}) ->
                                    BinKey = list_to_binary(Key),
                                    %% just unset the option
                                    AccOptions1 = lists:keydelete(BinKey, 1, AccOptions),

                                    case proplists:get_value(Key, Params) of
                                        undefined ->
                                            {AccOptions1, AccErrors};
                                        Value ->
                                            case menelaus_util:parse_validate_number(
                                                   Value, 0, undefined) of
                                                {ok, Parsed} ->
                                                    AccOptions2 =
                                                        [{BinKey, Parsed} | AccOptions1],
                                                    {AccOptions2, AccErrors};
                                                Error ->
                                                    Msg = io_lib:format(
                                                            "Invalid ~s: ~p",
                                                            [Key, Error]),
                                                    AccErrors1 =
                                                        [{Key, iolist_to_binary(Msg)}],
                                                    {AccOptions, AccErrors1}
                                            end
                                    end
                            end, {Options0, []},
                            ["updateMinChanges", "replicaUpdateMinChanges"]),

                      case Errors of
                          [] ->
                              complete_update_ddoc_options(Req, Bucket, DDoc, Options1);
                          _ ->
                              reply_json(Req, {struct, Errors}, 400)
                      end;
                  {not_found, _} ->
                      reply_json(Req, {struct, [{'_',
                                                 <<"Design document not found">>}]}, 400)
              end
      end).

complete_update_ddoc_options(Req, Bucket, #doc{body={Body0}}= DDoc, Options0) ->
    Options = {Options0},
    NewBody0 = [{<<"options">>, Options} |
                lists:keydelete(<<"options">>, 1, Body0)],

    NewBody = {NewBody0},
    NewDDoc = DDoc#doc{body=NewBody},
    ok = capi_ddoc_replication_srv:update_doc(Bucket, NewDDoc),
    reply_json(Req, capi_utils:couch_json_to_mochi_json(Options)).

-define(RANDOM_KEY_ATTEMPTS, 10).

handle_local_random_key(_PoolId, Bucket, Req) ->
    NodesVBuckets = vbucket_map_mirror:node_vbuckets_dict(Bucket),
    case dict:find(node(), NodesVBuckets) of
        error ->
            reply_json(Req, {struct, [{error, no_ddocs_service}]}, 400);
        {ok, OurVBuckets} ->
            handle_local_random_key_have_vbuckets(Bucket, Req, OurVBuckets)
    end.

handle_local_random_key_have_vbuckets(Bucket, Req, OurVBuckets) ->
    NumVBuckets = length(OurVBuckets),

    random:seed(erlang:now()),
    MaybeKey = random_key(Bucket, OurVBuckets,
                          NumVBuckets, ?RANDOM_KEY_ATTEMPTS),

    case MaybeKey of
        empty ->
            reply_json(Req, {struct,
                             [{ok, false},
                              {error, <<"fallback_to_all_docs">>}]}, 404);
        Key ->
            reply_json(Req, {struct,
                             [{ok, true},
                              {key, Key}]})
    end.

random_key(_Bucket, _VBuckets, _NumVBuckets, 0) ->
    empty;
random_key(Bucket, VBuckets, NumVBuckets, Attempts) ->
    case do_random_key(Bucket, VBuckets, NumVBuckets) of
        empty ->
            random_key(Bucket, VBuckets, NumVBuckets, Attempts - 1);
        Key ->
            Key
    end.

do_random_key(Bucket, VBuckets, NumVBuckets) ->
    Ix = random:uniform(NumVBuckets),
    VBucket = lists:nth(Ix, VBuckets),

    try
        capi_frontend:with_subdb(
          Bucket, VBucket,
          fun (Db) ->
                  case couch_db:random_doc_info(Db) of
                      {ok, #doc_info{id=Key}} ->
                          Key;
                      empty ->
                          empty
                  end
          end)
    catch
        exit:{open_db_failed, {not_found, no_db_file}} ->
            empty
    end.
