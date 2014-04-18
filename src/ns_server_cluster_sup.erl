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

-include("ns_common.hrl").

%% API
-export ([start_cluster/0, start_link/0, stop_cluster/0]).
-export ([start_via_wrapper_process/2, wrapper_process_body/3]).

%% Supervisor callbacks
-export([init/1]).

%%
%% API
%%

%% @doc Start child after its been stopped
start_cluster() ->
    supervisor:restart_child(?MODULE, ns_server_sup),
    ok = gen_server:call('ns_server_sup-wrapper', sync, infinity).


%% @doc Start the supervisor
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


%% @doc Stop ns_server_sup
stop_cluster() ->
    supervisor:terminate_child(?MODULE, ns_server_sup).


%%
%% Supervisor callbacks
%%

init([]) ->
    {ok, {{one_for_one, 10, 1},
          [{cb_couch_sup, {cb_couch_sup, start_link, []},
            permanent, 5000, supervisor, [cb_couch_sup]},
           %% this must be placed after cb_couch_sup since couchdb starts
           %% sasl application
           {cb_init_loggers, {cb_init_loggers, start_link, []},
            transient, 1000, worker, [cb_init_loggers]},
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
            {ns_process_registry, start_link, [vbucket_filter_changes_registry]},
            permanent, 100, worker, [ns_process_registry]},
           {ns_server_sup, {?MODULE, start_via_wrapper_process,
                            [ns_server_sup, {ns_server_sup, start_link, []}]},
            permanent, infinity, supervisor, [ns_server_sup]}
          ]}}.

start_via_wrapper_process(ChildName, MFA) ->
    Parent = self(),
    proc_lib:start_link(?MODULE, wrapper_process_body, [Parent, ChildName, MFA]).

wrapper_process_body(Parent, ChildName, {M, F, A}) ->
    Name = list_to_atom(atom_to_list(ChildName) ++ "-wrapper"),
    erlang:register(Name, self()),
    proc_lib:init_ack(Parent, {ok, self()}),

    process_flag(trap_exit, true),

    {ok, Child} = erlang:apply(M, F, A),

    wrapper_process_loop(Parent, Child).

wrapper_process_loop(Parent, Child) ->
    KillChildAndDie =
        fun (Reason) ->
                exit(Child, Reason),
                misc:wait_for_process(Child, infinity),
                exit(Reason)
        end,

    receive
        {'EXIT', Parent, Reason} = Exit ->
            ?log_debug("Got exit from parent: ~p", [Exit]),
            KillChildAndDie(Reason);
        {'EXIT', Child, Reason} = Exit ->
            ?log_debug("Got exit from child: ~p", [Exit]),
            exit(Reason);
        {'$gen_call', From, sync} ->
            gen_server:reply(From, ok),
            wrapper_process_loop(Parent, Child);
        Other ->
            ?log_debug("Got unexpected message: ~p", [Other]),
            KillChildAndDie({unexpected_message, Other})
    end.
