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
-module(ns_server_sup).

-behaviour(supervisor2).

-include("ns_common.hrl").

%% API

-export([node_name_changed/0,
         start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

%% @doc Notify the supervisor that the node's name has changed so it
%% can restart children that care.
node_name_changed() ->
    {ok, _} = restartable:restart(?MODULE, ns_doctor),
    {ok, _} = restartable:restart(?MODULE, mb_master),
    ok.


start_link() ->
    supervisor2:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    pre_start(),
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          child_specs()}}.

pre_start() ->
    misc:make_pidfile(),
    misc:ping_jointo().

child_specs() ->
    [{ns_disksup, {ns_disksup, start_link, []},
      {permanent, 4}, 1000, worker, []},

     {diag_handler_worker, {work_queue, start_link, [diag_handler_worker]},
      permanent, 1000, worker, []},

     {dir_size, {dir_size, start_link, []},
      permanent, 1000, worker, [dir_size]},

     {request_throttler, {request_throttler, start_link, []},
      permanent, 1000, worker, [request_throttler]},

     %% ns_log starts after ns_config because it needs the config to
     %% find where to persist the logs
     {ns_log, {ns_log, start_link, []},
      permanent, 1000, worker, [ns_log]},

     {ns_crash_log_consumer, {ns_log, start_link_crash_consumer, []},
      {permanent, 4}, 1000, worker, []},

     %% Track bucket configs and ensure isasl is sync'd up
     {ns_config_isasl_sync, {ns_config_isasl_sync, start_link, []},
      permanent, 1000, worker, []},

     {ns_log_events, {gen_event, start_link, [{local, ns_log_events}]},
      permanent, 1000, worker, dynamic},

     {ns_node_disco_sup, {ns_node_disco_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_node_disco_sup]},

     {vbucket_map_mirror, {vbucket_map_mirror, start_link, []},
      permanent, brutal_kill, worker, []},

     {bucket_info_cache, {bucket_info_cache, start_link, []},
      permanent, brutal_kill, worker, []},

     %% Start ns_tick_event before mb_master as auto_failover needs it
     {ns_tick_event, {gen_event, start_link, [{local, ns_tick_event}]},
      permanent, 1000, worker, dynamic},

     {buckets_events, {gen_event, start_link, [{local, buckets_events}]},
      permanent, 1000, worker, dynamic},

     {ns_mail_sup, {ns_mail_sup, start_link, []},
      permanent, infinity, supervisor, [ns_mail_sup]},

     {ns_stats_event, {gen_event, start_link, [{local, ns_stats_event}]},
      permanent, 1000, worker, dynamic},

     {samples_loader_tasks, {samples_loader_tasks, start_link, []},
      permanent, 1000, worker, []},

     {ns_heart_sup, {ns_heart_sup, start_link, []},
      permanent, infinity, supervisor, [ns_heart_sup]},

     restartable:spec(
       {ns_doctor, {ns_doctor, start_link, []},
        permanent, 1000, worker, [ns_doctor]}),

     {remote_clusters_info, {remote_clusters_info, start_link, []},
      permanent, 1000, worker, [remote_servers_info]},

     {master_activity_events, {gen_event, start_link, [{local, master_activity_events}]},
      permanent, brutal_kill, worker, dynamic},

     %% Starts mb_master_sup, which has all processes that start on the master
     %% node.
     restartable:spec(
       {mb_master, {mb_master, start_link, []},
        permanent, infinity, supervisor, [mb_master]}),

     {master_activity_events_ingress, {gen_event, start_link, [{local, master_activity_events_ingress}]},
      permanent, brutal_kill, worker, dynamic},

     {master_activity_events_timestamper, {master_activity_events, start_link_timestamper, []},
      permanent, brutal_kill, worker, dynamic},

     {master_activity_events_pids_watcher, {master_activity_events_pids_watcher, start_link, []},
      permanent, brutal_kill, worker, dynamic},

     {master_activity_events_keeper, {master_activity_events_keeper, start_link, []},
      permanent, brutal_kill, worker, dynamic},

     {xdcr_ckpt_store,
      {simple_store, start_link, [?XDCR_CHECKPOINT_STORE]},
      permanent, 1000, worker, []},

     {metakv_worker,
      {work_queue, start_link, [metakv_worker]},
      permanent, 1000, worker, []},

     {index_events,
      {gen_event, start_link, [{local, index_events}]},
      permanent, brutal_kill, worker, dynamic},

     {index_settings_manager, {index_settings_manager, start_link, []},
      permanent, 1000, worker, [index_settings_manager]},

     {menelaus, {menelaus_sup, start_link, []},
      permanent, infinity, supervisor,
      [menelaus_sup]},

     %% Note: many of the processes started by ns_ports_setup try to connect
     %% to ns_server rest port for various reasons. So ns_ports_setup needs to
     %% go after menelaus_sup.
     {ns_ports_setup, {ns_ports_setup, start, []},
      {permanent, 4}, brutal_kill, worker, []},

     {ns_memcached_sockets_pool, {ns_memcached_sockets_pool, start_link, []},
      permanent, 1000, worker, []},

     {ns_audit_cfg, {ns_audit_cfg, start_link, []},
      {permanent, 4}, 1000, worker, []},

     {memcached_config_mgr, {memcached_config_mgr, start_link, []},
      {permanent, 4}, 1000, worker, []},

     {ns_memcached_log_rotator, {ns_memcached_log_rotator, start_link, []},
      permanent, 1000, worker, [ns_memcached_log_rotator]},

     {memcached_clients_pool, {memcached_clients_pool, start_link, []},
      permanent, 1000, worker, []},

     {proxied_memcached_clients_pool, {proxied_memcached_clients_pool, start_link, []},
      permanent, 1000, worker, []},

     %% this may spuriously fails sometimes when our xdcr workers
     %% crash and exit message is sent to this guy supposedly via
     %% socket links (there's brief window of time when both
     %% lhttpc_client process and this guy are linked to socket as
     %% part of passing ownership to client).
     %%
     %% When this crash happens we usually end up crashing
     %% continuously because all clients are sending done back to new
     %% process and new process, unaware of old clients, crashes. And
     %% it happens continuously and may cause
     %% reached_max_restart_intensity.
     %%
     %% So in order to at least prevent max restart intensity
     %% condition we just use supervisor2 feature to keep restarting
     %% this sucker. Due to restart delay we should reach condition
     %% when all clients have died and new guy won't receive done-s.
     {xdc_lhttpc_pool, {lhttpc_manager, start_link, [[{name, xdc_lhttpc_pool}, {connection_timeout, 120000}, {pool_size, 200}]]},
      {permanent, 1}, 10000, worker, [lhttpc_manager]},

     {ns_null_connection_pool, {ns_null_connection_pool, start_link, [ns_null_connection_pool]},
      permanent, 1000, worker, []},

     %% xdcr subsystem supervisor
     {xdcr_sup,
      {xdcr_sup, start_link, []},
      permanent, infinity, supervisor, []},

     {xdcr_dcp_sockets_pool, {xdcr_dcp_sockets_pool, start_link, []},
      permanent, 1000, worker, []},

     {ns_bucket_worker_sup, {ns_bucket_worker_sup, start_link, []},
      permanent, infinity, supervisor, [ns_bucket_worker_sup]},

     {system_stats_collector, {system_stats_collector, start_link, []},
      permanent, 1000, worker, [system_stats_collector]},

     {{stats_archiver, "@system"}, {stats_archiver, start_link, ["@system"]},
      permanent, 1000, worker, [stats_archiver]},

     {{stats_reader, "@system"}, {stats_reader, start_link, ["@system"]},
      permanent, 1000, worker, [start_reader]},

     {{stats_archiver, "@system-processes"}, {stats_archiver, start_link, ["@system-processes"]},
      permanent, 1000, worker, [stats_archiver]},

     {{stats_reader, "@system-processes"}, {stats_reader, start_link, ["@system-processes"]},
      permanent, 1000, worker, [start_reader]},

     {{stats_archiver, "@query"}, {stats_archiver, start_link, ["@query"]},
      permanent, 1000, worker, [stats_archiver]},

     {{stats_reader, "@query"}, {stats_reader, start_link, ["@query"]},
      permanent, 1000, worker, [stats_reader]},

     {query_stats_collector, {query_stats_collector, start_link, []},
      permanent, 1000, worker, []},

     {{stats_archiver, "@global"}, {stats_archiver, start_link, ["@global"]},
      permanent, 1000, worker, [stats_archiver]},

     {{stats_reader, "@global"}, {stats_reader, start_link, ["@global"]},
      permanent, 1000, worker, [stats_reader]},

     {global_stats_collector, {global_stats_collector, start_link, []},
      permanent, 1000, worker, [global_stats_collector]},

     {goxdcr_status_keeper, {goxdcr_status_keeper, start_link, []},
      permanent, 1000, worker, [goxdcr_status_keeper]},

     {index_stats_sup, {index_stats_sup, start_link, []},
      permanent, infinity, supervisor, []},

     {compaction_daemon, {compaction_daemon, start_link, []},
      permanent, 1000, worker, [compaction_daemon]},

     {compaction_new_daemon, {compaction_new_daemon, start_link, []},
      {permanent, 4}, 86400000, worker, [compaction_new_daemon]},

     {cluster_logs_sup, {cluster_logs_sup, start_link, []},
      permanent, infinity, supervisor, []},

     {remote_api, {remote_api, start_link, []},
      permanent, 1000, worker, [remote_api]}].
