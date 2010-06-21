%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

% A module for retrieving & configuring per-server storage paths,
% storage quotas, mem quotas, etc.
%
-module(ns_storage_conf).

-export([memory_quota/1, change_memory_quota/2,
         storage_conf/1, add_storage/4, remove_storage/2, format_engine_max_size/0]).

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
    UpdatedProps = lists:map(fun ({max_size, _}) -> {max_size, Quota};
                                 (X) -> X
                             end, PropList),
    ns_config:set({node, Node, memcached}, UpdatedProps),
    ok.

change_memory_quota(Node, none) ->
    update_max_size(Node, none);

change_memory_quota(Node, NewMemQuotaMB) when is_integer(NewMemQuotaMB) ->
    update_max_size(Node, NewMemQuotaMB).

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
    HDDInfo = case proplists:get_value(dbname, PropList) of
                  undefined -> [];
                  DBName -> [{path, filename:absname(DBName)},
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
