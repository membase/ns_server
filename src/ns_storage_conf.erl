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

-export([memory_quota/1, change_memory_quota/2, prepare_setup_disk_storage_conf/2,
         storage_conf/1, add_storage/4, remove_storage/2, format_engine_max_size/0,
         local_bucket_disk_usage/1, bucket_disk_usage/2]).

-export([node_storage_info/1, cluster_storage_info/0]).

-export([extract_disk_stats_for_path/2, disk_stats_for_path/2]).

format_engine_max_size() ->
    RawValue = ns_config:search_node_prop(ns_config:get(), memcached, max_size),
    case RawValue of
        undefined -> "";
        X -> io_lib:format(";max_size=~B", [X * 1048576])
    end.

memory_quota(Node) ->
    {value, PropList} = ns_config:search_node(Node, ns_config:get(), memcached),
    proplists:get_value(max_size, PropList).

update_max_size(Node, Quota) ->
    {value, PropList} = ns_config:search_node(Node, ns_config:get(), memcached),
    UpdatedProps = misc:key_update(max_size, PropList, fun (_) -> Quota end),
    ns_config:set({node, Node, memcached}, UpdatedProps),
    case ns_bucket:get_bucket("default") of
        {ok, Config} ->
            case ns_bucket:ram_quota(Config) of
                0 ->
                    ns_bucket:update_bucket_props("default", [{ram_quota, Quota * 1048576}]),
                    ok%% ;
                %% _ -> ok
            end%% ;
        %% _ -> ok
    end.

change_memory_quota(Node, none) ->
    update_max_size(Node, none);

change_memory_quota(Node, NewMemQuotaMB) when is_integer(NewMemQuotaMB) ->
    update_max_size(Node, NewMemQuotaMB).

prepare_setup_disk_storage_conf(Node, Path) when Node =:= node() ->
    {value, PropList} = ns_config:search_node(Node, ns_config:get(), memcached),
    DBName = filename:absname(proplists:get_value(dbname, PropList)),
    {ok, NodeInfo} = dict:find(Node, ns_doctor:get_nodes()),
    NewDBName = filename:absname(filename:join(Path, "default")),
    PathOK = case DBName of
                 NewDBName -> ok;
                 _ ->
                     filelib:ensure_dir(Path),
                     case file:make_dir(Path) of
                         ok -> ok;
                         _ -> error
                     end
             end,
    case PathOK of
        ok ->
            {ok, fun () ->
                         %% we need to setup disk quota for node & default bucket
                         DiskStats = proplists:get_value(disk_data, NodeInfo),
                         {ok, {_MPoint, KBytesTotal, Cap}} = extract_disk_stats_for_path(DiskStats, NewDBName),
                         Total = KBytesTotal * 1024,
                         Used = (Total * Cap) div 100,
                         FreeMB = (Total - Used) div 1048576,

                         ns_config:set({node, node(), memcached},
                                       [{dbname, NewDBName},
                                        {hdd_quota, FreeMB}
                                        | lists:keydelete(dbname, 1, PropList)]),

                         ns_bucket:update_bucket_props("default", [{hdd_quota, FreeMB * 1048576}])
                 end};
        X -> X
    end.

local_bucket_disk_usage("default" = _Bucket) ->
    {value, PropList} = ns_config:search_node(node(), ns_config:get(), memcached),
    DBPath = proplists:get_value(dbname, PropList),
    DBDir = filename:dirname(DBPath),
    {ok, Filenames} = file:list_dir(DBDir),
    %% this doesn't include filesystem slack
    lists:sum([filelib:file_size(filename:join([DBDir, Name])) || Name <- Filenames]).

bucket_disk_usage(Node, Bucket) ->
    case rpc:call(Node, ns_storage_conf, local_bucket_disk_usage, [Bucket]) of
        {badrpc, _} ->
            0;
        X -> X
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
    DBName = misc:expect_prop_value(dbname, PropList),
    HDDQuotaMB = misc:expect_prop_value(hdd_quota, PropList),
    HDDInfo = [{path, filename:nativename(filename:dirname(filename:absname(DBName)))},
               {quotaMb, HDDQuotaMB},
               {state, ok}],
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
    DiskPathes = [proplists:get_value(path, X) || X <- proplists:get_value(hdd, ns_storage_conf:storage_conf(Node))],
    [{ssd, _},
     {hdd, [HDDProps]}] = storage_conf(Node),
    MemQuotaMB = memory_quota(Node),
    HDDQuotaMB = misc:expect_prop_value(quotaMb, HDDProps),
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
                    end, {0, 0}, DiskPathes),
    [{ram, [{total, RAMTotal},
            {quotaTotal, MemQuotaMB * 1048576},
            {used, RAMUsed}]},
     {hdd, [{total, DiskTotal},
            {quotaTotal, HDDQuotaMB * 1048576},
            {used, DiskUsed}]}].

cluster_storage_info() ->
    Nodes = dict:to_list(ns_doctor:get_nodes()),
    PList1 = case Nodes of
                 [] -> [];
                 [{FirstNode, FirstInfo} | Rest] ->
                     lists:foldl(fun ({Node, Info}, Acc) ->
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
                                 end, extract_node_storage_info(FirstInfo, FirstNode), Rest)
             end,
    {RAMQuotaUsed, HDDQuotaUsed} =
        lists:foldl(fun ({_, Config}, {RAMQuota, HDDQuota}) ->
                            RepN = ns_bucket:num_replicas(Config),
                            {ns_bucket:ram_quota(Config) * RepN + RAMQuota,
                             ns_bucket:hdd_quota(Config) * RepN + HDDQuota}
                    end, {0, 0}, ns_bucket:get_buckets()),
    lists:map(fun ({ram, Props}) ->
                      {ram, [{quotaUsed, RAMQuotaUsed} | Props]};
                  ({hdd, Props}) ->
                      {hdd, [{quotaUsed, HDDQuotaUsed} | Props]}
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
    extract_disk_stats_for_path_rec(StatsList, Path).

disk_stats_for_path(Node, Path) ->
    case rpc:call(Node, disksup, get_disk_data, [], 2000) of
        {badrpc, _} = Crap -> Crap;
        List -> case extract_disk_stats_for_path(List, Path) of
                    none -> none;
                    {ok, {_MPoint, KBytes, Cap}} -> {ok, KBytes, Cap}
                end
    end.
