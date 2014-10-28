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
%%
%% @doc supervisor that ensures that the whole ns_server_sup will be restarted
%%      if couchdb_node port crashes
%%

-module(ns_server_nodes_sup).

-include("ns_common.hrl").

-behaviour(supervisor).

%% API
-export([start_link/0, start_couchdb_node/0, start_ns_server/0, stop_ns_server/0]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor2:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {rest_for_one,
            misc:get_env_default(max_r, 3),
            misc:get_env_default(max_t, 10)}, child_specs()} }.

%% @doc Start child after its been stopped
start_ns_server() ->
    supervisor:restart_child(?MODULE, ns_server_sup).

%% @doc Stop ns_server_sup
stop_ns_server() ->
    supervisor:terminate_child(?MODULE, ns_server_sup).

child_specs() ->
    [
     {setup_node_names,
      {ns_server, setup_node_names, []},
      transient, brutal_kill, worker, []},

     {start_couchdb_node, {?MODULE, start_couchdb_node, []},
      {permanent, 5000}, 1000, worker, []},

     {ns_server_sup, {ns_server_sup, start_link, []},
      permanent, infinity, supervisor, [ns_server_sup]}].

create_ns_couchdb_spec() ->
    CouchIni = case init:get_argument(couch_ini) of
                   error ->
                       [];
                   {ok, [[]]} ->
                       [];
                   {ok, [Values]} ->
                       ["-couch_ini" | Values]
               end,

    ErlangArgs = CouchIni ++
        ["-setcookie", atom_to_list(ns_server:get_babysitter_cookie()),
         "-name", atom_to_list(ns_node_disco:couchdb_node()),
         "-smp", "enable",
         "+P", "327680",
         "+K", "true",
         "-kernel", "error_logger", "false",
         "-sasl", "sasl_error_logger", "false",
         "-nouser",
         "-hidden",
         "-run", "child_erlang", "child_start", "ns_couchdb"],

    ns_ports_setup:create_erl_node_spec(
      ns_couchdb, [{ns_server_node, node()}], "NS_COUCHDB_ENV_ARGS", ErlangArgs).

start_couchdb_node() ->
    proc_lib:start_link(
      erlang, apply,
      [fun () ->
               ok = net_kernel:monitor_nodes(true, [nodedown_reason]),
               ns_port_server:start_link(fun () -> create_ns_couchdb_spec() end),
               ns_couchdb_api:wait_for_name(last_process),

               proc_lib:init_ack({ok, self()}),
               monitor_couchdb_node_loop(ns_node_disco:couchdb_node())
       end, []]).

monitor_couchdb_node_loop(CouchdbNode) ->
    receive
        {nodeup, CouchdbNode} ->
            ?log_debug("Node ~p started.", [CouchdbNode]),
            monitor_couchdb_node_loop(CouchdbNode);
        {nodedown, CouchdbNode} ->
            ?log_debug("Node ~p went down. Restart port and ns_server_sup.", [CouchdbNode]),
            exit({shutdown, {nodedown, CouchdbNode}});
        _ ->
            monitor_couchdb_node_loop(CouchdbNode)
    end.
