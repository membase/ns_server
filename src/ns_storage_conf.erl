%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
% A module for retrieving & configuring per-server storage paths,
% storage quotas, mem quotas, etc.
%
-module(ns_storage_conf).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").

-export([memory_quota/0, change_memory_quota/1,
         setup_disk_storage_conf/2,
         storage_conf/1, storage_conf_from_node_status/1,
         local_bucket_disk_usage/1,
         this_node_dbdir/0, this_node_ixdir/0, this_node_logdir/0,
         this_node_bucket_dbdir/1,
         delete_unused_buckets_db_files/0]).

-export([cluster_storage_info/0, cluster_storage_info/1, nodes_storage_info/1]).

-export([allowed_node_quota_range/1, allowed_node_quota_range/0,
         default_memory_quota/1,
         allowed_node_quota_max_for_joined_nodes/0,
         this_node_memory_data/0]).

-export([extract_disk_stats_for_path/2]).


memory_quota() ->
    memory_quota(ns_config:get()).

memory_quota(Config) ->
    {value, RV} = ns_config:search(Config, memory_quota),
    RV.

couch_storage_path(Field) ->
    try cb_config_couch_sync:get_db_and_ix_paths() of
        PList ->
            {Field, RV} = lists:keyfind(Field, 1, PList),
            {ok, RV}
    catch T:E ->
            ?log_debug("Failed to get couch storage config field: ~p due to ~p:~p", [Field, T, E]),
            {error, iolist_to_binary(io_lib:format("couch config access failed: ~p:~p", [T, E]))}
    end.

-spec this_node_dbdir() -> {ok, string()} | {error, binary()}.
this_node_dbdir() ->
    couch_storage_path(db_path).

-spec this_node_bucket_dbdir(bucket_name()) -> {ok, string()}.
this_node_bucket_dbdir(BucketName) ->
    {ok, DBDir} = ns_storage_conf:this_node_dbdir(),
    DBSubDir = filename:join(DBDir, BucketName),
    {ok, DBSubDir}.

-spec this_node_ixdir() -> {ok, string()} | {error, binary()}.
this_node_ixdir() ->
    couch_storage_path(index_path).

-spec this_node_logdir() -> {ok, string()} | {error, any()}.
this_node_logdir() ->
    logdir(ns_config:get(), node()).

-spec logdir(any(), atom()) -> {ok, string()} | {error, any()}.
logdir(Config, Node) ->
    read_path_from_conf(Config, Node, ns_log, filename).

%% @doc read a path from the configuration, following symlinks
-spec read_path_from_conf(any(), atom(), atom(), atom()) ->
    {ok, string()} | {error, any()}.
read_path_from_conf(Config, Node, Key, SubKey) ->
    {value, PropList} = ns_config:search_node(Node, Config, Key),
    case proplists:get_value(SubKey, PropList) of
        undefined ->
            {error, undefined};
        DBDir ->
            {ok, Base} = file:get_cwd(),
            case misc:realpath(DBDir, Base) of
                {error, Atom, _, _} -> {error, Atom};
                {ok, _} = X -> X
            end
    end.


change_memory_quota(NewMemQuotaMB) when is_integer(NewMemQuotaMB) ->
    ns_config:set(memory_quota, NewMemQuotaMB).

%% @doc sets db and index path of this node.
%%
%% NOTE: ns_server restart is required to make this fully effective.
-spec setup_disk_storage_conf(DbPath::string(), IxDir::string()) -> ok | {errors, [Msg :: binary()]}.
setup_disk_storage_conf(DbPath, IxPath) ->
    [{db_path, CurrentDbDir},
     {index_path, CurrentIxDir}] = lists:sort(cb_config_couch_sync:get_db_and_ix_paths()),

    NewDbDir = misc:absname(DbPath),
    NewIxDir = misc:absname(IxPath),

    case NewDbDir =/= CurrentDbDir orelse NewIxDir =/= CurrentIxDir of
        true ->
            ale:info(?USER_LOGGER, "Setting database directory path to ~s and index directory path to ~s", [NewDbDir, NewIxDir]),
            case misc:ensure_writable_dirs([NewDbDir, NewIxDir]) of
                ok ->
                    RV =
                        case NewDbDir =:= CurrentDbDir of
                            true ->
                                ok;
                            false ->
                                ?log_info("Removing all unused database files"),
                                case delete_unused_buckets_db_files() of
                                    ok ->
                                        ok;
                                    Error ->
                                        Msg = iolist_to_binary(
                                                io_lib:format("Could not delete unused database files: ~p",
                                                              [Error])),
                                        {errors, [Msg]}
                                end
                        end,

                    case RV of
                        ok ->
                            cb_config_couch_sync:set_db_and_ix_paths(NewDbDir, NewIxDir);
                        _ ->
                            RV
                    end;
                error ->
                    {errors, [<<"Could not set the storage path. It must be a directory writable by 'couchbase' user.">>]}
            end;
        _ ->
            ok
    end.

%% this is RPCed by pre-2.0 nodes
local_bucket_disk_usage(BucketName) ->
    {ok, Stats} = couch_stats_reader:fetch_stats(BucketName),
    Docs = proplists:get_value(couch_docs_actual_disk_size, Stats, 0),
    Views = proplists:get_value(couch_views_actual_disk_size, Stats, 0),
    Docs + Views.

% Returns a proplist of lists of proplists.
%
% A quotaMb of none means no quota. Disks can get full, disappear,
% etc, so non-ok state is used to signal issues.
%
% NOTE: in current implementation node disk quota is supported and
% state is always ok
%
% NOTE: current node supports only single storage path and does not
% support dedicated ssd (versus hdd) path
%
% NOTE: 1.7/1.8 nodes will not have storage conf returned in current
% implementation.
%
% [{ssd, []},
%  {hdd, [[{path, /some/nice/disk/path}, {quotaMb, 1234}, {state, ok}],
%         [{path", /another/good/disk/path}, {quotaMb, 5678}, {state, ok}]]}]
%
storage_conf(Node) ->
    NodeStatus = ns_doctor:get_node(Node),
    storage_conf_from_node_status(NodeStatus).

storage_conf_from_node_status(NodeStatus) ->
    StorageConf = proplists:get_value(node_storage_conf, NodeStatus, []),
    HDDInfo = case proplists:get_value(db_path, StorageConf) of
                  undefined -> [];
                  DBDir ->
                      [{path, DBDir},
                       {index_path, proplists:get_value(index_path, StorageConf, DBDir)},
                       {quotaMb, none},
                       {state, ok}]
              end,
    [{ssd, []},
     {hdd, [HDDInfo]}].

extract_node_storage_info(NodeInfo) ->
    {RAMTotal, RAMUsed, _} = proplists:get_value(memory_data, NodeInfo),
    DiskStats = proplists:get_value(disk_data, NodeInfo),
    StorageConf = proplists:get_value(node_storage_conf, NodeInfo, []),
    DiskPaths = [X || {PropName, X} <- StorageConf,
                      PropName =:= db_path orelse PropName =:= index_path],
    {DiskTotal, DiskUsed} = extract_disk_totals(DiskPaths, DiskStats),
    [{ram, [{total, RAMTotal},
            {used, RAMUsed}
           ]},
     {hdd, [{total, DiskTotal},
            {quotaTotal, DiskTotal},
            {used, DiskUsed},
            {free, DiskTotal - DiskUsed}
           ]}].

-spec extract_disk_totals(list(), list()) -> {integer(), integer()}.
extract_disk_totals(DiskPaths, DiskStats) ->

    F = fun (Path, {UsedMounts, ATotal, AUsed} = Tuple) ->
                case extract_disk_stats_for_path(DiskStats, Path) of
                    none -> Tuple;
                    {ok, {MPoint, KBytesTotal, Cap}} ->
                        case lists:member(MPoint, UsedMounts) of
                            true -> Tuple;
                            false ->
                                Total = KBytesTotal * 1024,
                                Used = (Total * Cap) div 100,
                                {[MPoint | UsedMounts], ATotal + Total,
                                 AUsed + Used}
                        end
                end
        end,
    {_UsedMounts, DiskTotal, DiskUsed} = lists:foldl(F, {[], 0, 0}, DiskPaths),
    {DiskTotal, DiskUsed}.

%% returns cluster_storage_info for subset of nodes
nodes_storage_info(NodeNames) ->
    NodesDict = ns_doctor:get_nodes(),
    NodesInfos = lists:foldl(fun (N, A) ->
                                     case dict:find(N, NodesDict) of
                                         {ok, V} -> [{N, V} | A];
                                         _ -> A
                                     end
                             end, [], NodeNames),
    do_cluster_storage_info(NodesInfos).

%% returns cluster storage info. This is aggregation of various
%% storage related metrics across active nodes of cluster.
%%
%% total - total amount of this resource (ram or hdd) in bytes
%%
%% free - amount of this resource free (ram or hdd) in bytes
%%
%% used - amount of this resource used (for any purpose (us, OS, other
%% processes)) in bytes
%%
%% quotaTotal - amount of quota for this resource across cluster
%% nodes. Note hdd quota is not really supported.
%%
%% quotaUsed - amount of quota already allocated
%%
%% usedByData - amount of this resource used by our data
cluster_storage_info() ->
    nodes_storage_info(ns_cluster_membership:active_nodes()).

cluster_storage_info(NodesInfos) ->
    do_cluster_storage_info(NodesInfos).

extract_subprop(NodeInfos, Key, SubKey) ->
    [proplists:get_value(SubKey, proplists:get_value(Key, NodeInfo, [])) ||
     NodeInfo <- NodeInfos].

interesting_stats_total_rec([], _Key, Acc) ->
    Acc;
interesting_stats_total_rec([ThisStats | RestStats], Key, Acc) ->
    case lists:keyfind(Key, 1, ThisStats) of
        false ->
            interesting_stats_total_rec(RestStats, Key, Acc);
        {_, V} ->
            interesting_stats_total_rec(RestStats, Key, Acc + V)
    end.

get_total_buckets_ram_quota(Config) ->
    AllBuckets = ns_bucket:get_buckets(Config),
    lists:foldl(fun ({_, BucketConfig}, RAMQuota) ->
                                       ns_bucket:raw_ram_quota(BucketConfig) + RAMQuota
                               end, 0, AllBuckets).

do_cluster_storage_info([]) -> [];
do_cluster_storage_info(NodeInfos) ->
    Config = ns_config:get(),
    AllNodes = ordsets:intersection(lists:sort(ns_node_disco:nodes_actual_proper()),
                                    lists:sort(proplists:get_keys(NodeInfos))),
    AllNodesSize = length(AllNodes),
    RAMQuotaUsedPerNode = get_total_buckets_ram_quota(Config),
    RAMQuotaUsed = RAMQuotaUsedPerNode * AllNodesSize,

    RAMQuotaTotalPerNode =
        case memory_quota(Config) of
            MemQuotaMB when is_integer(MemQuotaMB) ->
                MemQuotaMB * ?MIB;
            _ ->
                0
        end,

    StorageInfos = [extract_node_storage_info(NodeInfo)
                    || {_Node, NodeInfo} <- NodeInfos],
    HddTotals = extract_subprop(StorageInfos, hdd, total),
    HddUsed = extract_subprop(StorageInfos, hdd, used),

    AllInterestingStats = [proplists:get_value(interesting_stats, PList, []) || {_N, PList} <- NodeInfos],

    BucketsRAMUsage = interesting_stats_total_rec(AllInterestingStats, mem_used, 0),
    BucketsDiskUsage = interesting_stats_total_rec(AllInterestingStats, couch_docs_actual_disk_size, 0)
        + interesting_stats_total_rec(AllInterestingStats, couch_views_actual_disk_size, 0),

    RAMUsed = erlang:max(lists:sum(extract_subprop(StorageInfos, ram, used)),
                         BucketsRAMUsage),
    HDDUsed = erlang:max(lists:sum(HddUsed),
                         BucketsDiskUsage),

    [{ram, [{total, lists:sum(extract_subprop(StorageInfos, ram, total))},
            {quotaTotal, RAMQuotaTotalPerNode * AllNodesSize},
            {quotaUsed, RAMQuotaUsed},
            {used, RAMUsed},
            {usedByData, BucketsRAMUsage},
            {quotaUsedPerNode, RAMQuotaUsedPerNode},
            {quotaTotalPerNode, RAMQuotaTotalPerNode}
           ]},
     {hdd, [{total, lists:sum(HddTotals)},
            {quotaTotal, lists:sum(HddTotals)},
            {used, HDDUsed},
            {usedByData, BucketsDiskUsage},
            {free, lists:min(lists:zipwith(fun (A, B) -> A - B end,
                                           HddTotals, HddUsed)) * length(HddUsed)} % Minimum amount free on any node * number of nodes
           ]}].

extract_disk_stats_for_path_rec([], _Path) ->
    none;
extract_disk_stats_for_path_rec([{MountPoint0, _, _} = Info | Rest], Path) ->
    MountPoint = filename:join([MountPoint0]),  % normalize path. See filename:join docs
    MPath = case lists:reverse(MountPoint) of
                %% ends of '/'
                "/" ++ _ -> MountPoint;
                %% doesn't. Append it
                X -> lists:reverse("/" ++ X)
            end,
    case MPath =:= string:substr(Path, 1, length(MPath)) of
        true -> {ok, Info};
        _ -> extract_disk_stats_for_path_rec(Rest, Path)
    end.

%% Path0 must be an absolute path with all symlinks resolved.
extract_disk_stats_for_path(StatsList, Path0) ->
    Path = case filename:join([Path0]) of
               "/" -> "/";
               X -> X ++ "/"
           end,
    %% we sort by decreasing length so that first match is 'deepest'
    LessEqFn = fun (A,B) ->
                       length(element(1, A)) >= length(element(1, B))
               end,
    SortedList = lists:sort(LessEqFn, StatsList),
    extract_disk_stats_for_path_rec(SortedList, Path).

%% scan data directory for bucket names
bucket_names_from_disk() ->
    {ok, DbDir} = ns_storage_conf:this_node_dbdir(),
    Files = filelib:wildcard("*", DbDir),
    lists:foldl(
      fun (MaybeBucket, Acc) ->
              Path = filename:join(DbDir, MaybeBucket),
              case filelib:is_dir(Path) of
                  true ->
                      case ns_bucket:is_valid_bucket_name(MaybeBucket) of
                          true ->
                              [MaybeBucket | Acc];
                          {error, _} ->
                              Acc
                      end;
                  false ->
                      Acc
              end
      end, [], Files).

delete_disk_buckets_databases(Pred) ->
    Buckets = lists:filter(Pred, bucket_names_from_disk()),
    delete_disk_buckets_databases_loop(Pred, Buckets).

delete_disk_buckets_databases_loop(_Pred, []) ->
    ok;
delete_disk_buckets_databases_loop(Pred, [Bucket | Rest]) ->
    case ns_couchdb_storage:delete_databases_and_files(Bucket) of
        ok ->
            delete_disk_buckets_databases_loop(Pred, Rest);
        Error ->
            Error
    end.

%% deletes all databases files for buckets not defined for this node
%% note: this is called remotely
%%
%% it's named a bit differently from other functions here; but this function
%% is rpc called by older nodes; so we must keep this name unchanged
delete_unused_buckets_db_files() ->
    Config = ns_config:get(),
    BucketNames = ns_bucket:node_bucket_names(node(), ns_bucket:get_buckets(Config)),
    delete_disk_buckets_databases(
      fun (Bucket) ->
              RV = not(lists:member(Bucket, BucketNames)),
              case RV of
                  true ->
                      ale:info(?USER_LOGGER, "Deleting old data files of bucket ~p", [Bucket]);
                  _ ->
                      ok
              end,
              RV
      end).

-ifdef(EUNIT).
extract_disk_stats_for_path_test() ->
    DiskSupStats = [{"/",297994252,97},
             {"/lib/init/rw",1921120,1},
             {"/dev",10240,2},
             {"/dev/shm",1921120,0},
             {"/var/separate",1921120,0},
             {"/media/p2",9669472,81}],
    ?assertEqual({ok, {"/media/p2",9669472,81}},
                 extract_disk_stats_for_path(DiskSupStats,
                                             "/media/p2/mbdata")),
    ?assertEqual({ok, {"/", 297994252, 97}},
                 extract_disk_stats_for_path(DiskSupStats, "/")),
    ?assertEqual({ok, {"/", 297994252, 97}},
                 extract_disk_stats_for_path(DiskSupStats, "/lib/init")),
    ?assertEqual({ok, {"/dev", 10240, 2}},
                 extract_disk_stats_for_path(DiskSupStats, "/dev/sh")),
    ?assertEqual({ok, {"/dev", 10240, 2}},
                 extract_disk_stats_for_path(DiskSupStats, "/dev")).


-endif.

this_node_memory_data() ->
    case os:getenv("MEMBASE_RAM_MEGS") of
        false -> memsup:get_memory_data();
        X ->
            RAMBytes = list_to_integer(X) * ?MIB,
            {RAMBytes, 0, 0}
    end.

allowed_node_quota_range() ->
    MemoryData = this_node_memory_data(),
    allowed_node_quota_range(ns_config:get(), MemoryData, 1024).

allowed_node_quota_range(MemoryData) ->
    allowed_node_quota_range(ns_config:get(), MemoryData, 1024).

%% when validating memory size versus cluster quota we use less strict
%% rules so that clusters upgraded from 1.6.0 are able to join
%% homogeneous nodes. See MB-2762
allowed_node_quota_max_for_joined_nodes() ->
    MemoryData = this_node_memory_data(),
    {_, MaxMemoryMB, _} = allowed_node_quota_range(undefined, MemoryData, 512),
    MaxMemoryMB.

allowed_node_quota_range(Config, MemSupData, MinusMegs) ->
    {MaxMemoryBytes0, _, _} = MemSupData,
    MinMemoryMB = case Config of
                      undefined ->
                          256;
                      _ ->
                          erlang:max(256, get_total_buckets_ram_quota(Config) div ?MIB)
                  end,

    MaxMemoryMBPercent = (MaxMemoryBytes0 * 4) div (5 * ?MIB),
    MaxMemoryMB = lists:max([(MaxMemoryBytes0 div ?MIB) - MinusMegs,
                             MaxMemoryMBPercent]),
    QuotaErrorDetailsFun =
        fun () ->
                case MaxMemoryMB of
                    MaxMemoryMBPercent ->
                        io_lib:format(" Quota must be between ~w MB and ~w MB (80% of memory size).",
                                      [MinMemoryMB, MaxMemoryMB]);
                    _ ->
                        io_lib:format(" Quota must be between ~w MB and ~w MB (memory size minus ~w MB).",
                                      [MinMemoryMB, MaxMemoryMB, MinusMegs])
                end
        end,
    {MinMemoryMB, MaxMemoryMB, QuotaErrorDetailsFun}.

default_memory_quota(MemSupData) ->
    {Min, Max, _} = allowed_node_quota_range(undefined, MemSupData, 1024),
    {MaxMemoryBytes0, _, _} = MemSupData,
    Value = (MaxMemoryBytes0 * 3) div (5 * ?MIB),
    if Value > Max ->
            Max;
       Value < Min ->
            Min;
       true ->
            Value
    end.
