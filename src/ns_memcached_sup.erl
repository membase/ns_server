%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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

-module(ns_memcached_sup).

-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-include("ns_common.hrl").

start_link(BucketName) ->
    Name = list_to_atom(?MODULE_STRING ++ "-" ++ BucketName),
    supervisor:start_link({local, Name}, ?MODULE, [BucketName]).

child_specs(BucketName) ->
    [{{capi_set_view_manager, BucketName},
      {capi_set_view_manager, start_link, [BucketName]},
      permanent, 1000, worker, [capi_set_view_manager]},
     {{ns_memcached, BucketName}, {ns_memcached, start_link, [BucketName]},
      %% sometimes bucket deletion is slow. NOTE: we're not deleting
      %% bucket on system shutdown anymore
      permanent, 86400000, worker, [ns_memcached]},
     {{tap_replication_manager, BucketName}, {tap_replication_manager, start_link, [BucketName]},
      permanent, 1000, worker, []},
     {{ns_vbm_new_sup, BucketName}, {ns_vbm_new_sup, start_link, [BucketName]},
      permanent, infinity, supervisor, [ns_vbm_new_sup]},
     {{ns_vbm_sup, BucketName}, {ns_vbm_sup, start_link, [BucketName]},
      permanent, 1000, supervisor, []},
     {{janitor_agent, BucketName}, {janitor_agent, start_link, [BucketName]},
      permanent, brutal_kill, worker, []},
     {{couch_stats_reader, BucketName},
      {couch_stats_reader, start_link, [BucketName]},
      permanent, 1000, worker, [couch_stats_reader]},
     {{stats_collector, BucketName}, {stats_collector, start_link, [BucketName]},
      permanent, 1000, worker, [stats_collector]},
     {{stats_archiver, BucketName}, {stats_archiver, start_link, [BucketName]},
      permanent, 1000, worker, [stats_archiver]},
     {{stats_reader, BucketName}, {stats_reader, start_link, [BucketName]},
      permanent, 1000, worker, [stats_reader]},
     {{failover_safeness_level, BucketName},
      {failover_safeness_level, start_link, [BucketName]},
      permanent, 1000, worker, [failover_safeness_level]}].

init([BucketName]) ->
    {ok, {{rest_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          child_specs(BucketName)}}.
