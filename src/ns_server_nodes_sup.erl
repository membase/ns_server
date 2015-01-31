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
-export([start_link/0, start_couchdb_node/0]).

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

child_specs() ->
    [
     {setup_node_names,
      {ns_server, setup_node_names, []},
      transient, brutal_kill, worker, []},

     {remote_monitors, {remote_monitors, start_link, []},
      permanent, 1000, worker, []},

     %% we cannot "kill" this guy anyways. Thus hefty shutdown timeout.
     {start_couchdb_node, {?MODULE, start_couchdb_node, []},
      {permanent, 5}, 86400000, worker, []},

     {wait_for_couchdb_node, {erlang, apply, [fun wait_link_to_couchdb_node/0, []]},
      permanent, 1000, worker, []},

     {setup_dirs,
      {ns_storage_conf, setup_db_and_ix_paths, []},
      transient, brutal_kill, worker, []},

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
    ns_port_server:start_link_named(ns_couchdb_port, fun () -> create_ns_couchdb_spec() end).

wait_link_to_couchdb_node() ->
    proc_lib:start_link(erlang, apply, [fun start_wait_link_to_couchdb_node/0, []]).

start_wait_link_to_couchdb_node() ->
    erlang:register(wait_link_to_couchdb_node, self()),
    do_wait_link_to_couchdb_node(true).

do_wait_link_to_couchdb_node(Initial) ->
    ?log_debug("Waiting for ns_couchdb node to start"),
    erlang:link(erlang:whereis(ns_couchdb_port)),
    RV = misc:poll_for_condition(
           fun () ->
                   case rpc:call(ns_node_disco:couchdb_node(), erlang, apply, [fun is_couchdb_node_ready/0, []], 5000) of
                       {ok, _} = OK -> OK;
                       Other ->
                           ?log_debug("ns_couchdb is not ready: ~p", [Other]),
                           false
                   end
           end,
           60000, 200),
    case RV of
        {ok, Pid} ->
            case Initial of
                true ->
                    proc_lib:init_ack({ok, self()});
                _ -> ok
            end,
            remote_monitors:monitor(Pid),
            wait_link_to_couchdb_node_loop(Pid);
        timeout ->
            exit(timeout)
    end.

wait_link_to_couchdb_node_loop(Pid) ->
    receive
        {remote_monitor_down, Pid, unpaused} ->
            ?log_debug("Link to couchdb node was unpaused."),
            do_wait_link_to_couchdb_node(false);
        {remote_monitor_down, Pid, Reason} ->
            ?log_debug("Link to couchdb node was lost. Reason: ~p", [Reason]),
            exit(normal);
        Msg ->
            ?log_debug("Exiting due to message: ~p", [Msg]),
            exit(normal)
    end.

%% NOTE: rpc-ed between ns_server and ns_couchdb nodes.
is_couchdb_node_ready() ->
    case erlang:whereis(ns_couchdb_sup) of
        P when is_pid(P) ->
            try supervisor:which_children(P) of
                _ ->
                    {ok, P}
            catch _:_ ->
                    false
            end;
        _ ->
            false
    end.
