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
         local_bucket_disk_usage/1, bucket_disk_usage/2]).

-export([node_storage_info/1, cluster_storage_info/0, nodes_storage_info/1]).

-export([extract_disk_stats_for_path/2, disk_stats_for_path/2]).

memory_quota(_Node) ->
    {value, RV} = ns_config:search(ns_config:get(), memory_quota),
    RV.

change_memory_quota(_Node, NewMemQuotaMB) when is_integer(NewMemQuotaMB) ->
    ns_config:set(memory_quota, NewMemQuotaMB),
    ns_bucket:update_bucket_props("default", [{ram_quota, NewMemQuotaMB * 1048576}]).

prepare_setup_disk_storage_conf(Node, Path) when Node =:= node() ->
    {value, PropList} = ns_config:search_node(Node, ns_config:get(), memcached),
    DBDir = filename:absname(proplists:get_value(dbdir, PropList)),
    NewDBDir = filename:absname(Path),
    PathOK = case DBDir of
                 NewDBDir -> ok;
                 _ ->
                     %% TODO: check permission to write
                     filelib:ensure_dir(Path),
                     case file:make_dir(Path) of
                         ok -> ok;
                         {error, eexist} -> ok;
                         _ -> error
                     end
             end,
    case PathOK of
        ok ->
            {ok, fun () ->
                         ns_config:set({node, node(), memcached},
                                       [{dbdir, Path}
                                        | lists:keydelete(dbdir, 1, PropList)]),

                         ns_memcached:sync_bucket_config("default")
                 end};
        X -> X
    end.

local_bucket_disk_usage(BucketName) ->
    {value, PropList} = ns_config:search_node(node(), ns_config:get(), memcached),
    DBDir = proplists:get_value(dbdir, PropList),
    {ok, Filenames} = file:list_dir(DBDir),
    OKFilenames = lists:filter(fun (Name) ->
                                       lists:prefix(BucketName, Name)
                               end, Filenames),
    %% this doesn't include filesystem slack
    lists:sum([filelib:file_size(filename:join([DBDir, Name])) || Name <- OKFilenames]).

bucket_disk_usage(Node, Bucket) ->
    {ok, Config} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(Config) of
        membase ->
            case rpc:call(Node, ns_storage_conf, local_bucket_disk_usage, [Bucket]) of
                {badrpc, _} ->
                    0;
                X -> X
            end;
        _ ->
            0
    end.

% Returns a proplist of lists of proplists.
%
% A quotaMb of -1 means no quota.
% Disks can get full, disappear, etc, so non-ok state is used to signal issues.
%
% [{ssd, []},
%  {hdd, [[{path, /some/nice/disk/path}, {quotaMb, 1234}, {state, ok}],
%         [{path", /another/good/disk/path}, {quotaMb, 5678}, {state, ok}]]}]
%
storage_conf(Node) ->
    {value, PropList} = ns_config:search_node(Node, ns_config:get(), memcached),
    HDDInfo = case proplists:get_value(dbdir, PropList) of
                  undefined -> [];
                  DBDir -> [{path, filename:absname(DBDir)},
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
    {RAMTotal, RAMUsed, _} = proplists:get_value(memory_data, NodeInfo),
    DiskStats = proplists:get_value(disk_data, NodeInfo),
    DiskPaths = [proplists:get_value(path, X) || X <- proplists:get_value(hdd, ns_storage_conf:storage_conf(Node))],
    case memory_quota(Node) of
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
                    {used, RAMUsed}]},
             {hdd, [{total, DiskTotal},
                    {quotaTotal, DiskTotal},
                    {used, DiskUsed}]}];
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
    Nodes = lists:filter(fun ({Node, _}) ->
                             ns_cluster_membership:get_cluster_membership(Node, Config) =:= active
                         end, dict:to_list(ns_doctor:get_nodes())),
    PList1 = do_cluster_storage_info(Nodes),
    AllBuckets = ns_bucket:get_buckets(),
    RAMQuotaUsed = lists:foldl(fun ({_, BucketConfig}, RAMQuota) ->
                                       ns_bucket:ram_quota(BucketConfig) + RAMQuota
                               end, 0, AllBuckets),
    lists:map(fun ({ram, RAMList}) ->
                      {ram, [{quotaUsed, RAMQuotaUsed}
                             | RAMList]};
                  (X) -> X
              end, PList1).

do_cluster_storage_info([]) -> [];
do_cluster_storage_info([{FirstNode, FirstInfo} | Rest] = NodeInfos) ->
    PList1 = lists:foldl(fun ({Node, Info}, Acc) ->
                                 ThisInfo = extract_node_storage_info(Info, Node),
                                 lists:zipwith(fun ({StatName, [{total, TotalA},
                                                                {quotaTotal, QTotalA},
                                                                {used, UsedA}]},
                                                    {StatName, [{total, TotalB},
                                                                {quotaTotal, QTotalB},
                                                                {used, UsedB}]}) ->
                                                       {StatName, [{total, TotalA + TotalB},
                                                                   {quotaTotal, QTotalA + QTotalB},
                                                                   {used, UsedA + UsedB}]}
                                               end, Acc, ThisInfo)
                         end, extract_node_storage_info(FirstInfo, FirstNode), Rest),
    AllNodes = proplists:get_keys(NodeInfos),
    AllBuckets = ns_bucket:get_buckets(),
    {BucketsRAMUsage, BucketsHDDUsage}
        = lists:foldl(fun ({Name, _}, {RAM, HDD}) ->
                              BasicStats = menelaus_stats:basic_stats(Name, AllNodes),
                              {RAM + proplists:get_value(memUsed, BasicStats),
                               HDD + proplists:get_value(diskUsed, BasicStats)}
                      end, {0, 0}, AllBuckets),
    lists:map(fun ({ram, Props}) ->
                      {ram, [{usedByData, BucketsRAMUsage}
                             | Props]};
                  ({hdd, Props}) ->
                      {hdd, [{usedByData, BucketsHDDUsage}
                             | Props]}
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

disk_stats_for_path(Node, Path) ->
    case rpc:call(Node, disksup, get_disk_data, [], 2000) of
        {badrpc, _} = Crap -> Crap;
        List -> case extract_disk_stats_for_path(List, Path) of
                    none -> none;
                    {ok, {_MPoint, KBytes, Cap}} -> {ok, KBytes, Cap}
                end
    end.

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
                                             "/media/p2/mbdata")).
-endif.
