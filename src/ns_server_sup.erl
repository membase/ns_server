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

-export([start_link/0]).

-export([init/1, pull_plug/1]).

start_link() ->
    application:start(os_mon),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    pre_start(),
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          get_child_specs()}}.

pre_start() ->
    misc:make_pidfile(),
    misc:ping_jointo().

get_child_specs() ->
    [{ns_config_sup, {ns_config_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_config_sup]},

     %% ns_log starts after ns_config because it needs the config to
     %% find where to persist the logs
     {ns_log, {ns_log, start_link, []},
      permanent, 10, worker, [ns_log]},

     {ns_log_events, {gen_event, start_link, [{local, ns_log_events}]},
      permanent, 10, worker, [ns_log_events]},

     {ns_mail_sup, {ns_mail_sup, start_link, []},
      permanent, infinity, supervisor, [ns_mail_sup]},

     {ns_node_disco_sup, {ns_node_disco_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_node_disco_sup]},

     {ns_port_sup, {ns_port_sup, start_link, []},
      permanent, 10, worker,
      [supervisor_cushion]},

     {menelaus, {menelaus_app, start_subapp, []},
      permanent, infinity, supervisor,
      []},

     {ns_memcached,
      {ns_memcached, start_link, []},
      permanent, 10, worker, [ns_memcached]},

     {ns_vbm_sup, {ns_vbm_sup, start_link, []},
      permanent, infinity, supervisor, [ns_vbm_sup]},

     {ns_tick_event, {gen_event, start_link, [{local, ns_tick_event}]},
      permanent, 10, worker, [gen_event]},

     {ns_tick, {ns_tick, start_link, []},
      permanent, 10, worker, [ns_tick]},

     {ns_stats_event, {gen_event, start_link, [{local, ns_stats_event}]},
      permanent, 10, worker, [gen_event]},

     {ns_bucket_sup, {ns_bucket_sup, start_link, []},
      permanent, infinity, supervisor, [ns_bucket_sup]},

     {ns_heart, {ns_heart, start_link, []},
      permanent, 10, worker,
      [ns_heart]},

     {ns_doctor, {ns_doctor, start_link, []},
      permanent, 10, worker, [ns_doctor]}
    ].

%% beware that if it's called from one of restarted childs it won't
%% work. This can be allowed with further work here. As of now it's not needed
pull_plug(Fun) ->
    GoodChildren = [ns_config_sup, ns_port_sup, menelaus, ns_node_disco_sup,
                    ns_tick, ns_tick_event, ns_stats_event, ns_log_events],
    BadChildren = [Id || {Id,_,_,_,_,_} <- get_child_specs(),
                         not lists:member(Id, GoodChildren)],
    error_logger:info_msg("~p plug pulled.  Killing ~p, keeping ~p~n",
                          [?MODULE, BadChildren, GoodChildren]),
    lists:foreach(fun(C) -> ok = supervisor:terminate_child(?MODULE, C) end,
                  BadChildren),
    Fun(),
    lists:foreach(fun(C) ->
                          R = supervisor:restart_child(?MODULE, C),
                          error_logger:info_msg("Restarting ~p: ~p~n", [C, R])
                  end,
                  BadChildren).
