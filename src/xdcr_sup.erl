%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
-module(xdcr_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([link_stats_holder_body/0]).

-include("ns_common.hrl").

start_link() ->
    supervisor:start_link(?MODULE, []).

init([]) ->
    {ok, {{one_for_all, 3, 10}, child_specs()}}.

link_stats_holder_body() ->
    xdc_rep_utils:create_stats_table(),
    proc_lib:init_ack({ok, self()}),
    receive
        _ -> ok
    end.

child_specs() ->
    [{xdc_stats_holder,
      {proc_lib, start_link, [?MODULE, link_stats_holder_body, []]},
      permanent, 1000, worker, []},

     {xdc_replication_sup,
      {xdc_replication_sup, start_link, []},
      permanent, infinity, supervisor, [xdc_replication_sup]},

     {xdc_rep_manager,
      {xdc_rep_manager, start_link, []},
      permanent, 30000, worker, []},

     {xdc_rdoc_replicator,
      {doc_replicator, start_link, [xdcr]},
      permanent, 1000, worker, [doc_replicator]},

     {xdc_rdoc_replication_srv, {doc_replication_srv, start_link, [xdcr]},
      permanent, 1000, worker, [doc_replication_srv]},

     {wait_for_couchdb_node, {ns_couchdb_api, wait_for_name, [last_process]},
      transient, brutal_kill, worker, []},

     {xdc_rdoc_manager, {xdc_rdoc_manager, start_link_remote, [ns_node_disco:couchdb_node()]},
      permanent, 1000, worker, []}].
