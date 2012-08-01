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

-behaviour(supervisor).

-include("ns_common.hrl").

-export([node_name_changed/0,
         start_link/0]).

-export([init/1]).


%% @doc Notify the supervisor that the node's name has changed so it
%% can restart children that care.
node_name_changed() ->
    ok = supervisor:terminate_child(?MODULE, ns_doctor),
    {ok, _} = supervisor:restart_child(?MODULE, ns_doctor),
    ok = supervisor:terminate_child(?MODULE, mb_master),
    {ok, _} = supervisor:restart_child(?MODULE, mb_master),
    ok.


start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

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
    [%% ns_log starts after ns_config because it needs the config to
     %% find where to persist the logs
     {ns_log, {ns_log, start_link, []},
      permanent, 1000, worker, [ns_log]},

     {ns_config_ets_dup, {ns_config_ets_dup, start_link, []},
      permanent, brutal_kill, worker, [ns_config, ns_config_ets_dup]},

     {ns_log_events, {gen_event, start_link, [{local, ns_log_events}]},
      permanent, 1000, worker, dynamic},

     {ns_node_disco_sup, {ns_node_disco_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_node_disco_sup]},

     {vbucket_map_mirror, {vbucket_map_mirror, start_link, []},
      permanent, brutal_kill, worker, []},

     %% Start ns_tick_event before mb_master as auto_failover needs it
     {ns_tick_event, {gen_event, start_link, [{local, ns_tick_event}]},
      permanent, 1000, worker, dynamic},

     {mb_master_events, {gen_event, start_link, [{local, mb_master_events}]},
      permanent, 1000, worker, dynamic},

     {buckets_events, {gen_event, start_link, [{local, buckets_events}]},
      permanent, 1000, worker, dynamic},

     {ns_mail_sup, {ns_mail_sup, start_link, []},
      permanent, infinity, supervisor, [ns_mail_sup]},

     {ns_stats_event, {gen_event, start_link, [{local, ns_stats_event}]},
      permanent, 1000, worker, dynamic},

     {ns_heart, {ns_heart, start_link, []},
      permanent, 1000, worker, [ns_heart]},

     {ns_doctor, {ns_doctor, start_link, []},
      permanent, 1000, worker, [ns_doctor]},

     {remote_clusters_info, {remote_clusters_info, start_link, []},
      permanent, 1000, worker, [remote_servers_info]},

     {menelaus, {menelaus_sup, start_link, []},
      permanent, infinity, supervisor,
      [menelaus_sup]},

     {mc_sup, {mc_sup, start_link, []},
      permanent, infinity, supervisor, dynamic},

     {ns_port_sup, {ns_port_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_port_sup]},

     {ns_port_memcached_killer, {ns_port_sup, start_memcached_force_killer, []},
      permanent, brutal_kill, worker, [ns_port_sup]},

     {ns_bucket_worker, {work_queue, start_link, [ns_bucket_worker]},
      permanent, 1000, worker, [work_queue]},

     %% per-vbucket replication supervisor, required by XDC manager
     {xdc_vbucket_rep_sup,
      {xdc_vbucket_rep_sup, start_link, []},
      permanent, infinity, supervisor, [xdc_vbucket_rep_sup]},

     %% XDC replication manager
     %% per-bucket supervisor needs xdc_rep_manager. In fact any couch
     %% replication requires xdc_rep_manager to be started, because it
     %% relies on some public ETS tables.
     {xdc_rep_manager,
      {xdc_rep_manager, start_link, []},
      permanent, 30000, worker, []},

     %% Starts mb_master_sup, which has all processes that start on the master
     %% node.
     {mb_master, {mb_master, start_link, []},
      permanent, infinity, supervisor, [mb_master]},

     {master_activity_events, {gen_event, start_link, [{local, master_activity_events}]},
      permanent, brutal_kill, worker, dynamic},

     {master_activity_events_ingress, {gen_event, start_link, [{local, master_activity_events_ingress}]},
      permanent, brutal_kill, worker, dynamic},

     {master_activity_events_timestamper, {master_activity_events, start_link_timestamper, []},
      permanent, brutal_kill, worker, dynamic},

     {master_activity_events_pids_watcher, {master_activity_events_pids_watcher, start_link, []},
      permanent, brutal_kill, worker, dynamic},

     {master_activity_events_keeper, {master_activity_events_keeper, start_link, []},
      permanent, brutal_kill, worker, dynamic},

     {ns_bucket_sup, {ns_bucket_sup, start_link, []},
      permanent, infinity, supervisor, [ns_bucket_sup]},

     {system_stats_collector, {system_stats_collector, start_link, []},
      permanent, 1000, worker, [system_stats_collector]},

     {{stats_archiver, "@system"}, {stats_archiver, start_link, ["@system"]},
      permanent, 1000, worker, [stats_archiver]},

     {{stats_reader, "@system"}, {stats_reader, start_link, ["@system"]},
      permanent, 1000, worker, [start_reader]},

     {ns_moxi_sup_work_queue, {work_queue, start_link, [ns_moxi_sup_work_queue]},
      permanent, 1000, worker, [work_queue]},

     {ns_moxi_sup, {ns_moxi_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_moxi_sup]},

     {compaction_daemon,
      {supervisor_cushion, start_link,
       [compaction_daemon, 3000, 1000, compaction_daemon, start_link, []]},
      permanent, 86400000, worker, [compaction_daemon]},

     {xdc_rdoc_replication_srv, {xdc_rdoc_replication_srv, start_link, []},
      permanent, 1000, worker, [xdc_rdoc_replication_srv]},

     {set_view_update_daemon, {set_view_update_daemon, start_link, []},
      permanent, 1000, worker, [set_view_update_daemon]}
].
