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

-export([memory_quota/1, change_memory_quota/2, prepare_setup_disk_storage_conf/2,
         storage_conf/1, add_storage/4, remove_storage/2,
         local_bucket_disk_usage/1,
         delete_buckets_db_files/2,
         delete_all_db_files/0, delete_all_db_files/1, delete_db_files/1,
         dbdir/0, dbdir/1, dbdir/2,
         logdir/1, logdir/2,
         bucket_dir/3]).

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


-spec bucket_dir(any(), atom(), string()) -> {ok, string()} | {error, any()}.
bucket_dir(Config, Node, BucketName) ->
    {ok, DBDir} = read_path_from_conf(Config, Node, memcached, dbdir),
    case misc:realpath(BucketName ++ "-data", DBDir) of
        {ok, _} = X -> X;
        {error, X, _, _} -> {error, X}
    end.

-spec dbdir() -> {ok, string()} | {error, any()}.
dbdir() ->
    dbdir(ns_config:get()).

-spec dbdir(any()) -> {ok, string()} | {error, any()}.
dbdir(Config) ->
    dbdir(Config, node()).

-spec dbdir(any(), atom()) -> {ok, string()} | {error, any()}.
dbdir(Config, Node) ->
    read_path_from_conf(Config, Node, memcached, dbdir).


-spec logdir(any()) -> {ok, string()} | {error, any()}.
logdir(Config) ->
    logdir(Config, node()).

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

prepare_setup_disk_storage_conf(Node, Path) when Node =:= node() ->
    Config = ns_config:get(),
    {ok, DBDir} = dbdir(Config, Node),
    NewDBDir = misc:absname(Path),
    PathOK = case DBDir of
                 NewDBDir -> ok;
                 _ ->
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
                     end
             end,
    case PathOK of
        ok ->
            {value, PropList} = ns_config:search_node(Node, Config,
                                                      memcached),
            {ok, fun () ->
                         ns_config:set({node, node(), memcached},
                                       [{dbdir, Path}
                                        | lists:keydelete(dbdir, 1, PropList)])
                 end};
        X -> X
    end.

local_bucket_disk_usage(BucketName) ->
    {ok, BucketDir} = bucket_dir(ns_config:get(), node(), BucketName),
    %% this doesn't include filesystem slack
    lists:sum([filelib:file_size(File)
               || File <- filelib:wildcard(BucketDir ++ "/*")]).

storage_conf(Node) ->
    storage_conf(Node, ns_config:get()).

% Returns a proplist of lists of proplists.
%
% A quotaMb of -1 means no quota.
% Disks can get full, disappear, etc, so non-ok state is used to signal issues.
%
% [{ssd, []},
%  {hdd, [[{path, /some/nice/disk/path}, {quotaMb, 1234}, {state, ok}],
%         [{path", /another/good/disk/path}, {quotaMb, 5678}, {state, ok}]]}]
%
storage_conf(Node, Config) ->
    HDDInfo = case dbdir(Config, Node) of
                  {ok, DBDir} -> [{path, misc:absname(DBDir)},
                                  {quotaMb, none},
                                  {state, ok}];
                  _ -> []
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
    DiskPaths = [proplists:get_value(path, X) || X <- proplists:get_value(hdd, storage_conf(Node, Config))],
    case memory_quota(Node, Config) of
        MemQuotaMB when is_integer(MemQuotaMB) ->
            {DiskTotal, DiskUsed} =
                lists:foldl(fun (Path, {ATotal, AUsed} = Tuple) ->
                                    %% move it over here
                                    case extract_disk_stats_for_path(DiskStats, Path) of
                                        none -> Tuple;
                                        {ok, {_MPoint, KBytesTotal, Cap}} ->
                                            Total = KBytesTotal * 1024,
                                            Used = (Total * Cap) div 100,
                                            {ATotal + Total,
                                             AUsed + Used}
                                    end
                            end, {0, 0}, DiskPaths),
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

nodes_storage_info(NodeNames) ->
    NodesDict = ns_doctor:get_nodes(),
    NodesInfos = lists:foldl(fun (N, A) ->
                                     case dict:find(N, NodesDict) of
                                         {ok, V} -> [{N, V} | A];
                                         _ -> A
                                     end
                             end, [], NodeNames),
    do_cluster_storage_info(NodesInfos).

cluster_storage_info() ->
    Config = ns_config:get(),
    DoctorNodes = ns_doctor:get_nodes(),
    Nodes = lists:foldl(fun (Node, Acc) ->
                              case dict:find(Node, DoctorNodes) of
                                  {ok, Info} -> [{Node, Info} | Acc];
                                  _ -> Acc
                              end
                      end, [], ns_cluster_membership:active_nodes()),
    PList1 = do_cluster_storage_info(Nodes),
    AllBuckets = ns_bucket:get_buckets(Config),
    RAMQuotaUsed = lists:foldl(fun ({_, BucketConfig}, RAMQuota) ->
                                       ns_bucket:ram_quota(BucketConfig) + RAMQuota
                               end, 0, AllBuckets),
    lists:map(fun ({ram, RAMList}) ->
                      {ram, [{quotaUsed, RAMQuotaUsed}
                             | RAMList]};
                  (X) -> X
              end, PList1).

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
    StorageInfos = [extract_node_storage_info(NodeInfo, Node, Config)
                    || {Node, NodeInfo} <- NodeInfos],
    HddTotals = extract_subprop(StorageInfos, hdd, total),
    HddUsed = extract_subprop(StorageInfos, hdd, used),
    PList1 = [{ram, [{total, lists:sum(extract_subprop(StorageInfos, ram, total))},
                     {quotaTotal, lists:sum(extract_subprop(StorageInfos, ram,
                                                            quotaTotal))},
                     {used, lists:sum(extract_subprop(StorageInfos, ram, used))}
                    ]},
              {hdd, [{total, lists:sum(HddTotals)},
                     {quotaTotal, lists:sum(HddTotals)},
                     {used, lists:sum(HddUsed)},
                     {free, lists:min(lists:zipwith(fun (A, B) -> A - B end,
                                                    HddTotals, HddUsed))
                      * length(HddUsed)} % Minimum amount free on any node * number of nodes
                    ]}],
    AllNodes = ordsets:intersection(lists:sort(ns_node_disco:nodes_actual_proper()),
                                    lists:sort(proplists:get_keys(NodeInfos))),
    AllBuckets = ns_bucket:get_buckets(Config),
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

db_files_dir(DBDir, Bucket) ->
    filename:join(DBDir, Bucket ++ "-data").

db_files(Dir, Bucket) ->
    BucketSubDir = db_files_dir(Dir, Bucket),
    S = fun (X) -> [X, X ++ "-shm", X ++ "-wal"] end,
    [filename:join(BucketSubDir, lists:append(Bucket, Suffix))
       || Suffix <- lists:flatmap(S, ["", "-0.mb", "-1.mb", "-2.mb", "-3.mb"])].

delete_buckets_db_files(DBDir, Pred) ->
    BucketDirs = filelib:wildcard("*-data", DBDir),
    delete_buckets_db_files_loop(DBDir, BucketDirs, Pred).

delete_buckets_db_files_loop(_, [], _Pred) ->
    ok;
delete_buckets_db_files_loop(DBDir, [D | Dirs], Pred) ->
    {match, [Bucket]} = re:run(D, "^\(.*\)-data$", [{capture, [1], list}]),
    case Pred(Bucket) of
        true ->
            R = delete_bucket_db_directory(filename:join(DBDir, D)),
            case R of
                ok ->
                    delete_buckets_db_files_loop(DBDir, Dirs, Pred);
                Error ->
                    Error
            end;
        false ->
            delete_buckets_db_files_loop(DBDir, Dirs, Pred)
    end.

delete_all_db_files() ->
    {ok, DBDir} = dbdir(),
    delete_all_db_files(DBDir).

delete_all_db_files(DBDir) ->
    delete_buckets_db_files(DBDir, fun (_) -> true end).

delete_bucket_db_directory(BucketDBDir) ->
    Result = misc:rm_rf(BucketDBDir),
    ?log_debug("Result of deleting db directory: ~p: ~p", [BucketDBDir, Result]),
    Result.

delete_db_files(Bucket) ->
    {ok, DBDir} = dbdir(ns_config:get()),
    BucketDBDir = db_files_dir(DBDir, Bucket),
    delete_bucket_db_directory(BucketDBDir).


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

db_files_test() ->
  ?assertEqual(["hello/world-data/world",
                "hello/world-data/world-shm",
                "hello/world-data/world-wal",
                "hello/world-data/world-0.mb",
                "hello/world-data/world-0.mb-shm",
                "hello/world-data/world-0.mb-wal",
                "hello/world-data/world-1.mb",
                "hello/world-data/world-1.mb-shm",
                "hello/world-data/world-1.mb-wal",
                "hello/world-data/world-2.mb",
                "hello/world-data/world-2.mb-shm",
                "hello/world-data/world-2.mb-wal",
                "hello/world-data/world-3.mb",
                "hello/world-data/world-3.mb-shm",
                "hello/world-data/world-3.mb-wal"],
                db_files("hello", "world")).

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
