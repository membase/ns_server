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
-module(ns_server_cluster_sup).

-behavior(supervisor).

%% API
-export ([start_link/0, restart/0]).

%% Supervisor callbacks
-export([init/1]).

%%
%% API
%%

%% @doc Start the supervisor
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%
%% Supervisor callbacks
%%

init([]) ->
    {ok, {{one_for_one, 10, 1},
          [{local_tasks, {local_tasks, start_link, []},
            permanent, brutal_kill, worker, [local_tasks]},
           {log_os_info, {log_os_info, start_link, []},
            transient, 1000, worker, [log_os_info]},
           {timeout_diag_logger, {timeout_diag_logger, start_link, []},
            permanent, 1000, worker, [timeout_diag_logger, diag_handler]},
           {dist_manager, {dist_manager, start_link, []},
            permanent, 1000, worker, [dist_manager]},
           {ns_cookie_manager,
            {ns_cookie_manager, start_link, []},
            permanent, 1000, worker, []},
           {ns_cluster, {ns_cluster, start_link, []},
            permanent, 5000, worker, [ns_cluster]},
           {ns_config_sup, {ns_config_sup, start_link, []},
            permanent, infinity, supervisor,
            [ns_config_sup]},
           {vbucket_filter_changes_registry,
            {ns_process_registry, start_link,
             [vbucket_filter_changes_registry, [{terminate_command, shutdown}]]},
            permanent, 100, worker, [ns_process_registry]},
           {ns_server_nodes_sup, {ns_server_nodes_sup, start_link, []},
            permanent, infinity, supervisor, [ns_server_nodes_sup]}
          ]}}.

restart() ->
    %% NOTE: starting and stopping in usual way is surprisingly
    %% hard. Because we normally do that from process which
    %% group_leader is application_master of ns_server application. So
    %% we just terminate and restart all childs instead.
    {ok, {_, ChildSpecs}} = init([]),
    %% we don't restart dist manager in order to avoid shutting
    %% down/restarting net_kernel
    DontRestart = [dist_manager, ns_server_nodes_sup],
    ChildIds = [element(1, Spec) || Spec <- ChildSpecs] -- DontRestart,
    ns_server_nodes_sup:stop_ns_server(),
    [supervisor:terminate_child(?MODULE, Id) || Id <- lists:reverse(ChildIds)],
    [supervisor:restart_child(?MODULE, Id) || Id <- ChildIds],
    ns_couchdb_api:restart_couch(),
    ns_server_nodes_sup:start_ns_server().
