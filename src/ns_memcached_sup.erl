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

ns_memcached_data_child_specs(BucketName, NumInstances) ->
    [{{ns_memcached, data, BucketName, Id}, {ns_memcached, start_link,
                                             [{BucketName, data, Id}]},
      permanent, brutal_kill, worker, [ns_memcached]}
     || Id <- lists:seq(1, NumInstances)].

child_specs(BucketName) ->
    [{{ns_memcached, stats, BucketName, 0}, {ns_memcached, start_link,
                                             [{BucketName, stats, 0}]},
      %% ns_memcached waits for the bucket to sync to disk before exiting
      permanent, 86400000, worker, [ns_memcached]}] ++

    ns_memcached_data_child_specs(
        BucketName, misc:getenv_int("NUM_NS_MEMCACHED_DATA_INSTANCES",
                                    ?NUM_NS_MEMCACHED_DATA_INSTANCES)) ++

    [{{ns_vbm_sup, BucketName}, {ns_vbm_sup, start_link, [BucketName]},
      permanent, 1000, worker, [ns_vbm_sup]},
     {{ns_vbm_new_sup, BucketName}, {ns_vbm_new_sup, start_link, [BucketName]},
      permanent, 1000, supervisor, [ns_vbm_new_sup]},
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
