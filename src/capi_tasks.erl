%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(capi_tasks).

-include("ns_common.hrl").
-include("couch_db.hrl").

-export([cluster_tasks_req/1]).

-define(TIMEOUT, 10000).

cluster_tasks_req(#httpd{method='GET'}=Req) ->
    Nodes = ns_node_disco:nodes_actual(),
    Tasks = fetch_tasks(Nodes),
    couch_httpd:send_json(Req, 200, {Tasks});
cluster_tasks_req(Req) ->
    couch_httpd:send_method_not_allowed(Req, "GET").

fetch_tasks(Nodes) ->
    misc:parallel_map(
      fun (Node) ->
              {Node, fetch_node_tasks(Node)}
      end,
      Nodes, infinity).

fetch_node_tasks(Node) when Node =:= node() ->
    [{Task} || Task <- capi_frontend:task_status_all()];
fetch_node_tasks(Node) ->
    case rpc:call(Node, capi_frontend, task_status_all, [], ?TIMEOUT) of
        {badrpc, Reason} ->
            ?log_info("Failed to get tasks status of ~p node: ~p",
                      [Node, Reason]),
            [];
        Tasks ->
            [{Task} || Task <- Tasks]
    end.
