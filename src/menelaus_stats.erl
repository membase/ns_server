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

-module(menelaus_stats).
-author('NorthScale <info@northscale.com>').

-include("ns_stats.hrl").
-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([handle_bucket_stats/3,
         handle_stats_section/3,
         handle_bucket_node_stats/4,
         handle_stats_section_for_node/4,
         handle_specific_stat_for_buckets/4,
         handle_overview_stats/2,
         basic_stats/1,
         bucket_disk_usage/1,
         bucket_ram_usage/1,
         serve_stats_directory/3]).

-export([serve_ui_stats/1]).

%% External API
bucket_disk_usage(BucketName) ->
    {_, _, _, _, DiskUsed, _}
        = last_membase_sample(BucketName, ns_bucket:live_bucket_nodes(BucketName)),
    DiskUsed.

bucket_ram_usage(BucketName) ->
    %% NOTE: we're getting last membase sample, but first stat name is
    %% same in memcached buckets, so it works for them too.
    element(1, last_membase_sample(BucketName, ns_bucket:live_bucket_nodes(BucketName))).

extract_stat(StatName, Sample) ->
    case orddict:find(StatName, Sample#stat_entry.values) of
        error -> 0;
        {ok, V} -> V
    end.

get_node_infos(NodeNames) ->
    NodesDict = ns_doctor:get_nodes(),
    lists:foldl(fun (N, A) ->
                        case dict:find(N, NodesDict) of
                            {ok, V} -> [{N, V} | A];
                            _ -> A
                        end
                end, [], NodeNames).

grab_latest_bucket_stats(BucketName, Nodes) ->
    NodeInfos = get_node_infos(Nodes),
    Stats = extract_interesting_buckets(BucketName, NodeInfos),
    {FoundNodes, _} = lists:unzip(Stats),
    RestNodes = Nodes -- FoundNodes,
    RestStats = [{N, S} || {N, [#stat_entry{values=S} | _]} <-
                               menelaus_stats_gatherer:invoke_archiver(BucketName, RestNodes,
                                                                       {1, minute, 1})],
    Stats ++ RestStats.

extract_interesting_stat(Key, Stats) ->
    case lists:keyfind(Key, 1, Stats) of
        false -> 0;
        {_, Stat} -> Stat
    end.

extract_interesting_buckets(BucketName, NodeInfos) ->
    Stats0 =
        lists:map(
          fun ({Node, NodeInfo}) ->
                  case proplists:get_value(per_bucket_interesting_stats, NodeInfo) of
                      undefined ->
                          [];
                      NodeStats ->
                          case [S || {B, S} <- NodeStats, B =:= BucketName] of
                              [BucketStats] ->
                                  [{Node, BucketStats}];
                              _ ->
                                  []
                          end
                  end
          end, NodeInfos),

    lists:append(Stats0).

last_membase_sample(BucketName, Nodes) ->
    lists:foldl(
      fun ({_, Stats},
           {AccMem, AccItems, AccOps, AccFetches, AccDisk, AccData, AccActiveNonRes}) ->
              {extract_interesting_stat(mem_used, Stats) + AccMem,
               extract_interesting_stat(curr_items, Stats) + AccItems,
               extract_interesting_stat(ops, Stats) + AccOps,
               extract_interesting_stat(ep_bg_fetched, Stats) + AccFetches,
               extract_interesting_stat(couch_docs_actual_disk_size, Stats) +
                   extract_interesting_stat(couch_spatial_disk_size, Stats) +
                   extract_interesting_stat(couch_views_actual_disk_size, Stats) + AccDisk,
               extract_interesting_stat(couch_docs_data_size, Stats) +
                   extract_interesting_stat(couch_views_data_size, Stats) +
                   extract_interesting_stat(couch_spatial_data_size, Stats) + AccData,
               extract_interesting_stat(vb_active_num_non_resident, Stats) + AccActiveNonRes}
      end, {0, 0, 0, 0, 0, 0, 0}, grab_latest_bucket_stats(BucketName, Nodes)).



last_memcached_sample(BucketName, Nodes) ->
    {MemUsed, CurrItems, Ops, CmdGet, GetHits}
        = lists:foldl(
            fun ({_, Stats},
                 {AccMem, AccItems, AccOps, AccGet, AccGetHits}) ->
                    {extract_interesting_stat(mem_used, Stats) + AccMem,
                     extract_interesting_stat(curr_items, Stats) + AccItems,
                     extract_interesting_stat(ops, Stats) + AccOps,
                     extract_interesting_stat(cmd_get, Stats) + AccGet,
                     extract_interesting_stat(get_hits, Stats) + AccGetHits}
            end, {0, 0, 0, 0, 0}, grab_latest_bucket_stats(BucketName, Nodes)),

    {MemUsed, CurrItems, Ops,
     case CmdGet == 0 of
         true -> 0;
         _ -> GetHits / CmdGet
     end}.

last_bucket_stats(membase, BucketName, Nodes) ->
    {MemUsed, ItemsCount, Ops, Fetches, Disk, Data, ActiveNonRes}
        = last_membase_sample(BucketName, Nodes),
    [{opsPerSec, Ops},
     {diskFetches, Fetches},
     {itemCount, ItemsCount},
     {diskUsed, Disk},
     {dataUsed, Data},
     {memUsed, MemUsed},
     {vbActiveNumNonResident, ActiveNonRes}];
last_bucket_stats(memcached, BucketName, Nodes) ->
    {MemUsed, ItemsCount, Ops, HitRatio} = last_memcached_sample(BucketName, Nodes),
    [{opsPerSec, Ops},
     {hitRatio, HitRatio},
     {itemCount, ItemsCount},
     {memUsed, MemUsed}].

basic_stats(BucketName) ->
    {ok, BucketConfig} = ns_bucket:maybe_get_bucket(BucketName, undefined),
    QuotaBytes = ns_bucket:ram_quota(BucketConfig),
    BucketType = ns_bucket:bucket_type(BucketConfig),
    BucketNodes = ns_bucket:live_bucket_nodes_from_config(BucketConfig),
    Stats = last_bucket_stats(BucketType, BucketName, BucketNodes),
    MemUsed = proplists:get_value(memUsed, Stats),
    QuotaPercent = try (MemUsed * 100.0 / QuotaBytes) of
                       X -> X
                   catch
                       error:badarith -> 0
                   end,
    [{quotaPercentUsed, lists:min([QuotaPercent, 100])}
     | Stats].

handle_overview_stats(_PoolId, Req) ->
    BucketNamesUnsorted =
        menelaus_auth:get_accessible_buckets(fun (BucketName) ->
                                                     {[{bucket, BucketName}, stats], read}
                                             end, Req),

    Names = lists:sort(BucketNamesUnsorted),
    {ClientTStamp, Window} = parse_stats_params([{"zoom", "hour"}]),
    AllSamples = lists:map(fun (Name) ->
                                   grab_aggregate_op_stats(Name, all, ClientTStamp, Window, [ops, ep_bg_fetched])
                           end, Names),
    MergedSamples = case AllSamples of
                        [FirstBucketSamples | RestSamples] ->
                            merge_all_samples_normally(FirstBucketSamples, RestSamples);
                        [] -> []
                    end,
    TStamps = [X#stat_entry.timestamp || X <- MergedSamples],
    Ops = [extract_stat(ops, X) || X <- MergedSamples],
    DiskReads = [extract_stat(ep_bg_fetched, X) || X <- MergedSamples],
    menelaus_util:reply_json(Req, {struct, [{timestamp, TStamps},
                                            {ops, Ops},
                                            {ep_bg_fetched, DiskReads}]}).

%% GET /pools/{PoolID}/buckets/{Id}/stats
handle_bucket_stats(_PoolId, Id, Req) ->
    Params = Req:parse_qs(),
    PropList1 = build_bucket_stats_ops_response(all, Id, Params, true),
    PropList2 = build_bucket_stats_hks_response(Id),
    menelaus_util:reply_json(Req, {struct, PropList1 ++ PropList2}).

handle_stats_section(_PoolId, Id, Req) ->
    case section_exists(Id) of
        true ->
            do_handle_stats_section(Id, Req);
        false ->
            menelaus_util:reply_not_found(Req)
    end.

do_handle_stats_section(Id, Req) ->
    Params = Req:parse_qs(),
    PropList1 = build_bucket_stats_ops_response(all, Id, Params, false),
    menelaus_util:reply_json(Req, {struct, PropList1}).


%% Per-Node Stats
%% GET /pools/{PoolID}/buckets/{Id}/nodes/{NodeId}/stats
%%
%% Per-node stats match bucket stats with the addition of a 'hostname' key,
%% stats specific to the node (obviously), and removal of any cross-node stats
handle_bucket_node_stats(_PoolId, BucketName, HostName, Req) ->
    case menelaus_web:find_node_hostname(HostName, Req) of
        false ->
            menelaus_util:reply_not_found(Req);
        {ok, Node} ->
            Params = Req:parse_qs(),
            Ops = build_bucket_stats_ops_response([Node], BucketName, Params, true),
            BucketsTopKeys = case hot_keys_keeper:bucket_hot_keys(BucketName, Node) of
                                 undefined -> [];
                                 X -> X
                             end,

            HKS = jsonify_hks(BucketsTopKeys),
            menelaus_util:reply_json(
              Req,
              {struct, [{hostname, list_to_binary(HostName)}
                        | HKS ++ Ops]})
    end.

handle_stats_section_for_node(_PoolId, Id, HostName, Req) ->
    case menelaus_web:find_node_hostname(HostName, Req) of
        false ->
            menelaus_util:reply_not_found(Req);
        {ok, Node} ->
            case section_exists(Id) andalso lists:member(Node, section_nodes(Id)) of
                true ->
                    do_handle_stats_section_for_node(Id, HostName, Node, Req);
                false ->
                    menelaus_util:reply_not_found(Req)
            end
    end.

do_handle_stats_section_for_node(Id, HostName, Node, Req) ->
    Params = Req:parse_qs(),
    Ops = build_bucket_stats_ops_response([Node], Id, Params, false),
    menelaus_util:reply_json(
      Req,
      {struct, [{hostname, list_to_binary(HostName)}
                | Ops]}).

%% Specific Stat URL grouped by nodes
%% GET /pools/{PoolID}/buckets/{Id}/stats/{StatName}
%%
%% Req:ok({"application/json",
%%         menelaus_util:server_header(),
%%         <<"{
%%     \"timestamp\": [1,2,3,4,5],
%%     \"nodeStats\": [{\"127.0.0.1:9000\": [1,2,3,4,5]},
%%                     {\"127.0.0.1:9001\": [1,2,3,4,5]}]
%%   }">>}).
handle_specific_stat_for_buckets(_PoolId, BucketName, StatName, Req) ->
    Params = Req:parse_qs(),
    menelaus_util:reply_json(
      Req,
      build_response_for_specific_stat(BucketName, StatName, Params, menelaus_util:local_addr(Req))).

%% Function to extract a simple stat from a list of stats.
build_simple_stat_extractor(StatAtom, StatBinary) ->
    fun (#stat_entry{timestamp = TS, values = VS}) ->
            V = case dict_safe_fetch(StatAtom, VS, undefined) of
                    undefined ->
                        dict_safe_fetch(StatBinary, VS, undefined);
                    V1 ->
                        V1
                end,

            {TS, V}
    end.

%% Function to extract a raw stat from a list of stats.
build_raw_stat_extractor(StatBinary) ->
    fun (#stat_entry{timestamp = TS, values = VS}) ->
            {TS, dict_safe_fetch(StatBinary, VS, undefined)}
    end.

%%
%% Some stats are computed using other stats.
%% Stats used in the computation are gathered and the ComputeFun is then
%% applied on them to extract the relevant stat.
%%
build_computed_stat_extractor(ComputeFun, Stats) ->
    fun (#stat_entry{timestamp = TS, values = VS}) ->
            Args = [dict_safe_fetch(Name, VS, undefined) || Name <- Stats],
            case lists:member(undefined, Args) of
                true ->
                    {TS, undefined};
                _ ->
                    {TS, erlang:apply(ComputeFun, Args)}
            end
    end.

%%
%% For the specified StatName, build the list of stats that need to be gathered
%% and the function to extract them.
%% E.g. for a computed stat, vb_active_resident_items_ratio, it will return
%% following:
%%      {[vb_active_num_non_resident, curr_items], <extractor_function>}.
%%
build_stat_list_and_extractor(BucketName, StatName) ->
    ExtraStats = computed_stats_lazy_proplist(BucketName),
    build_stat_list_and_extractor_inner(ExtraStats, StatName).

build_stat_list_and_extractor_inner(ExtraStats, StatName) ->
    StatBinary = list_to_binary(StatName),
    case lists:keyfind(StatBinary, 1, ExtraStats) of
        {_K, {F, Meta}} ->
            {Meta, build_computed_stat_extractor(F, Meta)};
        false ->
            Stat = try
                       {ok, list_to_existing_atom(StatName)}
                   catch
                       error:badarg ->
                           error
                   end,

            case Stat of
                {ok, StatAtom} ->
                    {[StatAtom, StatBinary],
                     build_simple_stat_extractor(StatAtom, StatBinary)};
                error ->
                    {[StatBinary],
                     build_raw_stat_extractor(StatBinary)}
            end
    end.

dict_safe_fetch(K, Dict, Default) ->
    case lists:keyfind(K, 1, Dict) of
        {_, V} -> V;
        _ -> Default
    end.

are_samples_undefined(Samples) ->
    lists:all(fun (List) ->
                      lists:all(fun ({_, undefined}) ->
                                        true;
                                    ({_, _}) ->
                                        false
                                end, List)
              end, Samples).

%%
%% Earlier we were gathering all stats from all nodes even if we are
%% interested in only one or some of them.
%% To optimize, we will gather only the stats as specified by the StatName.
%%

get_samples_for_stat(BucketName, StatName, ForNodes, ClientTStamp, Window) ->
    {GatherStats, StatExtractor} = build_stat_list_and_extractor(BucketName,
                                                                 StatName),

    {AllNodesSamples, Nodes} = gather_needed_stats(BucketName, ForNodes,
                                                   ClientTStamp, Window,
                                                   GatherStats),
    {[lists:map(StatExtractor, NodeSamples) ||
         {_, NodeSamples} <- AllNodesSamples], Nodes}.

gather_needed_stats(BucketName, ForNodes, ClientTStamp, Window, GatherStats) ->
    {MainNode, MainSamples, RestSamplesRaw}
        = menelaus_stats_gatherer:gather_stats(BucketName, ForNodes,
                                               ClientTStamp, Window,
                                               GatherStats),
    Nodes = [MainNode | [N || {N, _} <- RestSamplesRaw]],
    AllNodesSamples = [{MainNode, lists:reverse(MainSamples)} | RestSamplesRaw],
    {AllNodesSamples, Nodes}.

get_samples_from_one_of_kind([], _, _, _) ->
    %% We will reach here if samples are not available for a known stat.
    %% Samples may not be available at higher zoom level e.g. week, year etc.
    %% We do not know which Kind the stat belongs to and the
    %% nodes relevant for that Kind i.e. its section_nodes().
    %% So, return empty sample with local node.
    {[[]], [node()]};
get_samples_from_one_of_kind([Kind | RestKinds], StatName, ClientTStamp, Window) ->
    case section_nodes(Kind) of
        [] ->
            get_samples_from_one_of_kind(RestKinds,
                                         StatName, ClientTStamp, Window);
        ForNodes ->
            get_samples_for_kind(Kind, RestKinds, ForNodes,
                                 StatName, ClientTStamp, Window)
    end.

get_samples_for_kind(Kind, RestKinds, ForNodes, StatName, ClientTStamp, Window) ->
    RV = {Samples, _} = get_samples_for_stat(Kind, StatName, ForNodes, ClientTStamp, Window),
    case are_samples_undefined(Samples) of
        true ->
            get_samples_from_one_of_kind(RestKinds, StatName, ClientTStamp, Window);
        false ->
            RV
    end.

get_samples_for_system_or_bucket_stat(BucketName, StatName, ClientTStamp, Window) ->
    SearchList = get_stats_search_order(StatName, BucketName),
    get_samples_from_one_of_kind(SearchList, StatName, ClientTStamp, Window).

%% List of different types of stats
kinds_list(BucketName) ->
    ["@system", BucketName, "@query", "@index-" ++ BucketName,
     "@fts-" ++ BucketName, "@xdcr-" ++ BucketName, "@index"].

%% For many stats, their kind can be identified by their prefix.
get_possible_kind(StatName, BucketName) ->
    case StatName of
        "query_" ++ _Rest ->
            "@query";
        "replication" ++ _Rest ->
            "@xdcr-" ++ BucketName;
        "index" ++ _Rest ->
            "@index-" ++ BucketName;
        "fts" ++ _Rest ->
            "@fts-" ++ BucketName;
        "views" ++ _Rest ->
            BucketName;
        "spatial" ++ _Rest ->
            BucketName;
        "vb_" ++ _Rest ->
            BucketName;
        "ep_" ++ _Rest ->
            BucketName;
        _ ->
            kind_not_found
    end.

%%
%% Optimize the search order based on the stat prefix.
%% E.g. if a stat is query_..., then search for it in
%% query related stats first.
%%
get_stats_search_order(StatName, BucketName) ->
    Kind = get_possible_kind(StatName, BucketName),
    case Kind of
        kind_not_found ->
            %% Some stats do not have standard prefix.
            %% In that case, we use the default search order.
            kinds_list(BucketName);
        _ ->
            %% Move "Kind" to beginning of the search list.
            [Kind | lists:delete(Kind, kinds_list(BucketName))]
    end.

build_response_for_specific_stat(BucketName, StatName, Params, LocalAddr) ->
    {ClientTStamp, {Step, _, Count} = Window} =
        parse_stats_params(Params),

    {NodesSamples, Nodes} =
        get_samples_for_system_or_bucket_stat(BucketName, StatName, ClientTStamp, Window),

    Config = ns_config:get(),
    Hostnames = [list_to_binary(menelaus_web:build_node_hostname(Config, N, LocalAddr)) || N <- Nodes],

    Timestamps = [TS || {TS, _} <- hd(NodesSamples)],
    MainValues = [VS || {_, VS} <- hd(NodesSamples)],

    AllignedRestValues
        = lists:map(fun (undefined) -> [undefined || _ <- Timestamps];
                        (Samples) ->
                            Dict = orddict:from_list(Samples),
                            [dict_safe_fetch(T, Dict, 0) || T <- Timestamps]
                    end, tl(NodesSamples)),
    {struct, [{samplesCount, Count},
              {isPersistent, is_persistent(BucketName)},
              {lastTStamp, case Timestamps of
                               [] -> 0;
                               L -> lists:last(L)
                           end},
              {interval, Step * 1000},
              {timestamp, Timestamps},
              {nodeStats, {struct, lists:zipwith(fun (H, VS) ->
                                                         {H, VS}
                                                 end,
                                                 Hostnames, [MainValues | AllignedRestValues])}}]}.

%% ops SUM(cmd_get, cmd_set,
%%         incr_misses, incr_hits,
%%         decr_misses, decr_hits,
%%         cas_misses, cas_hits, cas_badval,
%%         delete_misses, delete_hits,
%%         cmd_flush)
%% cmd_get (cmd_get)
%% get_misses (get_misses)
%% get_hits (get_hits)
%% cmd_set (cmd_set)
%% evictions (evictions)
%% replacements (if available in time)
%% misses SUM(get_misses, delete_misses, incr_misses, decr_misses,
%%            cas_misses)
%% updates SUM(cmd_set, incr_hits, decr_hits, cas_hits)
%% bytes_read (bytes_read)
%% bytes_written (bytes_written)
%% hit_ratio (get_hits / cmd_get)
%% curr_items (curr_items)

%% Implementation

merge_all_samples_normally(MainSamples, ListOfLists) ->
    ETS = ets:new(ok, [{keypos, #stat_entry.timestamp}]),
    try do_merge_all_samples_normally(ETS, MainSamples, ListOfLists)
    after
        ets:delete(ETS)
    end.

do_merge_all_samples_normally(ETS, MainSamples, ListOfLists) ->
    ets:insert(ETS, MainSamples),
    lists:foreach(
      fun (OtherSamples) ->
              lists:foreach(
                fun (OtherS) ->
                        TS = OtherS#stat_entry.timestamp,
                        case ets:lookup(ETS, TS) of
                            [S|_] ->
                                ets:insert(ETS, aggregate_stat_entries(S, OtherS));
                            _ ->
                                nothing
                        end
                end, OtherSamples)
      end, ListOfLists),
    [hd(ets:lookup(ETS, T)) || #stat_entry{timestamp = T} <- MainSamples].

section_nodes("@system") ->
    ns_cluster_membership:actual_active_nodes();
section_nodes("@index") ->
    ns_cluster_membership:service_actual_nodes(ns_config:latest(), index);
section_nodes("@query") ->
    ns_cluster_membership:service_actual_nodes(ns_config:latest(), n1ql);
section_nodes("@index-"++_) ->
    ns_cluster_membership:service_actual_nodes(ns_config:latest(), index);
section_nodes("@fts-"++_) ->
    ns_cluster_membership:service_actual_nodes(ns_config:latest(), fts);
section_nodes("@fts") ->
    ns_cluster_membership:service_actual_nodes(ns_config:latest(), fts);
section_nodes("@xdcr-"++Bucket) ->
    ns_bucket:live_bucket_nodes(Bucket);
section_nodes(Bucket) ->
    ns_bucket:live_bucket_nodes(Bucket).

is_persistent("@query") ->
    false;
is_persistent("@index-"++_) ->
    false;
is_persistent("@fts-"++_) ->
    false;
is_persistent("@xdcr-"++_) ->
    false;
is_persistent(BucketName) ->
    ns_bucket:is_persistent(BucketName).

bucket_exists(Bucket) ->
    ns_bucket:get_bucket(Bucket) =/= not_present.

section_exists("@system") ->
    true;
section_exists("@index") ->
    true;
section_exists("@query") ->
    true;
section_exists("@index-"++Bucket) ->
    bucket_exists(Bucket);
section_exists("@fts-"++Bucket) ->
    bucket_exists(Bucket);
section_exists("@xdcr-"++Bucket) ->
    bucket_exists(Bucket);
section_exists(Bucket) ->
    bucket_exists(Bucket).

grab_system_aggregate_op_stats(all, ClientTStamp, Window) ->
    grab_aggregate_op_stats("@system", section_nodes("@system"), ClientTStamp, Window);
grab_system_aggregate_op_stats([Node], ClientTStamp, Window) ->
    grab_aggregate_op_stats("@system", [Node], ClientTStamp, Window).

grab_aggregate_op_stats(Bucket, all, ClientTStamp, Window) ->
    grab_aggregate_op_stats(Bucket, section_nodes(Bucket), ClientTStamp, Window);
grab_aggregate_op_stats(Bucket, Nodes, ClientTStamp, Window) ->
    grab_aggregate_op_stats(Bucket, Nodes, ClientTStamp, Window, all).

grab_aggregate_op_stats(Bucket, all, ClientTStamp, Window, StatList) ->
    grab_aggregate_op_stats(Bucket, section_nodes(Bucket), ClientTStamp, Window, StatList);
grab_aggregate_op_stats(Bucket, Nodes, ClientTStamp, Window, StatList) ->
    {_MainNode, MainSamples, Replies} =
        menelaus_stats_gatherer:gather_stats(Bucket, Nodes, ClientTStamp, Window, StatList),
    RV = merge_all_samples_normally(MainSamples, [S || {_,S} <- Replies]),
    lists:reverse(RV).

parse_stats_params(Params) ->
    ClientTStamp = case proplists:get_value("haveTStamp", Params) of
                       undefined -> undefined;
                       X -> try list_to_integer(X) of
                                XI -> XI
                            catch
                                _:_ -> undefined
                            end
                   end,
    {Step0, Period, Count0} = case proplists:get_value("zoom", Params) of
                                  "minute" -> {1, minute, 60};
                                  "hour" -> {60, hour, 900};
                                  "day" -> {1440, day, 1440};
                                  "week" -> {11520, week, 1152};
                                  "month" -> {44640, month, 1488};
                                  "year" -> {527040, year, 1464};
                                  undefined -> {1, minute, 60}
                              end,
    {Step, Count} = case proplists:get_value("resampleForUI", Params) of
                        undefined -> {1, Count0};
                        _ -> {Step0, 60}
                    end,
    {ClientTStamp, {Step, Period, Count}}.

global_index_stat(StatName) ->
    indexer_gsi:global_index_stat(StatName).

per_index_stat(Index, Metric) ->
    indexer_gsi:per_index_stat(Index, Metric).

global_fts_stat(StatName) ->
    indexer_fts:global_index_stat(StatName).

per_fts_stat(Index, Metric) ->
    indexer_fts:per_index_stat(Index, Metric).

computed_stats_lazy_proplist("@system") ->
    [];
computed_stats_lazy_proplist("@index") ->
    [];
computed_stats_lazy_proplist("@query") ->
    Z2 = fun (StatNameA, StatNameB, Combiner) ->
                 {Combiner, [StatNameA, StatNameB]}
         end,
    QueryAvgRequestTime = Z2(query_request_time, query_requests,
                             fun (TimeNanos, Count) ->
                                     try TimeNanos * 1.0E-9 / Count
                                     catch error:badarith -> 0
                                     end
                             end),

    QueryAvgServiceTime = Z2(query_service_time, query_requests,
                             fun (TimeNanos, Count) ->
                                     try TimeNanos * 1.0E-9 / Count
                                     catch error:badarith -> 0
                                     end
                             end),

    QueryAvgResultSize = Z2(query_result_size, query_requests,
                            fun (Size, Count) ->
                                    try Size / Count
                                    catch error:badarith -> 0
                                    end
                            end),

    QueryAvgResultCount = Z2(query_result_count, query_requests,
                             fun (RCount, Count) ->
                                     try RCount / Count
                                     catch error:badarith -> 0
                                     end
                             end),


    [{<<"query_avg_req_time">>, QueryAvgRequestTime},
     {<<"query_avg_svc_time">>, QueryAvgServiceTime},
     {<<"query_avg_response_size">>, QueryAvgResultSize},
     {<<"query_avg_result_count">>, QueryAvgResultCount}];
computed_stats_lazy_proplist("@index-"++BucketId) ->
    Z2 = fun (StatNameA, StatNameB, Combiner) ->
                 {Combiner, [StatNameA, StatNameB]}
         end,


    ComputeFragmentation =
        fun (DiskOverhead, DiskSize) ->
                try
                    100 * (DiskOverhead / max(DiskOverhead, DiskSize))
                catch error:badarith ->
                        0
                end
        end,


    GlobalFragmentation = Z2(global_index_stat(<<"disk_overhead_estimate">>),
                             global_index_stat(<<"disk_size">>),
                             ComputeFragmentation),

    [{global_index_stat(<<"fragmentation">>), GlobalFragmentation}] ++
        lists:flatmap(
          fun (Index) ->
                  AvgItemSize = Z2(per_index_stat(Index, <<"data_size">>),
                                   per_index_stat(Index, <<"items_count">>),
                                   fun (DataSize, Count) ->
                                           try
                                               DataSize / Count
                                           catch
                                               error:badarith ->
                                                   0
                                           end
                                   end),

                  AvgScanLatency = Z2(per_index_stat(Index, <<"total_scan_duration">>),
                                      per_index_stat(Index, <<"num_rows_returned">>),
                                      fun (ScanDuration, NumRows) ->
                                              try
                                                  ScanDuration / NumRows
                                              catch
                                                  error:badarith ->
                                                      0
                                              end
                                      end),

                  AllPendingDocs = Z2(per_index_stat(Index, <<"num_docs_pending">>),
                                      per_index_stat(Index, <<"num_docs_queued">>),
                                      fun (Pending, Queued) ->
                                              Pending + Queued
                                      end),

                  [{per_index_stat(Index, <<"avg_item_size">>), AvgItemSize},
                   {per_index_stat(Index, <<"avg_scan_latency">>), AvgScanLatency},
                   {per_index_stat(Index, <<"num_docs_pending+queued">>), AllPendingDocs}]
          end, get_indexes(indexer_gsi, BucketId));
computed_stats_lazy_proplist("@fts-"++BucketId) ->
    Z2 = fun (StatNameA, StatNameB, Combiner) ->
                 {Combiner, [StatNameA, StatNameB]}
         end,
    lists:flatmap(
      fun (Index) ->
              AvgQueriesLatency = Z2(per_fts_stat(Index, <<"total_request_time">>),
                                     per_fts_stat(Index, <<"total_queries">>),
                                     fun (TimeNanos, Count) ->
                                             try TimeNanos * 1.0E-6 / Count
                                             catch error:badarith -> 0
                                             end
                                     end),

              [{per_fts_stat(Index, <<"avg_queries_latency">>), AvgQueriesLatency}]
      end, get_indexes(indexer_fts, BucketId));
computed_stats_lazy_proplist("@fts") ->
    [];
computed_stats_lazy_proplist("@xdcr-"++BucketName) ->
    Z2 = fun (StatNameA, StatNameB, Combiner) ->
                 {Combiner, [StatNameA, StatNameB]}
         end,
    %% compute a list of per replication XDC stats
    Reps = case cluster_compat_mode:is_goxdcr_enabled() of
               true ->
                   goxdcr_status_keeper:get_replications(BucketName);
               false ->
                   []
           end,
    lists:flatmap(fun (Id) ->
                          Prefix = <<"replications/", Id/binary,"/">>,

                          PercentCompleteness = Z2(<<Prefix/binary, "docs_processed">>,
                                                   <<Prefix/binary, "changes_left">>,
                                                   fun (Processed, Left) ->
                                                           try (100 * Processed) / (Processed + Left)
                                                           catch error:badarith -> 0
                                                           end
                                                   end),

                          [{<<Prefix/binary, "percent_completeness">>, PercentCompleteness}]
                  end,
                  Reps);
computed_stats_lazy_proplist(BucketName) ->
    Z2 = fun (StatNameA, StatNameB, Combiner) ->
                 {Combiner, [StatNameA, StatNameB]}
         end,
    Z3 = fun (StatNameA, StatNameB, StatNameC, Combiner) ->
                 {Combiner, [StatNameA, StatNameB, StatNameC]}
         end,
    HitRatio = Z2(cmd_get, get_hits,
                  fun (Gets, _Hits) when Gets == 0 -> 0; % this handles int and float 0
                      (Gets, Hits) -> Hits * 100/Gets
                  end),
    EPCacheMissRatio = Z2(ep_bg_fetched, cmd_get,
                          fun (BGFetches, Gets) ->
                                  try BGFetches * 100 / Gets
                                  catch error:badarith -> 0
                                  end
                          end),
    ResidentItemsRatio = Z2(ep_num_non_resident, curr_items_tot,
                            fun (NonResident, CurrItems) ->
                                    try (CurrItems - NonResident) * 100 / CurrItems
                                    catch error:badarith -> 100
                                    end
                            end),
    AvgActiveQueueAge = Z2(vb_active_queue_age, vb_active_queue_size,
                           fun (ActiveAge, ActiveCount) ->
                                   try ActiveAge / ActiveCount / 1000
                                   catch error:badarith -> 0
                                   end
                           end),
    AvgReplicaQueueAge = Z2(vb_replica_queue_age, vb_replica_queue_size,
                            fun (ReplicaAge, ReplicaCount) ->
                                    try ReplicaAge / ReplicaCount / 1000
                                    catch error:badarith -> 0
                                    end
                            end),
    AvgPendingQueueAge = Z2(vb_pending_queue_age, vb_pending_queue_size,
                            fun (PendingAge, PendingCount) ->
                                    try PendingAge / PendingCount / 1000
                                    catch error:badarith -> 0
                                    end
                            end),
    AvgTotalQueueAge = Z2(vb_total_queue_age, ep_diskqueue_items,
                          fun (TotalAge, TotalCount) ->
                                  try TotalAge / TotalCount / 1000
                                  catch error:badarith -> 0
                                  end
                          end),
    TotalDisk = Z2(couch_docs_actual_disk_size, couch_views_actual_disk_size,
                   fun (Views, Docs) ->
                           Views + Docs
                   end),

    ResidenceCalculator = fun (NonResident, Total) ->
                                  try (Total - NonResident) * 100 / Total
                                  catch error:badarith -> 100
                                  end
                          end,

    Fragmentation = fun (Data, Disk) ->
                            try
                                round((Disk - Data) / Disk * 100)
                            catch error:badarith ->
                                    0
                            end
                    end,

    DocsFragmentation = Z2(couch_docs_data_size, couch_docs_disk_size,
                           Fragmentation),
    ViewsFragmentation = Z2(couch_views_data_size, couch_views_disk_size,
                            Fragmentation),

    ActiveResRate = Z2(vb_active_num_non_resident, curr_items,
                       ResidenceCalculator),
    ReplicaResRate = Z2(vb_replica_num_non_resident, vb_replica_curr_items,
                        ResidenceCalculator),
    PendingResRate = Z2(vb_pending_num_non_resident, vb_pending_curr_items,
                        ResidenceCalculator),

    AverageDiskUpdateTime = Z2(disk_update_total, disk_update_count,
                               fun (Total, Count) ->
                                       try Total / Count
                                       catch error:badarith -> 0
                                       end
                               end),

    AverageCommitTime = Z2(disk_commit_total, disk_commit_count,
                           fun (Total, Count) ->
                                   try Total / Count / 1000000
                                   catch error:badarith -> 0
                                   end
                           end),

    AverageBgWait = Z2(bg_wait_total, bg_wait_count,
                       fun (Total, Count) ->
                               try Total / Count
                               catch error:badarith -> 0
                               end
                       end),

    AvgActiveTimestampDrift = Z2(ep_active_hlc_drift, ep_active_hlc_drift_count,
                                 fun (DriftTotal, Count) ->
                                         try DriftTotal / 1000000 / Count
                                         catch error:badarith -> 0
                                         end
                                 end),

    AvgReplicaTimestampDrift = Z2(ep_replica_hlc_drift, ep_replica_hlc_drift_count,
                                  fun (DriftTotal, Count) ->
                                          try DriftTotal / 1000000 / Count
                                          catch error:badarith -> 0
                                          end
                                  end),

    XDCAllRepStats =
        case cluster_compat_mode:is_goxdcr_enabled() of
            true ->
                [];
            false ->
                %% compute a list of per replication XDC stats
                Reps = xdc_replication_sup:get_replications(list_to_binary(BucketName)),
                lists:flatmap(
                  fun ({Id, _Pid}) ->
                          Prefix = <<"replications/", Id/binary,"/">>,

                          WtAvgMetaLatency = Z2(<<Prefix/binary, "meta_latency_aggr">>,
                                                <<Prefix/binary, "meta_latency_wt">>,
                                                fun (Total, Count) ->
                                                        try Total / Count
                                                        catch error:badarith -> 0
                                                        end
                                                end),

                          WtAvgDocsLatency = Z2(<<Prefix/binary, "docs_latency_aggr">>,
                                                <<Prefix/binary, "docs_latency_wt">>,
                                                fun (Total, Count) ->
                                                        try Total / Count
                                                        catch error:badarith -> 0
                                                        end
                                                end),

                          PercentCompleteness = Z2(<<Prefix/binary, "docs_checked">>,
                                                   <<Prefix/binary, "changes_left">>,
                                                   fun (Checked, Left) ->
                                                           try (100 * Checked) / (Checked + Left)
                                                           catch error:badarith -> 0
                                                           end
                                                   end),

                          Utilization = Z2(<<Prefix/binary, "time_working_rate">>,
                                           <<Prefix/binary, "max_vbreps">>,
                                           fun (Rate, Max) ->
                                                   try 100 * Rate / Max
                                                   catch error:badarith -> 0
                                                   end
                                           end),

                          [{<<Prefix/binary, "wtavg_meta_latency">>, WtAvgMetaLatency},
                           {<<Prefix/binary, "wtavg_docs_latency">>, WtAvgDocsLatency},
                           {<<Prefix/binary, "percent_completeness">>, PercentCompleteness},
                           {<<Prefix/binary, "utilization">>, Utilization}]
                  end,
                  Reps)
        end,

    ViewsIndexesStats =
        [{Key, Z3(ViewKey, IndexKey, FtsKey, fun (A, B, C) -> A + B + C end)} ||
            {Key, ViewKey, IndexKey, FtsKey} <-
                [{<<"ep_dcp_views+indexes_count">>,
                  ep_dcp_views_count, ep_dcp_2i_count, ep_dcp_fts_count},
                 {<<"ep_dcp_views+indexes_items_remaining">>,
                  ep_dcp_views_items_remaining, ep_dcp_2i_items_remaining, ep_dcp_fts_items_remaining},
                 {<<"ep_dcp_views+indexes_producer_count">>,
                  ep_dcp_views_producer_count, ep_dcp_2i_producer_count, ep_dcp_fts_producer_count},
                 {<<"ep_dcp_views+indexes_total_backlog_size">>,
                  ep_dcp_views_total_backlog_size, ep_dcp_2i_total_backlog_size, ep_dcp_fts_total_backlog_size},
                 {<<"ep_dcp_views+indexes_items_sent">>,
                  ep_dcp_views_items_sent, ep_dcp_2i_items_sent, ep_dcp_fts_items_sent},
                 {<<"ep_dcp_views+indexes_total_bytes">>,
                  ep_dcp_views_total_bytes, ep_dcp_2i_total_bytes, ep_dcp_fts_total_bytes},
                 {<<"ep_dcp_views+indexes_backoff">>,
                  ep_dcp_views_backoff, ep_dcp_2i_backoff, ep_dcp_fts_backoff}]],

    [{<<"couch_total_disk_size">>, TotalDisk},
     {<<"couch_docs_fragmentation">>, DocsFragmentation},
     {<<"couch_views_fragmentation">>, ViewsFragmentation},
     {<<"hit_ratio">>, HitRatio},
     {<<"ep_cache_miss_rate">>, EPCacheMissRatio},
     {<<"ep_resident_items_rate">>, ResidentItemsRatio},
     {<<"vb_avg_active_queue_age">>, AvgActiveQueueAge},
     {<<"vb_avg_replica_queue_age">>, AvgReplicaQueueAge},
     {<<"vb_avg_pending_queue_age">>, AvgPendingQueueAge},
     {<<"vb_avg_total_queue_age">>, AvgTotalQueueAge},
     {<<"vb_active_resident_items_ratio">>, ActiveResRate},
     {<<"vb_replica_resident_items_ratio">>, ReplicaResRate},
     {<<"vb_pending_resident_items_ratio">>, PendingResRate},
     {<<"avg_disk_update_time">>, AverageDiskUpdateTime},
     {<<"avg_disk_commit_time">>, AverageCommitTime},
     {<<"avg_bg_wait_time">>, AverageBgWait},
     {<<"avg_active_timestamp_drift">>, AvgActiveTimestampDrift},
     {<<"avg_replica_timestamp_drift">>, AvgReplicaTimestampDrift}]
        ++ ViewsIndexesStats ++ XDCAllRepStats
        ++ computed_stats_lazy_proplist("@query").

combine_samples(Combiner, Dict, StatNames) ->
    case all_stats_defined(Dict, StatNames, []) of
        false ->
            undefined;
        Stats ->
            case length(Stats) of
                2 ->
                    combine_2_samples(Combiner, Stats);
                3 ->
                    combine_3_samples(Combiner, Stats)
            end
    end.

combine_2_samples(Combiner, [ValA, ValB]) ->
    lists:zipwith(
        fun (A, B) when A =/= null, B =/= null ->
                Combiner(A, B);
            (_, _) ->
                null
        end, ValA, ValB).

combine_3_samples(Combiner, [ValA, ValB, ValC]) ->
    lists:zipwith3(
        fun (A, B, C) when A =/= null, B =/= null, C =/= null ->
                Combiner(A, B, C);
            (_, _, _) ->
                null
        end, ValA, ValB, ValC).

all_stats_defined(_Dict, [], Acc) ->
    lists:reverse(Acc);
all_stats_defined(Dict, [First | Rest], Acc) ->
    case lists:keyfind(First, 1, Dict) of
        false ->
            false;
        {_, Val} ->
            all_stats_defined(Dict, Rest, [Val | Acc])
    end.

%% converts list of samples to proplist of stat values.
%%
%% null values should be uncommon, but they are not impossible. They
%% will be used for samples which lack some particular stat, for
%% example due to older membase version. I.e. when we upgrade we
%% sometimes add new kinds of stats and null values are used to mark
%% those past samples that don't have new stats gathered.
-spec samples_to_proplists([#stat_entry{}], list()) -> [{atom(), [null | number()]}].
samples_to_proplists([], _BucketName) -> [{timestamp, []}];
samples_to_proplists(Samples, BucketName) ->
    %% we're assuming that last sample has currently supported stats,
    %% that's why we are folding from backward and why we're ignoring
    %% other keys of other samples
    [LastSample | ReversedRest] = lists:reverse(Samples),
    InitialAcc0 = orddict:map(fun (_, V) -> [V] end, LastSample#stat_entry.values),
    InitialAcc = orddict:store(timestamp, [LastSample#stat_entry.timestamp], InitialAcc0),
    Dict = lists:foldl(fun (Sample, Acc) ->
                               orddict:map(fun (timestamp, AccValues) ->
                                                   [Sample#stat_entry.timestamp | AccValues];
                                               (K, AccValues) ->
                                                   case lists:keyfind(K, 1, Sample#stat_entry.values) of
                                                       {_, ThisValue} -> [ThisValue | AccValues];
                                                       _ -> [null | AccValues]
                                                   end
                                           end, Acc)
                       end, InitialAcc, ReversedRest),

    ExtraStats = lists:map(fun ({K, {F, StatNames}}) ->
                                   {K, combine_samples(F, Dict, StatNames)}
                           end, computed_stats_lazy_proplist(BucketName)),

    lists:filter(fun ({_, undefined}) -> false;
                     ({_, _}) -> true
                 end, ExtraStats)
        ++ orddict:to_list(Dict).

join_samples(A, B, Count) ->
    join_samples(lists:reverse(A), lists:reverse(B), [], Count).

join_samples([A | _] = ASamples, [B | TailB], Acc, Count) when A#stat_entry.timestamp < B#stat_entry.timestamp ->
    join_samples(ASamples, TailB, Acc, Count);
join_samples([A | TailA], [B | _] = BSamples, Acc, Count) when A#stat_entry.timestamp > B#stat_entry.timestamp ->
    join_samples(TailA, BSamples, Acc, Count);
join_samples(_, _, Acc, 0) ->
    Acc;
join_samples([A | TailA], [B | TailB], Acc, Count) ->
    NewAcc = [A#stat_entry{values = A#stat_entry.values ++ B#stat_entry.values} | Acc],
    join_samples(TailA, TailB, NewAcc, Count - 1);
join_samples(_, _, Acc, _) ->
    Acc.

join_samples_test() ->
    A = [
         {stat_entry, 1, [{key1, 1},
                          {key2, 2}]},
         {stat_entry, 2, [{key1, 3},
                          {key2, 4}]},
         {stat_entry, 3, [{key1, 5},
                          {key2, 6}]}],
    B = [
         {stat_entry, 2, [{key3, 1},
                          {key4, 2}]},
         {stat_entry, 3, [{key3, 3},
                          {key4, 4}]},
         {stat_entry, 4, [{key3, 5},
                          {key4, 6}]}],

    R1 = [
          {stat_entry, 2, [{key1, 3},
                           {key2, 4},
                           {key3, 1},
                           {key4, 2}]},
          {stat_entry, 3, [{key1, 5},
                           {key2, 6},
                           {key3, 3},
                           {key4, 4}]}],

    R2 = [
          {stat_entry, 2, [{key3, 1},
                           {key4, 2},
                           {key1, 3},
                           {key2, 4}]},
          {stat_entry, 3, [{key3, 3},
                           {key4, 4},
                           {key1, 5},
                           {key2, 6}]}],

    ?assertEqual(R1, join_samples(A, B, 2)),
    ?assertEqual(R2, join_samples(B, A, 2)),
    ?assertEqual(tl(R2), join_samples(B, A, 1)).


build_bucket_stats_ops_response(Nodes, BucketName, Params, WithSystemStats) ->
    {ClientTStamp, {Step, Period, Count} = Window} = parse_stats_params(Params),

    Samples = case WithSystemStats of
                  true ->
                      W1 = {Step, Period, Count + 1},
                      BucketRawSamples = grab_aggregate_op_stats(BucketName, Nodes, ClientTStamp, W1),
                      SystemRawSamples = grab_system_aggregate_op_stats(Nodes, ClientTStamp, W1),

                      %% this will throw out all samples with timestamps that are not present
                      %% in both BucketRawSamples and SystemRawSamples
                      join_samples(BucketRawSamples, SystemRawSamples, Count);
                  false ->
                      grab_aggregate_op_stats(BucketName, Nodes, ClientTStamp, Window)
              end,

    StatsPropList = samples_to_proplists(Samples, BucketName),

    [{op, {struct,
           [{samples, {struct, StatsPropList}},
            {samplesCount, Count},
            {isPersistent, is_persistent(BucketName)},
            {lastTStamp, case proplists:get_value(timestamp, StatsPropList) of
                             [] -> 0;
                             L -> lists:last(L)
                         end},
            {interval, Step * 1000}]}}].

is_safe_key_name(Name) ->
    lists:all(fun (C) ->
                      C >= 16#20 andalso C =< 16#7f
              end, Name).


build_bucket_stats_hks_response(BucketName) ->
    build_bucket_stats_hks_response(BucketName, all).

build_bucket_stats_hks_response(BucketName, all) ->
    handle_hot_keys_resp(hot_keys_keeper:bucket_hot_keys(BucketName));
build_bucket_stats_hks_response(BucketName, [Node]) ->
    handle_hot_keys_resp(hot_keys_keeper:bucket_hot_keys(BucketName, Node)).

handle_hot_keys_resp(Resp) ->
    BucketsTopKeys = case Resp of
                         undefined -> [];
                         X -> X
                     end,
    jsonify_hks(BucketsTopKeys).

jsonify_hks(BucketsTopKeys) ->
    HotKeyStructs = lists:map(fun ({Key, PList}) ->
                                      EscapedKey = case is_safe_key_name(Key) of
                                                       true -> Key;
                                                       _ -> "BIN_" ++ base64:encode_to_string(Key)
                                                   end,
                                      {struct, [{name, list_to_binary(EscapedKey)},
                                                {ops, proplists:get_value(ops, PList)}]}
                              end, BucketsTopKeys),
    [{hot_keys, HotKeyStructs}].

%% by default we aggregate stats between nodes using SUM
%% but in some cases other methods should be used
%% for example for couch_views_ops since view hits all the nodes
%% we use max to prevent the number of ops to be multiplied to the number of nodes
get_aggregate_method(Key) ->
    case Key of
        couch_views_ops ->
            max;
        cpu_utilization_rate ->
            max;
        <<"index_ram_percent">> ->
            max;
        <<"views/", S/binary>> ->
            case binary:match(S, <<"/accesses">>) of
                nomatch ->
                    sum;
                _ ->
                    max
            end;
        _ ->
            sum
    end.

aggregate_values(Key, AV, BV) ->
    case get_aggregate_method(Key) of
        sum ->
            try AV+BV
            catch error:badarith ->
                    case ([X || X <- [AV,BV],
                                X =/= undefined]) of
                        [] -> undefined;
                        [X|_] -> X
                    end
            end;
        max ->
            case {AV, BV} of
                {undefined, undefined} ->
                    undefined;
                {undefined, _} ->
                    BV;
                {_, undefined} ->
                    AV;
                _ ->
                    max(AV, BV)
            end
    end.

aggregate_stat_kv_pairs([], BPairs, Acc) ->
    lists:reverse(Acc, BPairs);
aggregate_stat_kv_pairs(APairs, [], Acc) ->
    lists:reverse(Acc, APairs);
aggregate_stat_kv_pairs([{AK, AV} = APair | ARest] = A,
                        [{BK, BV} = BPair | BRest] = B,
                        Acc) ->
    case AK of
        BK ->
            NewAcc = [{AK, aggregate_values(AK, AV, BV)} | Acc],
            aggregate_stat_kv_pairs(ARest, BRest, NewAcc);
        _ when AK < BK ->
            aggregate_stat_kv_pairs(ARest, B, [APair | Acc]);
        _ ->
            aggregate_stat_kv_pairs(A, BRest, [BPair | Acc])
    end.

aggregate_stat_kv_pairs_test() ->
    ?assertEqual([{a, 3}, {b, undefined}, {c, 1}, {d,1}, {e, 1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {b, undefined}, {d, undefined}, {e,1}],
                                         [])),
    ?assertEqual([{a, 3}, {b, undefined}, {ba, 123}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {b, undefined}, {ba, 123}],
                                         [])),
    ?assertEqual([{a, 3}, {b, undefined}, {c, 1}, {d,1}, {e, 1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {c,0}, {d, undefined}, {e,1}],
                                         [])),
    ?assertEqual([{couch_views_ops, 3},
                  {<<"views/A1/accesses">>, 4},
                  {<<"views/A1/blah">>, 3}],
                 aggregate_stat_kv_pairs([{couch_views_ops, 1},
                                          {<<"views/A1/accesses">>, 4},
                                          {<<"views/A1/blah">>, 1}],
                                         [{couch_views_ops, 3},
                                          {<<"views/A1/accesses">>, 2},
                                          {<<"views/A1/blah">>, 2}],
                                         [])).

aggregate_stat_entries(A, B) ->
    true = (B#stat_entry.timestamp =:= A#stat_entry.timestamp),
    NewValues = aggregate_stat_kv_pairs(A#stat_entry.values,
                                        B#stat_entry.values,
                                        []),
    A#stat_entry{values = NewValues}.

-define(SPACE_CHAR, 16#20).

simple_memoize(Key, Body, Expiration) ->
    menelaus_web_cache:lookup_or_compute_with_expiration(
      Key,
      fun () ->
              {Body(), Expiration, []}
      end,
      fun (_Key, _Value, []) ->
              false
      end).

couchbase_goxdcr_stats_descriptions(BucketId) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        true ->
            simple_memoize({stats_directory_goxdcr, BucketId},
                           fun () ->
                                   do_couchbase_goxdcr_stats_descriptions(BucketId)
                           end, 5000);
        false ->
            []
    end.

do_couchbase_goxdcr_stats_descriptions(BucketId) ->
    Reps = goxdcr_status_keeper:get_replications_with_remote_info(BucketId),
    lists:map(fun ({Id, RemoteClusterName, RemoteBucket}) ->
                      Prefix = <<"replications/", Id/binary,"/">>,

                      BlockName = io_lib:format("Outbound XDCR Operations to bucket ~p "
                                                "on remote cluster ~p",[RemoteBucket, RemoteClusterName]),

                      {struct,[{blockName, iolist_to_binary(BlockName)},
                               {extraCSSClasses,<<"dynamic_closed">>},
                               {stats,
                                [
                                 {struct,[{title,<<"mutations">>},
                                          {name,<<Prefix/binary,"changes_left">>},
                                          {desc,<<"Number of mutations to be replicated to other clusters "
                                                  "(measured from per-replication stat changes_left)">>}]},
                                 {struct,[{title,<<"percent completed">>},
                                          {maxY, 100},
                                          {name,<<Prefix/binary, "percent_completeness">>},
                                          {desc,<<"Percentage of checked items out of all checked and to-be-replicated items "
                                                  "(measured from per-replication stat percent_completeness)">>}]},
                                 {struct,[{title,<<"mutations replicated">>},
                                          {name,<<Prefix/binary,"docs_written">>},
                                          {desc,<<"Number of mutations that have been replicated to other clusters "
                                                  "(measured from per-replication stat docs_written)">>}]},
                                 {struct,[{title,<<"mutations filtered per sec.">>},
                                          {name,<<Prefix/binary,"docs_filtered">>},
                                          {desc,<<"Number of mutations per second that have been filtered out and have not been replicated to other clusters "
                                                  "(measured from per-replication stat docs_filtered)">>}]},
                                 {struct,[{title,<<"mutations skipped by resolution">>},
                                          {name,<<Prefix/binary,"docs_failed_cr_source">>},
                                          {desc,<<"Number of mutations that failed conflict resolution on the source side and hence have not been replicated to other clusters "
                                                  "(measured from per-replication stat docs_failed_cr_source)">>}]},
                                 {struct,[{title,<<"mutation replication rate">>},
                                          {name,<<Prefix/binary,"rate_replicated">>},
                                          {desc,<<"Rate of replication in terms of number of replicated mutations per second "
                                                  "(measured from per-replication stat rate_replicated)">>}]},
                                 {struct,[{isBytes,true},
                                          {title,<<"data replication rate">>},
                                          {name,<<Prefix/binary,"bandwidth_usage">>},
                                          {desc,<<"Rate of replication in terms of bytes replicated per second "
                                                  "(measured from per-replication stat bandwidth_usage)">>}]},
                                 {struct,[{title,<<"opt. replication rate">>},
                                          {name,<<Prefix/binary,"rate_doc_opt_repd">>},
                                          {desc,<<"Rate of optimistic replications in terms of number of replicated mutations per second ">>}]},
                                 {struct,[{title,<<"doc checks rate">>},
                                          {name,<<Prefix/binary,"rate_doc_checks">>},
                                          {desc,<<"Rate of doc checks per second ">>}]},
                                 {struct,[{title,<<"ms meta batch latency">>},
                                          {name,<<Prefix/binary, "wtavg_meta_latency">>},
                                          {desc,<<"Weighted average latency in ms of sending getMeta and waiting for conflict solution result from remote cluster "
                                                  "(measured from per-replication stat wtavg_meta_latency)">>}]},
                                 {struct,[{title,<<"ms doc batch latency">>},
                                          {name,<<Prefix/binary, "wtavg_docs_latency">>},
                                          {desc,<<"Weighted average latency in ms of sending replicated mutations to remote cluster "
                                                  "(measured from per-replication stat wtavg_docs_latency)">>}]},
                                 {struct,[{title,<<"doc reception rate">>},
                                          {name,<<Prefix/binary,"rate_received_from_dcp">>},
                                          {desc,<<"Rate of mutations received from dcp in terms of number of mutations per second ">>}]}]}]}
              end, Reps).


couchbase_replication_stats_descriptions(BucketId) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        true ->
            [];
        false ->
            simple_memoize({stats_directory_xdcr, BucketId},
                           fun () ->
                                   do_couchbase_replication_stats_descriptions(BucketId)
                           end, 5000)
    end.

do_couchbase_replication_stats_descriptions(BucketId) ->
    Reps = xdc_replication_sup:get_replications(list_to_binary(BucketId)),
    lists:map(fun ({Id, Pid}) ->
                      {ok, Targ} = xdc_replication:target(Pid),
                      Prefix = <<"replications/", Id/binary,"/">>,

                      {ok, {RemoteClusterUUID, RemoteBucket}} = remote_clusters_info:parse_remote_bucket_reference(Targ),
                      RemoteCluster = remote_clusters_info:find_cluster_by_uuid(RemoteClusterUUID),
                      RemoteClusterName = proplists:get_value(name, RemoteCluster),
                      BlockName = io_lib:format("Outbound XDCR Operations to bucket ~p "
                                                "on remote cluster ~p",[RemoteBucket, RemoteClusterName]),

                      {struct,[{blockName, iolist_to_binary(BlockName)},
                               {extraCSSClasses,<<"dynamic_closed">>},
                               {stats,
                                [%% first row
                                 {struct,[{title,<<"mutations">>},
                                          {name,<<Prefix/binary,"changes_left">>},
                                          {desc,<<"Number of mutations to be replicated to other clusters "
                                                  "(measured from per-replication stat changes_left)">>}]},
                                 {struct,[{title,<<"percent completed">>},
                                          {maxY, 100},
                                          {name,<<Prefix/binary, "percent_completeness">>},
                                          {desc,<<"Percentage of checked items out of all checked and to-be-replicated items "
                                                  "(measured from per-replication stat percent_completeness)">>}]},
                                 {struct,[{title,<<"active vb reps">>},
                                          {name,<<Prefix/binary,"active_vbreps">>},
                                          {desc,<<"Number of active vbucket replications "
                                                  "(measured from per-replication stat active_vbreps)">>}]},
                                 {struct,[{title,<<"waiting vb reps">>},
                                          {name,<<Prefix/binary,"waiting_vbreps">>},
                                          {desc,<<"Number of waiting vbucket replications "
                                                  "(measured from per-replication stat waiting_vbreps)">>}]},
                                 %% second row
                                 {struct,[{title,<<"mutation replication rate">>},
                                          {name,<<Prefix/binary,"rate_replication">>},
                                          {desc,<<"Rate of replication in terms of number of replicated mutations per second "
                                                  "(measured from per-replication stat rate_replication)">>}]},
                                 {struct,[{isBytes,true},
                                          {title,<<"data replication rate">>},
                                          {name,<<Prefix/binary,"bandwidth_usage">>},
                                          {desc,<<"Rate of replication in terms of bytes replicated per second "
                                                  "(measured from per-replication stat bandwidth_usage)">>}]},
                                 {struct,[{title,<<"opt. replication rate">>},
                                          {name,<<Prefix/binary,"rate_doc_opt_repd">>},
                                          {desc,<<"Rate of optimistic replications in terms of number of replicated mutations per second ">>}]},
                                 {struct,[{title,<<"doc checks rate">>},
                                          {name,<<Prefix/binary,"rate_doc_checks">>},
                                          {desc,<<"Rate of doc checks per second ">>}]},

                                 %% third row
                                 {struct,[{title,<<"meta batches per sec.">>},
                                          {name,<<Prefix/binary, "meta_latency_wt">>},
                                          {desc,<<"Weighted average latency in ms of sending getMeta and waiting for conflict solution result from remote cluster "
                                                  "(measured from per-replication stat wtavg_meta_latency)">>}]},
                                 {struct,[{title,<<"ms meta batch latency">>},
                                          {name,<<Prefix/binary, "wtavg_meta_latency">>},
                                          {desc,<<"Weighted average latency in ms of sending getMeta and waiting for conflict solution result from remote cluster "
                                                  "(measured from per-replication stat wtavg_meta_latency)">>}]},
                                 {struct,[{title,<<"docs batches per sec.">>},
                                          {name,<<Prefix/binary, "docs_latency_wt">>},
                                          {desc,<<"Weighted average latency in ms of sending replicated mutations to remote cluster "
                                                  "(measured from per-replication stat wtavg_docs_latency)">>}]},
                                 {struct,[{title,<<"ms doc batch latency">>},
                                          {name,<<Prefix/binary, "wtavg_docs_latency">>},
                                          {desc,<<"Weighted average latency in ms of sending replicated mutations to remote cluster "
                                                  "(measured from per-replication stat wtavg_docs_latency)">>}]},
                                 %% fourth row
                                 {struct, [{title, <<"wakeups per sec.">>},
                                           {name, <<Prefix/binary, "wakeups_rate">>},
                                           {desc, <<"Rate of XDCR vbucket replicator wakeups">>}]},
                                 {struct, [{title, <<"XDCR vb reps per sec.">>},
                                           {name, <<Prefix/binary, "worker_batches_rate">>},
                                           {desc, <<"Rate at which XDCR vbucket replicators replicates batches per second">>}]},
                                 {struct, [{title, <<"% time spent vb reps">>},
                                           {maxY, 100},
                                           {name, <<Prefix/binary, "utilization">>},
                                           {desc, <<"Percentage of time spent with vbucket replicators * 100 / (max_workers_count * <time passed since last sample>)">>}]}]}]}

              end, Reps).

couchbase_view_stats_descriptions(BucketId) ->
    simple_memoize({stats_directory_views, BucketId},
                   fun () ->
                           do_couchbase_view_stats_descriptions(BucketId)
                   end, 5000).

do_couchbase_view_stats_descriptions(BucketId) ->
    {MapReduceSignatures, SpatialSignatures} = ns_couchdb_api:get_design_doc_signatures(BucketId),
    do_couchbase_view_stats_descriptions(MapReduceSignatures, <<"views/">>, <<"Mapreduce View Stats">>) ++
        do_couchbase_view_stats_descriptions(SpatialSignatures, <<"spatial/">>, <<"Spatial View Stats">>).

do_couchbase_view_stats_descriptions(DictBySig, KeyPrefix, Title) ->
    dict:fold(
      fun(Sig, DDocIds0, Stats) ->
              Prefix = <<KeyPrefix/binary, Sig/binary,"/">>,
              DDocIds = lists:sort(DDocIds0),
              Ids = iolist_to_binary([hd(DDocIds) |
                                      [[?SPACE_CHAR | Id]
                                       || Id <- tl(DDocIds)]]),
              MyStats = {struct,[{blockName,<<Title/binary, ": ", Ids/binary>>},
                                 {extraCSSClasses,<<"dynamic_closed">>},
                                 {columns,
                                  [<<"Data">>,<<"Disk">>,<<"Read Ops">>]},
                                 {stats,
                                  [{struct,[{isBytes,true},
                                            {title,<<"data size">>},
                                            {name,<<Prefix/binary,"data_size">>},
                                            {desc,<<"How many bytes stored">>}]},
                                   {struct,[{isBytes,true},
                                            {title,<<"disk size">>},
                                            {name,<<Prefix/binary,"disk_size">>},
                                            {desc,<<"How much storage used">>}]},
                                   {struct,[{title,<<"view reads per sec.">>},
                                            {name,<<Prefix/binary,"accesses">>},
                                            {desc,<<"Traffic to the views in this design doc">>}]}
                                  ]}]},
              [MyStats|Stats]
      end, [], DictBySig).

couchbase_index_stats_descriptions(_, []) ->
    [];
couchbase_index_stats_descriptions(BucketId, IndexNodes) ->
    simple_memoize({stats_directory_index, BucketId, IndexNodes},
                   fun () ->
                           do_couchbase_index_stats_descriptions(BucketId, IndexNodes)
                   end, 5000).

do_couchbase_index_stats_descriptions(BucketId, IndexNodes) ->
    Nodes = case IndexNodes of
                all ->
                    section_nodes("@index-" ++ BucketId);
                XNodes ->
                    XNodes
            end,
    AllIndexes = do_get_indexes(indexer_gsi, BucketId, Nodes),
    [{struct, [{blockName, <<"Index Stats: ", Id/binary>>},
               {extraCSSClasses, <<"dynamic_closed">>},
               {stats,
                [{struct, [{title, <<"items scanned/sec">>},
                           {name, per_index_stat(Id, <<"num_rows_returned">>)},
                           {desc, <<"Number of index items scanned by the indexer per second">>}]},
                 {struct, [{isBytes, true},
                           {title, <<"disk size">>},
                           {name, per_index_stat(Id, <<"disk_size">>)},
                           {desc, <<"Total disk file size consumed by the index">>}]},
                 {struct, [{isBytes, true},
                           {title, <<"data size">>},
                           {name, per_index_stat(Id, <<"data_size">>)},
                           {desc, <<"Actual data size consumed by the index">>}]},
                 {struct, [{title, <<"total items remaining">>},
                           {name, per_index_stat(Id, <<"num_docs_pending+queued">>)},
                           {desc, <<"Number of documents pending to be indexed">>}]},
                 {struct, [{title, <<"drain rate items/sec">>},
                           {name, per_index_stat(Id, <<"num_docs_indexed">>)},
                           {desc, <<"Number of documents indexed by the indexer per second">>}]},
                 {struct, [{title, <<"total indexed items">>},
                           {name, per_index_stat(Id, <<"items_count">>)},
                           {desc, <<"Current total indexed document count">>}]},
                 {struct, [{isBytes, true},
                           {title, <<"average item size">>},
                           {name, per_index_stat(Id, <<"avg_item_size">>)},
                           {desc, <<"Average size of each index item">>}]},
                 {struct, [{title, <<"% fragmentation">>},
                           {name, per_index_stat(Id, <<"frag_percent">>)},
                           {desc, <<"Percentage fragmentation of the index. Note: at small index sizes of less than a hundred kB, the static overhead of the index disk file will inflate the index fragmentation percentage">>}]},
                 {struct, [{title, <<"requests/sec">>},
                           {name, per_index_stat(Id, <<"num_requests">>)},
                           {desc, <<"Number of requests served by the indexer per second">>}]},
                 {struct, [{title, <<"bytes returned/sec">>},
                           {name, per_index_stat(Id, <<"scan_bytes_read">>)},
                           {desc, <<"Number of bytes per second read by a scan">>}]},
                 {struct, [{title, <<"avg scan latency(ns)">>},
                           {name, per_index_stat(Id, <<"avg_scan_latency">>)},
                           {desc, <<"Average time to serve a scan request (nanoseconds)">>}]}]}]}
     || Id <- AllIndexes].

couchbase_fts_stats_descriptions(_, []) ->
    [];
couchbase_fts_stats_descriptions(BucketId, FtsNodes) ->
    simple_memoize({stats_directory_fts, BucketId, FtsNodes},
                   fun () ->
                           do_couchbase_fts_stats_descriptions(BucketId, FtsNodes)
                   end, 5000).

do_couchbase_fts_stats_descriptions(BucketId, FtsNodes) ->
    Nodes = case FtsNodes of
                all ->
                    section_nodes("@fts-" ++ BucketId);
                XNodes ->
                    XNodes
            end,
    AllIndexes = do_get_indexes(indexer_fts, BucketId, Nodes),
    [{struct, [{blockName, <<"Full Text Search Stats: ", Id/binary>>},
               {extraCSSClasses, <<"dynamic_closed">>},
               {stats,
                [{struct, [{title, <<"items">>},
                          {name, per_fts_stat(Id, <<"doc_count">>)},
                          {desc, <<"Number of documents">>}]},
                 {struct, [{title, <<"bytes indexed/sec">>},
                           {name, per_fts_stat(Id, <<"total_bytes_indexed">>)},
                           {desc, <<"Number of plain text bytes indexed per second">>}]},
                 {struct, [{title, <<"queries/sec">>},
                           {name, per_fts_stat(Id, <<"total_queries">>)},
                           {desc, <<"Number of queries per second">>}]},
                 {struct, [{title, <<"error queries/sec">>},
                           {name, per_fts_stat(Id, <<"total_queries_error">>)},
                           {desc, <<"Number of queries that resulted in errors per second. Includes timeouts.">>}]},
                 {struct, [{title, <<"items remaining">>},
                           {name, per_fts_stat(Id, <<"num_mutations_to_index">>)},
                           {desc, <<"Number of mutations not yet indexed">>}]},
                 {struct, [{title, <<"compactions/sec">>},
                           {name, per_fts_stat(Id, <<"total_compactions">>)},
                           {desc, <<"Number of pindex compactions completed per second">>}]},
                 {struct, [{title, <<"avg query latency(ms)">>},
                           {name, per_fts_stat(Id, <<"avg_queries_latency">>)},
                           {desc, <<"Average time to answer query">>}]},
                 {struct, [{title, <<"timeout queries/sec">>},
                           {name, per_fts_stat(Id, <<"total_queries_timeout">>)},
                           {desc, <<"Number of queries that timeout per second">>}]},
                 {struct, [{title, <<"items not persisted">>},
                           {name, per_fts_stat(Id, <<"num_recs_to_persist">>)},
                           {desc, <<"Number items indexed but not yet persisted to disk">>}]},
                 {struct, [{title, <<"pindexes actual">>},
                           {name, per_fts_stat(Id, <<"num_pindexes_actual">>)},
                           {desc, <<"Number of PIndexes">>}]},
                 {struct, [{title, <<"bytes returned/sec">>},
                           {name, per_fts_stat(Id, <<"total_bytes_query_results">>)},
                           {desc, <<"Number of bytes returned in results per second">>}]},
                 {struct, [{title, <<"slow queries/sec">>},
                           {name, per_fts_stat(Id, <<"total_queries_slow">>)},
                           {desc, <<"Number of slow queries per second">>}]},
                 {struct, [{isBytes, true},
                           {title, <<"disk size">>},
                           {name, per_fts_stat(Id, <<"num_bytes_used_disk">>)},
                           {desc, <<"Total disk file size used by the index">>}]},
                 {struct, [{title, <<"pindexes target">>},
                           {name, per_fts_stat(Id, <<"num_pindexes_target">>)},
                           {desc, <<"Number of PIndexes expected">>}]},
                 {struct, [{title, <<"term searchers/sec">>},
                           {name, per_fts_stat(Id, <<"total_term_searchers">>)},
                           {desc, <<"Number of term searchers started per second">>}]}]}]}
     || Id <- AllIndexes].

couchbase_query_stats_descriptions() ->
    [{struct, [{blockName, <<"Query">>},
               {extraCSSClasses, <<"dynamic_closed">>},
               {stats,
                [{struct, [{title, <<"requests/sec">>},
                           {name, <<"query_requests">>},
                           {desc, <<"Number of N1QL requests processed per second">>}]},
                 {struct, [{title, <<"selects/sec">>},
                           {name, <<"query_selects">>},
                           {desc, <<"Number of N1QL selects processed per second">>}]},
                 {struct, [{title, <<"request time(sec)">>},
                           {name, <<"query_avg_req_time">>},
                           {desc, <<"Average end-to-end time to process a query (in seconds)">>}]},
                 {struct, [{title, <<"service time(sec)">>},
                           {name, <<"query_avg_svc_time">>},
                           {desc, <<"Average time to execute a query (in seconds)">>}]},
                 {struct, [{title, <<"result size">>},
                           {name, <<"query_avg_response_size">>},
                           {desc, <<"Average size (in bytes) of the data returned by a query">>}]},
                 {struct, [{title, <<"errors">>},
                           {name, <<"query_errors">>},
                           {desc, <<"Number of N1QL errors returned per second">>}]},
                 {struct, [{title, <<"warnings">>},
                           {name, <<"query_warnings">>},
                           {desc, <<"Number of N1QL errors returned per second">>}]},
                 {struct, [{title, <<"result count">>},
                           {name, <<"query_avg_result_count">>},
                           {desc, <<"Average number of results (documents) returned by a query">>}]},
                 {struct, [{title, <<"queries > 250ms">>},
                           {name, <<"query_requests_250ms">>},
                           {desc, <<"Number of queries that take longer than 250 ms per second">>}]},
                 {struct, [{title, <<"queries > 500ms">>},
                           {name, <<"query_requests_500ms">>},
                           {desc, <<"Number of queries that take longer than 500 ms per second">>}]},
                 {struct, [{title, <<"queries > 1000ms">>},
                           {name, <<"query_requests_1000ms">>},
                           {desc, <<"Number of queries that take longer than 1000 ms per second">>}]},
                 {struct, [{title, <<"queries > 5000ms">>},
                           {name, <<"query_requests_5000ms">>},
                           {desc, <<"Number of queries that take longer than 5000 ms per second">>}]},
                 {struct, [{title, <<"invalid requests/sec">>},
                           {name, <<"query_invalid_requests">>},
                           {desc, <<"Number of requests for unsupported endpoints per second, specifically HTTP requests for all endpoints not supported by the query engine. For example, a request for http://localhost:8093/foo will be included. Potentially useful in identifying DOS attacks.">>}]}]}]}].

membase_query_stats_description(false) ->
    [];
membase_query_stats_description(true) ->
    [{struct,[{title,<<"N1QL queries/sec">>},
              {name, <<"query_requests">>},
              {desc, <<"Number of N1QL requests processed per second">>}]}].

membase_index_stats_description([]) ->
    [];
membase_index_stats_description(_) ->
    [{struct, [{isBytes, true},
               {title, <<"index data size">>},
               {name, global_index_stat(<<"data_size">>)},
               {desc, <<"Actual data size consumed by the index">>}]},
     {struct, [{title, <<"index disk size">>},
               {name, global_index_stat(<<"disk_size">>)},
               {desc, <<"Total disk file size consumed by the index">>},
               {isBytes, true}]},
     {struct, [{title, <<"index fragmentation %">>},
               {name, global_index_stat(<<"fragmentation">>)},
               {desc, <<"Percentage fragmentation of the index. Note: at small index sizes of less than a hundred kB, the static overhead of the index disk file will inflate the index fragmentation percentage">>}]},
     {struct, [{title, <<"index scanned/sec">>},
               {name, global_index_stat(<<"num_rows_returned">>)},
               {desc, <<"Number of index items scanned by the indexer per second">>}]}].
membase_fts_stats_description([]) ->
    [];
membase_fts_stats_description(_) ->
    [{struct, [{title, <<"fts bytes indexed/sec">>},
               {name, global_fts_stat(<<"total_bytes_indexed">>)},
               {desc, <<"Number of fts bytes indexed per second">>}]},
     {struct, [{title, <<"fts queries/sec">>},
               {name, global_fts_stat(<<"total_queries">>)},
               {desc, <<"Number of fts queries per second">>}]},
     {struct, [{isBytes,true},
               {title, <<"fts disk size">>},
               {name, global_fts_stat(<<"num_bytes_used_disk">>)},
               {desc, <<"Total fts disk file size for this bucket">>}]}].

membase_drift_stats_description() ->
    [{struct,[{title,<<"avg active drift/mutation">>},
              {name,<<"avg_active_timestamp_drift">>},
              {desc,<<"Average drift (in seconds) per mutation on active vBuckets">>}]},
     {struct,[{title,<<"avg replica drift/mutation">>},
              {name,<<"avg_replica_timestamp_drift">>},
              {desc,<<"Average drift (in seconds) per mutation on replica vBuckets">>}]},
     {struct,[{title,<<"active ahead exceptions/sec">>},
              {name,<<"ep_active_ahead_exceptions">>},
              {desc,<<"Total number of ahead exceptions for  all active vBuckets">>}]},
     {struct,[{title,<<"replica ahead exceptions/sec">>},
              {name,<<"ep_replica_ahead_exceptions">>},
              {desc,<<"Total number of ahead exceptions for all replica vBuckets">>}]}].

membase_stats_description(BucketId, AddQuery, IndexNodes, FtsNodes) ->
    [{struct,[{blockName,<<"Summary">>},
              {stats,
               [{struct,[{title,<<"ops per second">>},
                         {name,<<"ops">>},
                         {desc,<<"Total amount of operations per second to this bucket (measured from cmd_get + cmd_set + incr_misses + incr_hits + decr_misses + decr_hits + delete_misses + delete_hits)">>},
                         {default,true}]},
                {struct,[{title,<<"cache miss ratio">>},
                         {name,<<"ep_cache_miss_rate">>},
                         {desc,<<"Percentage of reads per second to this bucket from disk as opposed to RAM (measured from ep_bg_fetches / gets * 100)">>},
                         {maxY,100}]},
                {struct,[{title,<<"gets per sec.">>},
                         {name,<<"cmd_get">>},
                         {desc,<<"Number of reads (get operations) per second from this bucket (measured from cmd_get)">>}]},
                {struct,[{title,<<"sets per sec.">>},
                         {name,<<"cmd_set">>},
                         {desc,<<"Number of writes (set operations) per second to this bucket (measured from cmd_set)">>}]},
                {struct,[{title,<<"deletes per sec.">>},
                         {name,<<"delete_hits">>},
                         {desc,<<"Number of delete operations per second for this bucket (measured from delete_hits)">>}]},
                {struct,[{title,<<"CAS ops per sec.">>},
                         {name,<<"cas_hits">>},
                         {desc,<<"Number of operations with a CAS id per second for this bucket (measured from cas_hits)">>}]},
                {struct,[{title,<<"active docs resident %">>},
                         {name,<<"vb_active_resident_items_ratio">>},
                         {desc,<<"Percentage of active items cached in RAM in this bucket (measured from vb_active_resident_items_ratio)">>},
                         {maxY,100}]},
                {struct,[{title,<<"items">>},
                         {name,<<"curr_items">>},
                         {desc,<<"Number of unique items in this bucket - only active items, not replica (measured from curr_items)">>}]},
                {struct,[{title,<<"temp OOM per sec.">>},
                         {name,<<"ep_tmp_oom_errors">>},
                         {desc,<<"Number of back-offs sent per second to client SDKs due to \"out of memory\" situations from this bucket (measured from ep_tmp_oom_errors)">>}]},
                {struct, [{isBytes,true},
                          {title, <<"low water mark">>},
                          {name, <<"ep_mem_low_wat">>},
                          {desc, <<"Low water mark for auto-evictions (measured from ep_mem_low_wat)">>}]},
                {struct, [{isBytes,true},
                          {title, <<"high water mark">>},
                          {name, <<"ep_mem_high_wat">>},
                          {desc, <<"High water mark for auto-evictions (measured from ep_mem_high_wat)">>}]},
                {struct, [{isBytes,true},
                          {title, <<"memory used">>},
                          {name, <<"mem_used">>},
                          {desc, <<"Memory used as measured from mem_used">>}]},
                {struct,[{title,<<"disk creates per sec.">>},
                         {name,<<"ep_ops_create">>},
                         {desc,<<"Number of new items created on disk per second for this bucket (measured from vb_active_ops_create + vb_replica_ops_create + vb_pending_ops_create)">>}]},
                {struct,[{title,<<"disk updates per sec.">>},
                         {name,<<"ep_ops_update">>},
                         {desc,<<"Number of items updated on disk per second for this bucket (measured from vb_active_ops_update + vb_replica_ops_update + vb_pending_ops_update)">>}]},
                {struct,[{title,<<"disk reads per sec.">>},
                         {name,<<"ep_bg_fetched">>},
                         {desc,<<"Number of reads per second from disk for this bucket (measured from ep_bg_fetched)">>}]},
                {struct,[{title,<<"disk write queue">>},
                         {name,<<"disk_write_queue">>},
                         {desc,<<"Number of items waiting to be written to disk in this bucket (measured from ep_queue_size+ep_flusher_todo)">>}]},
                {struct,[{isBytes,true},
                         {name,<<"couch_docs_data_size">>},
                         {title,<<"docs data size">>},
                         {desc,<<"The size of active data in this bucket "
                                 "(measured from couch_docs_data_size)">>}]},
                {struct,[{isBytes, true},
                         {name,<<"couch_docs_actual_disk_size">>},
                         {title,<<"docs total disk size">>},
                         {desc,<<"The size of all data files for this bucket, including the data itself, meta data and temporary files "
                                 "(measured from couch_docs_actual_disk_size)">>}]},
                {struct,[{name,<<"couch_docs_fragmentation">>},
                         {title,<<"docs fragmentation %">>},
                         {desc,<<"How much fragmented data there is to be compacted compared to real data for the data files in this bucket "
                                 "(measured from couch_docs_fragmentation)">>}]},
                {struct,[{isBytes,true},
                         {name,<<"couch_total_disk_size">>},
                         {title,<<"total disk size">>},
                         {desc,<<"The total size on disk of all data and view files for this bucket."
                                 "(measured from couch_total_disk_size)">>}]},
                {struct,[{isBytes,true},
                         {name,<<"couch_views_data_size">>},
                         {title,<<"views data size">>},
                         {desc,<<"The size of active data on for all the indexes in this bucket"
                                 "(measured from couch_views_data_size)">>}]},
                {struct,[{isBytes,true},
                         {name,<<"couch_views_actual_disk_size">>},
                         {title,<<"views total disk size">>},
                         {desc,<<"The size of all active items in all the indexes for this bucket on disk"
                                 "(measured from couch_views_actual_disk_size)">>}]},
                {struct,[{name,<<"couch_views_fragmentation">>},
                         {title,<<"views fragmentation %">>},
                         {desc,<<"How much fragmented data there is to be compacted compared to real data for the view index files in this bucket"
                                 "(measured from couch_views_fragmentation)">>}]},
                {struct,[{name,<<"couch_views_ops">>},
                         {title,<<"view reads per sec.">>},
                         {desc,<<"All the view reads for all design documents including scatter gather."
                                 "(measured from couch_views_ops)">>}]},
                {struct, [{title, <<"disk update time">>},
                          {name, <<"avg_disk_update_time">>},
                          {hidden, true},
                          {desc, <<"Average disk update time in microseconds as from disk_update histogram of timings"
                                   "(measured from avg_disk_update_time)">>}]},
                {struct, [{title, <<"disk commit time">>},
                          {name, <<"avg_disk_commit_time">>},
                          {hidden, true},
                          {desc, <<"Average disk commit time in seconds as from disk_update histogram of timings"
                                   "(measured from avg_disk_commit_time)">>}]},
                {struct, [{title, <<"bg wait time">>},
                          {hidden, true},
                          {name, <<"avg_bg_wait_time">>},
                          {desc, <<"Average background fetch time in microseconds"
                                   "(measured from avg_bg_wait_time)">>}]},
                {struct,[{title,<<"incoming XDCR ops/sec.">>},
                         {name,<<"xdc_ops">>},
                         {desc,<<"Incoming XDCR operations per second for this bucket "
                                 "(measured from xdc_ops)">>}]},
                {struct,[{title,<<"intra-replication queue">>},
                         {name,<<"ep_dcp_replica_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to consumer in this bucket (measured from ep_dcp_replica_items_remaining)">>}]}
                | (case display_outbound_xdcr_mutations(BucketId) of
                       true ->
                           [{struct,[{title,<<"outbound XDCR mutations">>},
                                     {name,<<"replication_changes_left">>},
                                     {desc,<<"Number of mutations to be replicated to other clusters"
                                             "(measured from replication_changes_left)">>}]}];
                       false ->
                           []
                   end ++
                       membase_query_stats_description(AddQuery) ++
                       membase_index_stats_description(IndexNodes) ++
                       membase_fts_stats_description(FtsNodes) ++
                       membase_drift_stats_description()
                  )]}]},
    {struct,[{blockName,<<"vBucket Resources">>},
              {extraCSSClasses,<<"dynamic_withtotal dynamic_closed">>},
              {columns,
               [<<"Active">>,<<"Replica">>,<<"Pending">>,<<"Total">>]},
              {stats,
               [{struct,[{title,<<"vBuckets">>},
                         {name,<<"vb_active_num">>},
                         {desc,<<"Number of vBuckets in the \"active\" state for this bucket (measured from vb_active_num)">>}]},
                {struct,[{title,<<"vBuckets">>},
                         {name,<<"vb_replica_num">>},
                         {desc,<<"Number of vBuckets in the \"replica\" state for this bucket (measured from vb_replica_num)">>}]},
                {struct,[{title,<<"vBuckets">>},
                         {name,<<"vb_pending_num">>},
                         {desc,<<"Number of vBuckets in the \"pending\" state for this bucket and should be transient during rebalancing (measured from vb_pending_num)">>}]},
                {struct,[{title,<<"vBuckets">>},
                         {name,<<"ep_vb_total">>},
                         {desc,<<"Total number of vBuckets for this bucket (measured from ep_vb_total)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"curr_items">>},
                         {desc,<<"Number of items in \"active\" vBuckets in this bucket (measured from curr_items)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"vb_replica_curr_items">>},
                         {desc,<<"Number of items in \"replica\" vBuckets in this bucket (measured from vb_replica_curr_items)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"vb_pending_curr_items">>},
                         {desc,<<"Number of items in \"pending\" vBuckets in this bucket and should be transient during rebalancing (measured from vb_pending_curr_items)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"curr_items_tot">>},
                         {desc,<<"Total number of items in this bucket (measured from curr_items_tot)">>}]},
                {struct,[{title,<<"resident %">>},
                         {name,<<"vb_active_resident_items_ratio">>},
                         {desc,<<"Percentage of active items cached in RAM in this bucket (measured from vb_active_resident_items_ratio)">>},
                         {maxY,100}]},
                {struct,[{title,<<"resident %">>},
                         {name,<<"vb_replica_resident_items_ratio">>},
                         {desc,<<"Percentage of replica items cached in RAM in this bucket (measured from vb_replica_resident_items_ratio)">>},
                         {maxY,100}]},
                {struct,[{title,<<"resident %">>},
                         {name,<<"vb_pending_resident_items_ratio">>},
                         {desc,<<"Percentage of items in pending state vbuckets cached in RAM in this bucket (measured from vb_pending_resident_items_ratio)">>},
                         {maxY,100}]},
                {struct,[{title,<<"resident %">>},
                         {name,<<"ep_resident_items_rate">>},
                         {desc,<<"Percentage of all items cached in RAM in this bucket (measured from ep_resident_items_rate)">>},
                         {maxY,100}]},
                {struct,[{title,<<"new items per sec.">>},
                         {name,<<"vb_active_ops_create">>},
                         {desc,<<"New items per second being inserted into \"active\" vBuckets in this bucket (measured from vb_active_ops_create)">>}]},
                {struct,[{title,<<"new items per sec.">>},
                         {name,<<"vb_replica_ops_create">>},
                         {desc,<<"New items per second being inserted into \"replica\" vBuckets in this bucket (measured from vb_replica_ops_create">>}]},
                {struct,[{title,<<"new items per sec.">>},
                         {name,<<"vb_pending_ops_create">>},
                         {desc,<<"New items per second being instead into \"pending\" vBuckets in this bucket and should be transient during rebalancing (measured from vb_pending_ops_create)">>}]},
                {struct,[{title,<<"new items per sec.">>},
                         {name,<<"ep_ops_create">>},
                         {desc,<<"Total number of new items being inserted into this bucket (measured from ep_ops_create)">>}]},
                {struct,[{title,<<"ejections per sec.">>},
                         {name,<<"vb_active_eject">>},
                         {desc,<<"Number of items per second being ejected to disk from \"active\" vBuckets in this bucket (measured from vb_active_eject)">>}]},
                {struct,[{title,<<"ejections per sec.">>},
                         {name,<<"vb_replica_eject">>},
                         {desc,<<"Number of items per second being ejected to disk from \"replica\" vBuckets in this bucket (measured from vb_replica_eject)">>}]},
                {struct,[{title,<<"ejections per sec.">>},
                         {name,<<"vb_pending_eject">>},
                         {desc,<<"Number of items per second being ejected to disk from \"pending\" vBuckets in this bucket and should be transient during rebalancing (measured from vb_pending_eject)">>}]},
                {struct,[{title,<<"ejections per sec.">>},
                         {name,<<"ep_num_value_ejects">>},
                         {desc,<<"Total number of items per second being ejected to disk in this bucket (measured from ep_num_value_ejects)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"user data in RAM">>},
                         {name,<<"vb_active_itm_memory">>},
                         {desc,<<"Amount of active user data cached in RAM in this bucket (measured from vb_active_itm_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"user data in RAM">>},
                         {name,<<"vb_replica_itm_memory">>},
                         {desc,<<"Amount of replica user data cached in RAM in this bucket (measured from vb_replica_itm_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"user data in RAM">>},
                         {name,<<"vb_pending_itm_memory">>},
                         {desc,<<"Amount of pending user data cached in RAM in this bucket and should be transient during rebalancing (measured from vb_pending_itm_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"user data in RAM">>},
                         {name,<<"ep_kv_size">>},
                         {desc,<<"Total amount of user data cached in RAM in this bucket (measured from ep_kv_size)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"metadata in RAM">>},
                         {name,<<"vb_active_meta_data_memory">>},
                         {desc,<<"Amount of active item metadata consuming RAM in this bucket (measured from vb_active_meta_data_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"metadata in RAM">>},
                         {name,<<"vb_replica_meta_data_memory">>},
                         {desc,<<"Amount of replica item metadata consuming in RAM in this bucket (measured from vb_replica_meta_data_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"metadata in RAM">>},
                         {name,<<"vb_pending_meta_data_memory">>},
                         {desc,<<"Amount of pending item metadata consuming RAM in this bucket and should be transient during rebalancing (measured from vb_pending_meta_data_memory)">>}]},
                {struct,[{isBytes,true},
                         {title,<<"metadata in RAM">>},
                         {name,<<"ep_meta_data_memory">>},
                         {desc,<<"Total amount of item  metadata consuming RAM in this bucket (measured from ep_meta_data_memory)">>}]}]}]},
     {struct,[{blockName,<<"Disk Queues">>},
              {extraCSSClasses,<<"dynamic_withtotal dynamic_closed">>},
              {columns,
               [<<"Active">>,<<"Replica">>,<<"Pending">>,<<"Total">>]},
              {stats,
               [{struct,[{title,<<"items">>},
                         {name,<<"vb_active_queue_size">>},
                         {desc,<<"Number of active items waiting to be written to disk in this bucket (measured from vb_active_queue_size)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"vb_replica_queue_size">>},
                         {desc,<<"Number of replica items waiting to be written to disk in this bucket (measured from vb_replica_queue_size)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"vb_pending_queue_size">>},
                         {desc,<<"Number of pending items waiting to be written to disk in this bucket and should be transient during rebalancing  (measured from vb_pending_queue_size)">>}]},
                {struct,[{title,<<"items">>},
                         {name,<<"ep_diskqueue_items">>},
                         {desc,<<"Total number of items waiting to be written to disk in this bucket (measured from ep_diskqueue_items)">>}]},
                {struct,[{title,<<"fill rate">>},
                         {name,<<"vb_active_queue_fill">>},
                         {desc,<<"Number of active items per second being put on the active item disk queue in this bucket (measured from vb_active_queue_fill)">>}]},
                {struct,[{title,<<"fill rate">>},
                         {name,<<"vb_replica_queue_fill">>},
                         {desc,<<"Number of replica items per second being put on the replica item disk queue in this bucket (measured from vb_replica_queue_fill)">>}]},
                {struct,[{title,<<"fill rate">>},
                         {name,<<"vb_pending_queue_fill">>},
                         {desc,<<"Number of pending items per second being put on the pending item disk queue in this bucket and should be transient during rebalancing (measured from vb_pending_queue_fill)">>}]},
                {struct,[{title,<<"fill rate">>},
                         {name,<<"ep_diskqueue_fill">>},
                         {desc,<<"Total number of items per second being put on the disk queue in this bucket (measured from ep_diskqueue_fill)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"vb_active_queue_drain">>},
                         {desc,<<"Number of active items per second being written to disk in this bucket (measured from vb_active_queue_drain)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"vb_replica_queue_drain">>},
                         {desc,<<"Number of replica items per second being written to disk in this bucket (measured from vb_replica_queue_drain)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"vb_pending_queue_drain">>},
                         {desc,<<"Number of pending items per second being written to disk in this bucket and should be transient during rebalancing (measured from vb_pending_queue_drain)">>}]},
                {struct,[{title,<<"drain rate">>},
                         {name,<<"ep_diskqueue_drain">>},
                         {desc,<<"Total number of items per second being written to disk in this bucket (measured from ep_diskqueue_drain)">>}]},
                {struct,[{title,<<"average age">>},
                         {name,<<"vb_avg_active_queue_age">>},
                         {desc,<<"Average age in seconds of active items in the active item queue for this bucket (measured from vb_avg_active_queue_age)">>}]},
                {struct,[{title,<<"average age">>},
                         {name,<<"vb_avg_replica_queue_age">>},
                         {desc,<<"Average age in seconds of replica items in the replica item queue for this bucket (measured from vb_avg_replica_queue_age)">>}]},
                {struct,[{title,<<"average age">>},
                         {name,<<"vb_avg_pending_queue_age">>},
                         {desc,<<"Average age in seconds of pending items in the pending item queue for this bucket and should be transient during rebalancing (measured from vb_avg_pending_queue_age)">>}]},
                {struct,[{title,<<"average age">>},
                         {name,<<"vb_avg_total_queue_age">>},
                         {desc,<<"Average age in seconds of all items in the disk write queue for this bucket (measured from vb_avg_total_queue_age)">>}]}]}]},
     {struct,[{blockName,<<"DCP Queues">>},
              {extraCSSClasses,<<"dynamic_closed">>},
              {columns,
               [<<"Replication">>,<<"XDCR">>,<<"Views/Indexes">>,<<"Other">>]},
              {stats,
               [{struct,[{title,<<"DCP connections">>},
                         {name,<<"ep_dcp_replica_count">>},
                         {desc,<<"Number of internal replication DCP connections in this bucket (measured from ep_dcp_replica_count)">>}]},
                {struct,[{title,<<"DCP connections">>},
                         {name,<<"ep_dcp_xdcr_count">>},
                         {desc,<<"Number of internal xdcr DCP connections in this bucket (measured from ep_dcp_xdcr_count)">>}]},
                {struct,[{title,<<"DCP connections">>},
                         {name,<<"ep_dcp_views+indexes_count">>},
                         {desc,<<"Number of internal views/indexes DCP connections in this bucket (measured from ep_dcp_views_count + ep_dcp_2i_count + ep_dcp_fts_count)">>}]},
                {struct,[{title,<<"DCP connections">>},
                         {name,<<"ep_dcp_other_count">>},
                         {desc,<<"Number of other DCP connections in this bucket (measured from ep_dcp_other_count)">>}]},
                {struct,[{title,<<"DCP senders">>},
                         {name,<<"ep_dcp_replica_producer_count">>},
                         {desc,<<"Number of replication senders for this bucket (measured from ep_dcp_replica_producer_count)">>}]},
                {struct,[{title,<<"DCP senders">>},
                         {name,<<"ep_dcp_xdcr_producer_count">>},
                         {desc,<<"Number of xdcr senders for this bucket (measured from ep_dcp_xdcr_producer_count)">>}]},
                {struct,[{title,<<"DCP senders">>},
                         {name,<<"ep_dcp_views+indexes_producer_count">>},
                         {desc,<<"Number of views/indexes senders for this bucket (measured from ep_dcp_views_producer_count + ep_dcp_2i_producer_count + ep_dcp_fts_producer_count)">>}]},
                {struct,[{title,<<"DCP senders">>},
                         {name,<<"ep_dcp_other_producer_count">>},
                         {desc,<<"Number of other senders for this bucket (measured from ep_dcp_other_producer_count)">>}]},
                {struct,[{title,<<"items remaining">>},
                         {name,<<"ep_dcp_replica_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to consumer in this bucket (measured from ep_dcp_replica_items_remaining)">>}]},
                {struct,[{title,<<"items remaining">>},
                         {name,<<"ep_dcp_xdcr_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to consumer in this bucket (measured from ep_dcp_xdcr_items_remaining)">>}]},
                {struct,[{title,<<"items remaining">>},
                         {name,<<"ep_dcp_views+indexes_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to consumer in this bucket (measured from ep_dcp_views_items_remaining + ep_dcp_2i_items_remaining + ep_dcp_fts_items_remaining)">>}]},
                {struct,[{title,<<"items remaining">>},
                         {name,<<"ep_dcp_other_items_remaining">>},
                         {desc,<<"Number of items remaining to be sent to consumer in this bucket (measured from ep_dcp_other_items_remaining)">>}]},
                {struct,[{title,<<"drain rate items/sec">>},
                         {name,<<"ep_dcp_replica_items_sent">>},
                         {desc,<<"Number of items per second being sent for a producer for this bucket (measured from ep_dcp_replica_items_sent)">>}]},
                {struct,[{title,<<"drain rate items/sec">>},
                         {name,<<"ep_dcp_xdcr_items_sent">>},
                         {desc,<<"Number of items per second being sent for a producer for this bucket (measured from ep_dcp_xdcr_items_sent)">>}]},
                {struct,[{title,<<"drain rate items/sec">>},
                         {name,<<"ep_dcp_views+indexes_items_sent">>},
                         {desc,<<"Number of items per second being sent for a producer for this bucket (measured from ep_dcp_views_items_sent + ep_dcp_2i_items_sent + ep_dcp_fts_items_sent)">>}]},
                {struct,[{title,<<"drain rate items/sec">>},
                         {name,<<"ep_dcp_other_items_sent">>},
                         {desc,<<"Number of items per second being sent for a producer for this bucket (measured from ep_dcp_other_items_sent)">>}]},
                {struct,[{title,<<"drain rate bytes/sec">>},
                         {name,<<"ep_dcp_replica_total_bytes">>},
                         {desc,<<"Number of bytes per second being sent for replication DCP connections for this bucket (measured from ep_dcp_replica_total_bytes)">>}]},
                {struct,[{title,<<"drain rate bytes/sec">>},
                         {name,<<"ep_dcp_xdcr_total_bytes">>},
                         {desc,<<"Number of bytes per second being sent for xdcr DCP connections for this bucket (measured from ep_dcp_xdcr_total_bytes)">>}]},
                {struct,[{title,<<"drain rate bytes/sec">>},
                         {name,<<"ep_dcp_views+indexes_total_bytes">>},
                         {desc,<<"Number of bytes per second being sent for views/indexes DCP connections for this bucket (measured from ep_dcp_views_total_bytes + ep_dcp_2i_total_bytes + ep_dcp_fts_total_bytes)">>}]},
                {struct,[{title,<<"drain rate bytes/sec">>},
                         {name,<<"ep_dcp_other_total_bytes">>},
                         {desc,<<"Number of bytes per second being sent for other DCP connections for this bucket (measured from ep_dcp_other_total_bytes)">>}]},
                {struct, [{title, <<"backoffs/sec">>},
                          {name, <<"ep_dcp_replica_backoff">>},
                          {desc,<<"Number of backoffs for replication DCP connections">>}]},
                {struct, [{title, <<"backoffs/sec">>},
                          {name, <<"ep_dcp_xdcr_backoff">>},
                          {desc,<<"Number of backoffs for xdcr DCP connections">>}]},
                {struct, [{title, <<"backoffs/sec">>},
                          {name, <<"ep_dcp_views+indexes_backoff">>},
                          {desc,<<"Number of backoffs for views/indexes DCP connections (measured from ep_dcp_views_backoff + ep_dcp_2i_backoff + ep_dcp_fts_backoff)">>}]},
                {struct, [{title, <<"backoffs/sec">>},
                          {name, <<"ep_dcp_other_backoff">>},
                          {desc,<<"Number of backoffs for other DCP connections">>}]}
               ]}]}]
        ++ couchbase_view_stats_descriptions(BucketId)
        ++ couchbase_index_stats_descriptions(BucketId, IndexNodes)
        ++ couchbase_fts_stats_descriptions(BucketId, FtsNodes)
        ++ couchbase_replication_stats_descriptions(BucketId)
        ++ couchbase_goxdcr_stats_descriptions(BucketId)
        ++ case AddQuery of
               true -> couchbase_query_stats_descriptions();
               false -> []
           end
        ++ [{struct,[{blockName,<<"Incoming XDCR Operations">>},
                     {bigTitlePrefix, <<"Incoming XDCR">>},
                     {extraCSSClasses,<<"dynamic_closed">>},
                     {stats,
                      [{struct,[{title,<<"metadata reads per sec.">>},
                                {bigTitle,<<"Incoming XDCR metadata reads per sec.">>},
                                {name,<<"ep_num_ops_get_meta">>},
                                {desc,<<"Number of metadata read operations per second for this bucket as the target for XDCR "
                                        "(measured from ep_num_ops_get_meta)">>}]},
                       {struct,[{title,<<"sets per sec.">>},
                                {name,<<"ep_num_ops_set_meta">>},
                                {desc,<<"Number of set operations per second for this bucket as the target for XDCR"
                                        "(measured from ep_num_ops_set_meta)">>}]},
                       {struct,[{title,<<"deletes per sec.">>},
                                {name,<<"ep_num_ops_del_meta">>},
                                {desc,<<"Number of delete operations per second for this bucket as the target for XDCR "
                                        "(measured from ep_num_ops_del_meta)">>}]},
                       {struct,[{title,<<"total ops per sec.">>},
                                {bigTitle, <<"Incoming XDCR total ops/sec.">>},
                                {name,<<"xdc_ops">>},
                                {desc,<<"Total XDCR operations per second for this bucket "
                                        "(measured from ep_num_ops_del_meta + ep_num_ops_get_meta + ep_num_ops_set_meta)">>}]}]}]}].

display_outbound_xdcr_mutations(BucketID) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        true ->
            goxdcr_status_keeper:get_replications(BucketID) =/= [];
        false ->
            true
    end.

memcached_stats_description() ->
    [{struct,[{blockName,<<"Memcached">>},
              {stats,
               [{struct,[{name,<<"ops">>},
                         {title,<<"ops per sec.">>},
                         {default,true},
                         {desc,<<"Total operations per second serviced by this bucket (measured from cmd_get + cmd_set + incr_misses + incr_hits + decr_misses + decr_hits + delete_misses + delete_hits + get_meta + set_meta + delete_meta)">>}]},
                {struct,[{name,<<"hit_ratio">>},
                         {title,<<"hit ratio">>},
                         {maxY,100},
                         {desc,<<"Percentage of get requests served with data from this bucket (measured from get_hits * 100/cmd_get)">>}]},
                {struct,[{isBytes,true},
                         {name,<<"mem_used">>},
                         {title,<<"RAM used">>},
                         {desc,<<"Total amount of RAM used by this bucket (measured from mem_used)">>}]},
                {struct,[{name,<<"curr_items">>},
                         {title,<<"items">>},
                         {desc,<<"Number of items stored in this bucket (measured from curr_items)">>}]},
                {struct,[{name,<<"evictions">>},
                         {title,<<"evictions per sec.">>},
                         {desc,<<"Number of items per second evicted from this bucket (measured from evictions)">>}]},
                {struct,[{name,<<"cmd_set">>},
                         {title,<<"sets per sec.">>},
                         {desc,<<"Number of set operations serviced by this bucket (measured from cmd_set)">>}]},
                {struct,[{name,<<"cmd_get">>},
                         {title,<<"gets per sec.">>},
                         {desc,<<"Number of get operations serviced by this bucket (measured from cmd_get)">>}]},
                {struct,[{name,<<"bytes_written">>},
                         {title,<<"bytes TX per sec.">>},
                         {desc,<<"Number of bytes per second sent from this bucket (measured from bytes_written)">>}]},
                {struct,[{name,<<"bytes_read">>},
                         {title,<<"bytes RX per sec.">>},
                         {desc,<<"Number of bytes per second sent into this bucket (measured from bytes_read)">>}]},
                {struct,[{name,<<"get_hits">>},
                         {title,<<"get hits per sec.">>},
                         {desc,<<"Number of get operations per second for data that this bucket contains (measured from get_hits)">>}]},
                {struct,[{name,<<"delete_hits">>},
                         {title,<<"delete hits per sec.">>},
                         {desc,<<"Number of delete operations per second for data that this bucket contains (measured from delete_hits)">>}]},
                {struct,[{name,<<"incr_hits">>},
                         {title,<<"incr hits per sec.">>},
                         {desc,<<"Number of increment operations per second for data that this bucket contains (measured from incr_hits)">>}]},
                {struct,[{name,<<"decr_hits">>},
                         {title,<<"decr hits per sec.">>},
                         {desc,<<"Number of decrement operations per second for data that this bucket contains (measured from decr_hits)">>}]},
                {struct,[{name,<<"delete_misses">>},
                         {title,<<"delete misses per sec.">>},
                         {desc,<<"Number of delete operations per second for data that this bucket does not contain (measured from delete_misses)">>}]},
                {struct,[{name,<<"decr_misses">>},
                         {title,<<"decr misses per sec.">>},
                         {desc,<<"Number of decr operations per second for data that this bucket does not contain (measured from decr_misses)">>}]},
                {struct,[{name,<<"get_misses">>},
                         {title,<<"get misses per sec.">>},
                         {desc,<<"Number of get operations per second for data that this bucket does not contain (measured from get_misses)">>}]},
                {struct,[{name,<<"incr_misses">>},
                         {title,<<"incr misses per sec.">>},
                         {desc,<<"Number of increment operations per second for data that this bucket does not contain (measured from incr_misses)">>}]},
                {struct,[{name,<<"cas_hits">>},
                         {title,<<"CAS hits per sec.">>},
                         {desc,<<"Number of CAS operations per second for data that this bucket contains (measured from cas_hits)">>}]},
                {struct,[{name,<<"cas_badval">>},
                         {title,<<"CAS badval per sec.">>},
                         {desc,<<"Number of CAS operations per second using an incorrect CAS ID for data that this bucket contains (measured from cas_badval)">>}]},
                {struct,[{name,<<"cas_misses">>},
                         {title,<<"CAS misses per sec.">>},
                         {desc,<<"Number of CAS operations per second for data that this bucket does not contain (measured from cas_misses)">>}]}]}]}].

server_resources_stats_description(IndexNodes, FtsNodes) ->
    MaybeFts =
        case FtsNodes of
            [] ->
                [];
            _ ->
                [{struct,[{isBytes,true},
                          {name,<<"fts_num_bytes_used_ram">>},
                          {title,<<"fts RAM used">>},
                          {desc,<<"Amount of RAM used by FTS on this server">>}]}]
        end,
    MaybeIndexFts =
        case IndexNodes of
            [] ->
                MaybeFts;
            _ ->
                [{struct,[{name,<<"index_ram_percent">>},
                          {title,<<"Max Index RAM Used %">>},
                          {desc,<<"Percentage of Index RAM in use across all indexes on this server">>}]},
                 {struct,[{name,<<"index_remaining_ram">>},
                          {title,<<"remaining index ram">>},
                          {desc,<<"Amount of index RAM available on this server">>}]}
                 | MaybeFts]
        end,
    [{blockName,<<"Server Resources">>},
     {serverResources, true},
     {stats,
      [{struct,[{isBytes,true},
                {name,<<"swap_used">>},
                {title,<<"swap usage">>},
                {desc,<<"Amount of swap space in use on this server">>}]},
       {struct,[{isBytes,true},
                {name,<<"mem_actual_free">>},
                {title,<<"free RAM">>},
                {desc,<<"Amount of RAM available on this server">>}]},
       {struct,[{name,<<"cpu_utilization_rate">>},
                {title,<<"Max CPU utilization %">>},
                {desc,<<"Percentage of CPU in use across all available cores on this server">>},
                {maxY,100}]},
       {struct,[{name,<<"curr_connections">>},
                {title,<<"connections">>},
                {desc,<<"Number of connections to this server including"
                        "connections from external client SDKs, proxies, "
                        "DCP requests and internal statistic gathering "
                        "(measured from curr_connections)">>}]},
       {struct,[{name,<<"rest_requests">>},
                {title,<<"port 8091 reqs/sec">>},
                {desc,<<"Rate of http requests on port 8091">>}]},
       {struct,[{name,<<"hibernated_requests">>},
                {title,<<"idle streaming requests">>},
                {desc,<<"Number of streaming requests on port 8091 now idle">>}]},
       {struct,[{name,<<"hibernated_waked">>},
                {title,<<"streaming wakeups/sec">>},
                {desc,<<"Rate of streaming request wakeups on port 8091">>}]}
       | MaybeIndexFts]}].

base_stats_directory(BucketId, AddQuery, IndexNodes, FtsNodes) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(BucketId),
    Base = case ns_bucket:bucket_type(BucketConfig) of
               membase -> membase_stats_description(BucketId, AddQuery, IndexNodes, FtsNodes);
               memcached -> memcached_stats_description()
           end,
    [{struct, server_resources_stats_description(IndexNodes, FtsNodes)} | Base].

parse_add_index_param(Param, Params) ->
    case proplists:get_value(Param, Params) of
        undefined ->
            [];
        AddIndexX ->
            case ejson:decode(AddIndexX) of
                <<"all">> ->
                    all;
                AddIndexDecoded ->
                    [binary_to_existing_atom(N, latin1) || N <- AddIndexDecoded]
            end
    end.

serve_stats_directory(_PoolId, BucketId, Req) ->
    Params = Req:parse_qs(),
    AddQuery = proplists:get_value("addq", Params, "") =/= "",
    IndexNodes = parse_add_index_param("addi", Params),
    FtsNodes = parse_add_index_param("addf", Params),

    BaseDescription = base_stats_directory(BucketId, AddQuery, IndexNodes, FtsNodes),
    Prefix = menelaus_util:concat_url_path(["pools", "default", "buckets", BucketId, "stats"]),
    Desc = [{struct, add_specific_stats_url(BD, Prefix)} || {struct, BD} <- BaseDescription],
    menelaus_util:reply_json(Req, {struct, [{blocks, Desc}]}).

add_specific_stats_url(BlockDesc, Prefix) ->
    {stats, Infos} = lists:keyfind(stats, 1, BlockDesc),
    NewInfos =
        [{struct, [{specificStatsURL, begin
                                          {name, Name} = lists:keyfind(name, 1, KV),
                                          iolist_to_binary([Prefix, $/, mochiweb_util:quote_plus(Name)])
                                      end} |
                   KV]} || {struct, KV} <- Infos],
    lists:keyreplace(stats, 1, BlockDesc, {stats, NewInfos}).

grab_ui_stats(Kind, Nodes, HaveStamp, Wnd) ->
    TS = proplists:get_value(list_to_binary(Kind), HaveStamp),
    S = grab_aggregate_op_stats(Kind, Nodes, TS, Wnd),
    samples_to_proplists(S, Kind).

%% Returns multiple blocks of stats and other things convenient for
%% analytics UI.
%%
%% This is private and thus easily evolve-able API.
%%
%% It serves all stats that we're going to display on
%% analytics. Currently that is bucket stats, portion of system stats and
%% @query stats.
%%
%% Response format is roughly as follows:
%% {
%%   directory: {url: "/pools/default/buckets/default/statsDirectory?v=40989663&addq=1"},
%%   hot_keys: [],
%%   interval: 1000,
%%   isPersistent: true,
%%   lastTStamp: {default: 1424312639799, @system: 1424312639799, @query: 1424312640799},
%%   mainStatsBlock: "default",
%%   nextReqAfter: 0,
%%   samplesCount: 60,
%%   specificStatName: null,
%%   stats: {
%%     @query: {query_avg_req_time: [0, 0], query_avg_svc_time: [0, 0], query_avg_response_size: [0, 0],…},
%%     @system: {cpu_idle_ms: [14950, 15070], cpu_local_ms: [16310, 16090],…},
%%     default: {couch_total_disk_size: [578886, 578886], couch_docs_fragmentation: [0, 0],…},
%%     "@index-default": …
%% }}
%%
%%
%% Overall focus of this API was to pull as much logic as possible
%% from .js and into server, and to be able to handle displaying
%% multiple stats on single analytics page (i.e. @system, bucket,
%% @query, @index and possibly more (like @memcached-global)).
%%
%% Biggest differences from old-style (and public) stats are:
%%
%%  * independent "delta encoding" for different stats block. Which
%%  allows us to handle things such as missing samples in some stats
%%  without having to drop matching timestamps everywhere (like we
%%  still do between @system and bucket stats)
%%
%%  * automatically version-ed directory url. Thus UI doesn't have to
%%  have logic to "watch" served stats and reload directory
%%
%%  * maximally unified format and UI logic between aggregated and
%%  "specific" stats
%%
%%  * nextReqAfter tells ui when to send request for next sample
%%
%% * UI is not expected to be "hypertext" anymore, but to simply send
%% all parameters to _uistats and receive correct response back
%% (handling aggregate and specific stats in single place). We do
%% refer to directory separately, however, for efficiency (i.e. so
%% that ui does not have to receive/parse stats directory every time it receives
%% new stats samples).
%%
serve_ui_stats(Req) ->
    Params = Req:parse_qs(),
    case lists:member(proplists:get_value("bucket", Params), ns_bucket:get_bucket_names()) of
        true ->
            case proplists:get_value("statName", Params) of
                undefined ->
                    serve_aggregated_ui_stats(Req, Params);
                StatName ->
                    serve_specific_ui_stats(Req, StatName, Params)
            end;
        _ ->
            menelaus_util:reply_not_found(Req)
    end.

extract_ui_stats_params(Params) ->
    Bucket = proplists:get_value("bucket", Params),
    {HaveStamp} = ejson:decode(list_to_binary(proplists:get_value("haveTStamp", Params, "{}"))),
    {Step, Period} = case proplists:get_value("zoom", Params) of
                         "minute" -> {1, minute};
                         "hour" -> {60, hour};
                         "day" -> {1440, day};
                         "week" -> {11520, week};
                         "month" -> {44640, month};
                         "year" -> {527040, year}
                     end,
    Wnd = {Step, Period, 60},
    {Bucket, HaveStamp, Wnd}.

maybe_grab_stats(Section, Nodes, HaveStamp, Wnd, Stats) ->
    SectionNodes = section_nodes(Section),
    Grab = case Nodes of
               all ->
                   SectionNodes =/= [];
               [_|_] ->
                   lists:any(fun (Node) ->
                                     lists:member(Node, Nodes)
                             end, SectionNodes)
           end,
    case Grab of
        false ->
            {false, [], Stats};
        true ->
            Res = grab_ui_stats(Section, Nodes, HaveStamp, Wnd),
            {true, Nodes, [{list_to_binary(Section), {Res}} | Stats]}
    end.

serve_aggregated_ui_stats(Req, Params) ->
    {Bucket, HaveStamp, Wnd} = extract_ui_stats_params(Params),
    Nodes = case proplists:get_value("node", Params, all) of
                all -> all;
                XHost ->
                    case menelaus_web:find_node_hostname(XHost, Req) of
                        {ok, N} -> [N];
                        _ ->
                            erlang:throw({web_exception, 404, "not found", []})
                    end
            end,
    BS = grab_ui_stats(Bucket, Nodes, HaveStamp, Wnd),
    SS = grab_ui_stats("@system", Nodes, HaveStamp, Wnd),

    GoXDCRStats = [{iolist_to_binary([<<"@xdcr-">>, Bucket]),
                    {grab_ui_stats("@xdcr-" ++ Bucket, Nodes, HaveStamp, Wnd)}}],

    {HaveQuery, _, QStats} =
        maybe_grab_stats("@query", Nodes, HaveStamp, Wnd, GoXDCRStats),

    {_, IndexNodes, IStats} =
        maybe_grab_stats("@index-" ++ Bucket, Nodes, HaveStamp, Wnd, QStats),

    {_, _, IndexerStats} =
        maybe_grab_stats("@index", Nodes, HaveStamp, Wnd, IStats),

    {_, FtsNodes, FStats} =
        maybe_grab_stats("@fts-" ++ Bucket, Nodes, HaveStamp, Wnd, IndexerStats),

    {_, _, FullStats} =
        maybe_grab_stats("@fts", Nodes, HaveStamp, Wnd, FStats),

    Stats = [{list_to_binary(Bucket), {BS}},
             {<<"@system">>, {SS}}
             | FullStats],
    NewHaveStamp = [case proplists:get_value(timestamp, S) of
                        [] -> {Name, 0};
                        L -> {Name, lists:last(L)}
                    end || {Name, {S}} <- Stats],
    StatsDirectoryV = erlang:phash2(base_stats_directory(Bucket, HaveQuery, IndexNodes, FtsNodes)),
    DirAddQ = case HaveQuery of
                  true ->
                      [{addq, <<"1">>}];
                  false ->
                      []
              end,
    DirAddI = case IndexNodes of
                  [] -> DirAddQ;
                  _ ->
                      [{addi, iolist_to_binary(ejson:encode(IndexNodes))} | DirAddQ]
              end,
    DirAddF = case FtsNodes of
                  [] -> DirAddI;
                  _ ->
                      [{addf, iolist_to_binary(ejson:encode(FtsNodes))} | DirAddI]
              end,
    DirQS = [{v, integer_to_list(StatsDirectoryV)} | DirAddF],
    DirURL = "/pools/default/buckets/" ++ menelaus_util:concat_url_path([Bucket, "statsDirectory"], DirQS),

    [{hot_keys, HKs0}] = build_bucket_stats_hks_response(Bucket, Nodes),
    HKs = [{HK} || {struct, HK} <- HKs0],
    Extra = [{hot_keys, HKs}],
    output_ui_stats(Req, Stats,
                    {[{url, list_to_binary(DirURL)}]},
                    Wnd, Bucket, null, NewHaveStamp, Extra).

maybe_string_hostname_port(H) ->
    case lists:reverse(H) of
        "1908:" ++ RevPref ->
            lists:reverse(RevPref);
        _ ->
            H
    end.

serve_specific_ui_stats(Req, StatName, Params) ->
    {Bucket, HaveStamp, Wnd} = extract_ui_stats_params(Params),
    ClientTStamp = proplists:get_value(<<"perNode">>, HaveStamp),

    FullDirectory = base_stats_directory(Bucket, true, all, all),
    StatNameB = list_to_binary(StatName),
    MaybeStatDesc = [Desc
                     || Block <- FullDirectory,
                        XDesc <- case Block of
                                     {struct, BlockProps} ->
                                         {_, XStats} = lists:keyfind(stats, 1, BlockProps),
                                         XStats
                                 end,
                        Desc <- case XDesc of
                                    {struct, DescProps} ->
                                        {_, DescName} = lists:keyfind(name, 1, DescProps),
                                        case DescName =:= StatNameB of
                                            true ->
                                                [DescProps];
                                            false ->
                                                []
                                        end
                                end],

    case MaybeStatDesc of
        [] ->
            erlang:throw({web_exception, 404, "not found", []});
        [_|_] ->
            ok
    end,

    StatDescProps = hd(MaybeStatDesc),

    {NodesSamples, Nodes} =
        get_samples_for_system_or_bucket_stat(Bucket, StatName, ClientTStamp, Wnd),

    Config = ns_config:get(),
    LocalAddr = menelaus_util:local_addr(Req),
    StringHostnames = [menelaus_web:build_node_hostname(Config, N, LocalAddr) || N <- Nodes],
    StatKeys = [list_to_binary("@"++H) || H <- StringHostnames],

    Timestamps = [TS || {TS, _} <- hd(NodesSamples)],
    MainValues = [VS || {_, VS} <- hd(NodesSamples)],

    AllignedRestValues
        = lists:map(fun (undefined) -> [undefined || _ <- Timestamps];
                        (Samples) ->
                            Dict = orddict:from_list(Samples),
                            [dict_safe_fetch(T, Dict, 0) || T <- Timestamps]
                    end, tl(NodesSamples)),

    Stats = lists:zipwith(fun (H, VS) ->
                                  {H, VS}
                          end,
                          StatKeys, [MainValues | AllignedRestValues]),
    LastTStamp = case Timestamps of
                     [] -> 0;
                     L -> lists:last(L)
                 end,

    RestStatDescProps =
        [{K, V} || {K, V} <- StatDescProps,
                   K =/= name andalso K =/= title],

    StatInfos = [{[{title, list_to_binary(maybe_string_hostname_port(H))},
                   {name, list_to_binary("@"++H)}
                   | RestStatDescProps]}
                 || H <- StringHostnames],

    ServeDirectory = {[{value, {[{thisISSpecificStats, true},
                                 {blocks, [{[{blockName, <<"Specific Stats">>},
                                             {hideThis, true},
                                             {stats, StatInfos}]}]}]}},
                       {origTitle, misc:expect_prop_value(title, StatDescProps)},
                       {url, null}]},

    FullStats = [{timestamp, Timestamps} | Stats],

    output_ui_stats(Req,
                    [{perNode, {FullStats}}],
                    ServeDirectory,
                    Wnd, Bucket, list_to_binary(StatName),
                    [{perNode, LastTStamp}], []).


output_ui_stats(Req, Stats, Directory, Wnd, Bucket, StatName, NewHaveStamp, Extra) ->
    Step = element(1, Wnd),
    J = [{stats, {Stats}},
         {directory, Directory},
         {samplesCount, 60},
         {interval, Step * 1000},
         {isPersistent, is_persistent(Bucket)},
         {nextReqAfter, case Step of
                            1 -> 0;
                            _ -> 30000
                        end},
         {mainStatsBlock, element(1, hd(Stats))},
         {specificStatName, StatName},
         {lastTStamp, {NewHaveStamp}} | Extra],
    menelaus_util:reply_json(Req, {J}).

get_indexes(Indexer, BucketId) ->
    simple_memoize({indexes, Indexer:get_type(), BucketId},
                   fun () ->
                           Nodes = section_nodes(Indexer:prefix() ++ BucketId),
                           do_get_indexes(Indexer, BucketId, Nodes)
                   end, 5000).

do_get_indexes(Indexer, BucketId0, Nodes) ->
    WantedHosts0 =
        [begin
             {_, Host} = misc:node_name_host(N),
             Port = misc:node_rest_port(N),
             iolist_to_binary([Host, $:, integer_to_list(Port)])
         end || N <- Nodes],
    WantedHosts = lists:usort(WantedHosts0),

    BucketId = list_to_binary(BucketId0),
    {ok, Indexes, _Stale, _Version} = index_status_keeper:get_indexes(Indexer),
    [begin
         {index, Name} = lists:keyfind(index, 1, I),
         Name
     end || I <- Indexes,
            proplists:get_value(bucket, I) =:= BucketId,
            not(ordsets:is_disjoint(WantedHosts,
                                    lists:usort(proplists:get_value(hosts, I))))].
