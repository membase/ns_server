%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

% A module for retrieving & configuring per-server storage paths,
% storage quotas, mem quotas, etc.
%
-module(ns_storage_conf).

-export([memory_quota/1, change_memory_quota/2,
         storage_conf/1, change_storage_conf/2]).

memory_quota(_Node) -> none. % TODO.

change_memory_quota(_Node, _NewMemQuota) ->
  {error, todo}.

% Returns a proplist of lists of proplists.
%
% A quotaMb of -1 means no quota.
% Disks can get full, disappear, etc, so non-ok state is used to signal issues.
%
% [{"ssd", []},
%  {"hdd", [[{"path", "/some/nice/disk/path"}, {"quotaMb", 1234}, {"state", ok}],
%           [{"path", "/another/good/disk/path"}, {"quotaMb", 5678}, {"state", ok}]]}]
%
storage_conf(_Node) ->
    [{"ssd", []},
     {"hdd", [[{"path", "./data"}, {"quotaMb", none}, {"state", ok}]]}].

change_storage_conf(_Node, _NewConf) ->
    {error, todo}. % TODO.
