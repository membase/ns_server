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

-export([memory_quota/1, change_memory_quota/2,
         setup_disk_storage_conf/2,
         storage_conf/1, storage_conf_from_node_status/1, add_storage/4, remove_storage/2,
         local_bucket_disk_usage/1,
         this_node_dbdir/0, this_node_ixdir/0, this_node_logdir/0,
         delete_databases/1,
         delete_all_databases/0, delete_all_databases/1]).

-export([node_storage_info/1, cluster_storage_info/0, nodes_storage_info/1]).

-export([allowed_node_quota_range/1, allowed_node_quota_range/0,
         allowed_node_quota_range_for_joined_nodes/0,
         this_node_memory_data/0]).

-export([extract_disk_stats_for_path/2]).


memory_quota(Node) ->
    memory_quota(Node, ns_config:get()).

memory_quota(_Node, Config) ->
    {value, RV} = ns_config:search(Config, memory_quota),
    RV.


-spec this_node_bucket_dirs(BucketName :: string()) -> [string()].
this_node_bucket_dirs(BucketName) ->
    {ok, DBDir} = this_node_dbdir(),
    {ok, IxDir} = this_node_ixdir(),

    [filename:join(DBDir, BucketName),
     filename:join(IxDir, "." ++ BucketName)].

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


change_memory_quota(_Node, NewMemQuotaMB) when is_integer(NewMemQuotaMB) ->
    ns_config:set(memory_quota, NewMemQuotaMB).

ensure_dir(Path) ->
    filelib:ensure_dir(Path),
    case file:make_dir(Path) of
        ok -> ok;
        {error, eexist} ->
            TouchPath = filename:join(Path, ".touch"),
            case file:write_file(TouchPath, <<"">>) of
                ok ->
                    file:delete(TouchPath),
                    ok;
                _ -> error
            end;
        _ -> error
    end.

ensure_dirs([]) ->
    ok;
ensure_dirs([Path | Rest]) ->
    case ensure_dir(Path) of
        ok ->
            ensure_dirs(Rest);
        X -> X
    end.

%% @doc sets db and index path of this node.
%%
%% NOTE: ns_server restart is required to make this fully effective.
-spec setup_disk_storage_conf(DbPath::string(), IxDir::string()) -> ok | {errors, [Msg :: binary()]}.
setup_disk_storage_conf(DbPath, IxPath) ->

    [ns_orchestrator:delete_bucket(Bucket)
     || {Bucket, _} <- ns_bucket:get_buckets()],

    [{db_path, CurrentDbDir},
     {index_path, CurrentIxDir}] = lists:sort(cb_config_couch_sync:get_db_and_ix_paths()),

    NewDbDir = misc:absname(DbPath),
    NewIxDir = misc:absname(IxPath),

    case NewDbDir =/= CurrentDbDir orelse NewIxDir =/= CurrentIxDir of
        true ->
            case ensure_dirs([NewDbDir, NewIxDir]) of
                ok ->
                    cb_config_couch_sync:set_db_and_ix_paths(NewDbDir, NewIxDir),
                    ok;
                error ->
                    {errors, [<<"Could not set the storage path. It must be a directory writable by 'couchbase' user.">>]}
            end;
        _ ->
            ok
    end.

local_bucket_disk_usage(BucketName) ->
    BucketDirs = this_node_bucket_dirs(BucketName),
    lists:sum([misc:dir_size(Dir) || Dir <- BucketDirs]).

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

% Quota is an integer or atom none.
% Kind is atom ssd or hdd.
%
add_storage(_Node, "", _Kind, _Quota) ->
    {error, invalid_path};

add_storage(_Node, _Path, _Kind, _Quota) ->
    % TODO.
    ok.

remove_storage(_Node, _Path) ->
    % TODO.
    {error, todo}.

node_storage_info(Node) ->
    case dict:find(Node, ns_doctor:get_nodes()) of
        {ok, NodeInfo} ->
            extract_node_storage_info(NodeInfo, Node);
        _ -> []
    end.

extract_node_storage_info(NodeInfo, Node) ->
    extract_node_storage_info(NodeInfo, Node, ns_config:get()).

extract_node_storage_info(NodeInfo, Node, Config) ->
    {RAMTotal, RAMUsed, _} = proplists:get_value(memory_data, NodeInfo),
    DiskStats = proplists:get_value(disk_data, NodeInfo),
    StorageConf = proplists:get_value(node_storage_conf, NodeInfo, []),
    DiskPaths = [X || {PropName, X} <- StorageConf,
                      PropName =:= db_path orelse PropName =:= index_path],
    case memory_quota(Node, Config) of
        MemQuotaMB when is_integer(MemQuotaMB) ->
            {DiskTotal, DiskUsed} = extract_disk_totals(DiskPaths, DiskStats),
            [{ram, [{total, RAMTotal},
                    {quotaTotal, MemQuotaMB * 1048576},
                    {used, RAMUsed},
                    {free, 0} % not used
                   ]},
             {hdd, [{total, DiskTotal},
                    {quotaTotal, DiskTotal},
                    {used, DiskUsed},
                    {free, DiskTotal - DiskUsed}
                   ]}];
        _ -> []
    end.

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

add_used_by_data_prop(UsedByData, Props) ->
    %% because of disk usage update lags and because disksup provides
    %% disk usage information in (rounded down) percentage we can have
    %% UsedByData > Used.
    Used = misc:expect_prop_value(used, Props),
    Props2 = case Used < UsedByData of
                 true ->
                     lists:keyreplace(used, 1, Props, {used, UsedByData});
                 _ ->
                     Props
             end,
    [{usedByData, UsedByData} | Props2].

extract_subprop(NodeInfos, Key, SubKey) ->
    [proplists:get_value(SubKey, proplists:get_value(Key, NodeInfo, [])) ||
     NodeInfo <- NodeInfos].

do_cluster_storage_info([]) -> [];
do_cluster_storage_info(NodeInfos) ->
    Config = ns_config:get(),
    AllBuckets = ns_bucket:get_buckets(Config),
    AllNodes = ordsets:intersection(lists:sort(ns_node_disco:nodes_actual_proper()),
                                    lists:sort(proplists:get_keys(NodeInfos))),
    AllNodesSize = length(AllNodes),
    RAMQuotaUsed = lists:foldl(fun ({_, BucketConfig}, RAMQuota) ->
                                       ns_bucket:raw_ram_quota(BucketConfig) * AllNodesSize + RAMQuota
                               end, 0, AllBuckets),
    StorageInfos = [extract_node_storage_info(NodeInfo, Node, Config)
                    || {Node, NodeInfo} <- NodeInfos],
    HddTotals = extract_subprop(StorageInfos, hdd, total),
    HddUsed = extract_subprop(StorageInfos, hdd, used),
    PList1 = [{ram, [{total, lists:sum(extract_subprop(StorageInfos, ram, total))},
                     {quotaTotal, lists:sum(extract_subprop(StorageInfos, ram,
                                                            quotaTotal))},
                     {quotaUsed, RAMQuotaUsed},
                     {used, lists:sum(extract_subprop(StorageInfos, ram, used))}
                    ]},
              {hdd, [{total, lists:sum(HddTotals)},
                     {quotaTotal, lists:sum(HddTotals)},
                     {used, lists:sum(HddUsed)},
                     {free, lists:min(lists:zipwith(fun (A, B) -> A - B end,
                                                    HddTotals, HddUsed))
                      * length(HddUsed)} % Minimum amount free on any node * number of nodes
                    ]}],

    {BucketsRAMUsage, BucketsHDDUsage}
        = lists:foldl(fun ({Name, _}, {RAM, HDD}) ->
                              BasicStats = menelaus_stats:basic_stats(Name, AllNodes),
                              {RAM + proplists:get_value(memUsed, BasicStats),
                               HDD + proplists:get_value(diskUsed, BasicStats)}
                      end, {0, 0}, AllBuckets),
    lists:map(fun ({ram, Props}) ->
                      {ram, add_used_by_data_prop(BucketsRAMUsage, Props)};
                  ({hdd, Props}) ->
                      {hdd, add_used_by_data_prop(BucketsHDDUsage, Props)}
              end, PList1).

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
        _ -> extract_disk_stats_for_path(Rest, Path)
    end.

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

bucket_databases(Bucket) ->
    {ok, AllDBs} = couch_server:all_databases(),
    bucket_databases(Bucket, AllDBs).

bucket_databases(Bucket, AllDBs) ->
    BinBucket = list_to_binary(Bucket ++ "/"),
    N = byte_size(BinBucket),
    Pred = fun (Db) ->
                   try
                       Prefix = binary:part(Db, {0, N}),
                       Prefix =:= BinBucket
                   catch
                       _E:_R ->
                           false
                   end
           end,
    lists:filter(Pred, AllDBs).

delete_database(DB) ->
    RV = couch_server:delete(DB, []),
    ?log_info("Deleting database ~p: ~p~n", [DB, RV]),
    ok.

delete_databases(Bucket) ->
    lists:foreach(fun delete_database/1, bucket_databases(Bucket)).

delete_all_databases() ->
    Buckets = ns_bucket:get_bucket_names(),
    delete_all_databases(Buckets).

delete_all_databases(Buckets) ->
    lists:foreach(fun delete_databases/1, Buckets).

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

bucket_databases_test() ->
    AllDBs = lists:map(fun list_to_binary/1,
                           ["_users",
                            "_replicator",
                            "bucket/master",
                            "bucket/0",
                            "bucket/1",
                            "bucket/2",
                            "bucket/3",
                            "default_bucket/master",
                            "default_bucket/0",
                            "default_bucket/1",
                            "default_bucket/2",
                            "default_bucket/3",
                            "default/master",
                            "default/0",
                            "default/1",
                            "default/2",
                            "default/3"]),
    DefaultBucketDBs = lists:map(fun list_to_binary/1,
                                 ["default/master",
                                  "default/0",
                                  "default/1",
                                  "default/2",
                                  "default/3"]),

    ?assertEqual(DefaultBucketDBs,
                 bucket_databases("default", AllDBs)).

-endif.

this_node_memory_data() ->
    case os:getenv("MEMBASE_RAM_MEGS") of
        false -> memsup:get_memory_data();
        X ->
            RAMBytes = list_to_integer(X) * 1048576,
            {RAMBytes, 0, 0}
    end.

allowed_node_quota_range() ->
    MemoryData = this_node_memory_data(),
    allowed_node_quota_range(MemoryData, 1024).

allowed_node_quota_range(MemoryData) ->
    allowed_node_quota_range(MemoryData, 1024).

%% when validating memory size versus cluster quota we use less strict
%% rules so that clusters upgraded from 1.6.0 are able to join
%% homogeneous nodes. See MB-2762
allowed_node_quota_range_for_joined_nodes() ->
    MemoryData = this_node_memory_data(),
    allowed_node_quota_range(MemoryData, 512).

allowed_node_quota_range(MemSupData, MinusMegs) ->
    {MaxMemoryBytes0, _, _} = MemSupData,
    MiB = 1048576,
    MinMemoryMB = 256,
    MaxMemoryMBPercent = (MaxMemoryBytes0 * 4) div (5 * MiB),
    MaxMemoryMB = lists:max([(MaxMemoryBytes0 div MiB) - MinusMegs,
                             MaxMemoryMBPercent]),
    QuotaErrorDetailsFun = fun () ->
                                   case MaxMemoryMB of
                                       MaxMemoryMBPercent ->
                                           io_lib:format(" Quota must be between 256 MB and ~w MB (80% of memory size).", [MaxMemoryMB]);
                                       _ ->
                                           io_lib:format(" Quota must be between 256 MB and ~w MB (memory size minus ~w MB).", [MaxMemoryMB, MinusMegs])
                                   end
                           end,
    {MinMemoryMB, MaxMemoryMB, QuotaErrorDetailsFun}.
