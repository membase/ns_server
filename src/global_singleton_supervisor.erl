%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% Processes supervised by this supervisor will only exist in one
%% place in a cluster.
%%
-module(global_singleton_supervisor).

-behaviour(supervisor).

-include_lib("eunit/include/eunit.hrl").

-define(CHECK_DELAY, 1000).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

start_link() ->
    case supervisor:start_link({global, ?MODULE}, ?MODULE, []) of
    {ok, Pid} -> {ok, Pid};
    {error, {already_started, Pid}} ->
        {ok, spawn_link(fun () -> watch(Pid) end)}
    end.

watch(Pid) ->
    process_flag(trap_exit, true),
    erlang:monitor(process, Pid),
    error_logger:info_msg("Monitoring global singleton at ~p (at node: ~p) from node ~p~n",
                          [Pid, node(Pid), node()]),
    receive
    LikelyExit ->
        error_logger:info_msg("Global singleton supervisor at ~p (at node: ~p) exited for reason ~p, seen from node ~p. Restarting.~n",
                              [Pid, node(Pid), LikelyExit, node()])
    end.

%% Check to make sure the name is still registered. For some reason we
%% don't always receive the exit signal.
check(Pid) ->
    case global:whereis_name(?MODULE) =:= Pid of
        true -> ok;
        false -> exit(Pid, kill)
    end,
    timer:sleep(?CHECK_DELAY),
    check(Pid).

init([]) ->
    Pid = self(),
    spawn_link(fun () -> check(Pid) end),
    {ok,{{one_for_one, 5, 5},
         [
          %% Everything in here is run once per entire cluster.  Be careful.
          {ns_log, {ns_log, start_link, []},
           permanent, 10, worker, [ns_log]},
          {ns_log_events, {gen_event, start_link, [{local, ns_log_events}]},
           permanent, 10, worker, [ns_log_events]},
          {ns_mail_sup, {ns_mail_sup, start_link, []},
           permanent, infinity, supervisor, [ns_mail_sup]},
          {ns_bucket_sup_sup, {ns_bucket_sup_sup, start_link, []},
           permanent, infinity, supervisor, [ns_bucket_sup_sup]},
          {ns_doctor, {ns_doctor, start_link, []},
           permanent, 10, worker, [ns_doctor]}
         ]}}.


%% Tests
global_singleton_watchdog_test() ->
    process_flag(trap_exit, true),
    Pid = spawn_link(fun () ->
                             global:register_name(?MODULE, self()),
                             check(self()),
                             global:unregister_name(?MODULE),
                             timer:sleep(5000)
                     end),
    receive
        {'EXIT', Pid, killed} ->
            ok;
        E -> {error, E}
    after 2000 ->
            {error, timeout}
    end.
