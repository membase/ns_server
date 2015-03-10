%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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

-module(single_bucket_kv_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-export([start_link/1, init/1]).


start_link(BucketName) ->
    Name = list_to_atom(atom_to_list(?MODULE) ++ "-" ++ BucketName),
    supervisor:start_link({local, Name}, ?MODULE, [BucketName]).

child_specs(BucketName) ->
    [{{docs_kv_sup, BucketName}, {docs_kv_sup, start_link, [BucketName]},
      permanent, infinity, supervisor, [docs_kv_sup]},
     {{ns_memcached_sup, BucketName}, {ns_memcached_sup, start_link, [BucketName]},
      permanent, infinity, supervisor, [ns_memcached_sup]},
     {{ns_vbm_sup, BucketName}, {ns_vbm_sup, start_link, [BucketName]},
      permanent, infinity, supervisor, [ns_vbm_sup]},
     {{dcp_sup, BucketName}, {dcp_sup, start_link, [BucketName]},
      permanent, infinity, supervisor, [dcp_sup]},
     {{replication_manager, BucketName}, {replication_manager, start_link, [BucketName]},
      permanent, 1000, worker, []},
     {{dcp_notifier, BucketName}, {dcp_notifier, start_link, [BucketName]},
      permanent, 1000, worker, []},
     {{janitor_agent_sup, BucketName}, {janitor_agent_sup, start_link, [BucketName]},
      permanent, 10000, worker, [janitor_agent_sup]},
     {{stats_collector, BucketName}, {stats_collector, start_link, [BucketName]},
      permanent, 1000, worker, [stats_collector]},
     {{stats_archiver, BucketName}, {stats_archiver, start_link, [BucketName]},
      permanent, 1000, worker, [stats_archiver]},
     {{stats_reader, BucketName}, {stats_reader, start_link, [BucketName]},
      permanent, 1000, worker, [stats_reader]},
     {{goxdcr_stats_collector, BucketName}, {goxdcr_stats_collector, start_link, [BucketName]},
      permanent, 1000, worker, [goxdcr_stats_collector]},
     {{goxdcr_stats_archiver, BucketName}, {stats_archiver, start_link, ["@goxdcr-" ++ BucketName]},
      permanent, 1000, worker, [stats_archiver]},
     {{goxdcr_stats_reader, BucketName}, {stats_reader, start_link, ["@goxdcr-" ++ BucketName]},
      permanent, 1000, worker, [stats_reader]},
     {{failover_safeness_level, BucketName},
      {failover_safeness_level, start_link, [BucketName]},
      permanent, 1000, worker, [failover_safeness_level]}].

init([BucketName]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          child_specs(BucketName)}}.
