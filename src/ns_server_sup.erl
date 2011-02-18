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
    [%% Starts mb_master_sup, which has all processes that start on the master
     %% node.
     {mb_master, {mb_master, start_link, []},
      permanent, infinity, supervisor, [mb_master]},

     %% ns_log starts after ns_config because it needs the config to
     %% find where to persist the logs
     {ns_log, {ns_log, start_link, []},
      permanent, 10, worker, [ns_log]},

     {ns_log_events, {gen_event, start_link, [{local, ns_log_events}]},
      permanent, 10, worker, dynamic},

     {ns_mail_sup, {ns_mail_sup, start_link, []},
      permanent, infinity, supervisor, [ns_mail_sup]},

     {ns_node_disco_sup, {ns_node_disco_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_node_disco_sup]},

     {ns_heart, {ns_heart, start_link, []},
      permanent, 10, worker, [ns_heart]},

     {ns_doctor, {ns_doctor, start_link, []},
      permanent, 10, worker, [ns_doctor]},

     {menelaus, {menelaus_app, start_subapp, []},
      permanent, infinity, supervisor,
      [menelaus_app]},

     {ns_port_sup, {ns_port_sup, start_link, []},
      permanent, 10, worker,
      [ns_port_sup]},

     {ns_tick_event, {gen_event, start_link, [{local, ns_tick_event}]},
      permanent, 10, worker, dynamic},

     {ns_stats_event, {gen_event, start_link, [{local, ns_stats_event}]},
      permanent, 10, worker, dynamic},

     {ns_bucket_worker, {work_queue, start_link, [ns_bucket_worker]},
      permanent, 10, worker, [work_queue]},

     {ns_bucket_sup, {ns_bucket_sup, start_link, []},
      permanent, infinity, supervisor, [ns_bucket_sup]},

     {ns_orchestrator, {ns_orchestrator, start_link, []},
      permanent, 20, worker, [ns_orchestrator]},

     {ns_moxi_sup, {ns_moxi_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_moxi_sup]},

     {moxi_stats_collector, {supervisor_cushion, start_link,
                             [moxi_stats_collector, 5000, moxi_stats_collector,
                              start_link, []]},
      permanent, 10, worker, [moxi_stats_collector, supervisor_cushion]},

     {ns_tick, {ns_tick, start_link, []},
      permanent, 10, worker, [ns_tick]}].
