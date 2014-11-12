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

-export([pause_ns_couchdb_link/0, unpause_ns_couchdb_link/0]).

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

     %% we cannot "kill" this guy anyways. Thus hefty shutdown timeout.
     {start_couchdb_node, {?MODULE, start_couchdb_node, []},
      {permanent, 5}, 86400000, worker, []},

     {wait_for_couchdb_node, {erlang, apply, [fun wait_link_to_couchdb_node/0, []]},
      permanent, 1000, worker, []},

     {ns_server_sup, {ns_server_sup, start_link, []},
      permanent, infinity, supervisor, [ns_server_sup]}].

pause_ns_couchdb_link() ->
    ok = gen_server:call(wait_link_to_couchdb_node, pause, infinity).

unpause_ns_couchdb_link() ->
    ok = gen_server:call(wait_link_to_couchdb_node, unpause, infinity).

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
    ns_port_server:start_link(fun () -> create_ns_couchdb_spec() end).

wait_link_to_couchdb_node() ->
    proc_lib:start_link(erlang, apply, [fun start_wait_link_to_couchdb_node/0, []]).

start_wait_link_to_couchdb_node() ->
    erlang:register(wait_link_to_couchdb_node, self()),
    do_wait_link_to_couchdb_node(true).

do_wait_link_to_couchdb_node(Initial) ->
    ?log_debug("Waiting for ns_couchdb node to start"),
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
            MRef = erlang:monitor(process, Pid),
            wait_link_to_couchdb_node_loop(MRef);
        timeout ->
            exit(timeout)
    end.

wait_link_to_couchdb_node_loop(MRef) ->
    receive
        {'$gen_call', {FromPid, _} = From, pause} ->
            erlang:demonitor(MRef, [flush]),
            MRef2 = erlang:monitor(process, FromPid),
            gen_server:reply(From, ok),
            wait_link_to_couchdb_node_paused_loop(FromPid, MRef2);
        Msg ->
            ?log_debug("Exiting due to message: ~p", [Msg]),
            exit(normal)
    end.

wait_link_to_couchdb_node_paused_loop(PauserPid, PauserMRef) ->
    receive
        {'$gen_call', {FromPid, _} = From, Msg} ->
            case Msg of
                pause ->
                    gen_server:reply(From, already_paused);
                unpause when FromPid =:= PauserPid ->
                    erlang:demonitor(PauserMRef),
                    gen_server:reply(From, ok),
                    do_wait_link_to_couchdb_node(false)
            end;
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
