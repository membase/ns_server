%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-2018 Couchbase, Inc.
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
-module(leader_services_sup).

-behaviour(supervisor).

-export([start_link/0, start_link/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, main).

start_link(Name) ->
    supervisor:start_link({local, Name}, ?MODULE, Name).

init(Name) ->
    {ok, {{restart_type(Name),
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          child_specs(Name)}}.

restart_type(main) ->
    one_for_one;
restart_type(_) ->
    rest_for_one.

child_specs(main) ->
    [{Name, {?MODULE, start_link, [Name]},
      permanent, infinity, supervisor, []} ||
        Name <- [leader_leases_sup, leader_registry_sup]];
child_specs(leader_leases_sup) ->
    [{leader_activities, {leader_activities, start_link, []},
      permanent, 10000, worker, []},
     {leader_lease_agent, {leader_lease_agent, start_link, []},
      permanent, 1000, worker, []}];
child_specs(leader_registry_sup) ->
    %% Note to the users of leader_events. The events are announced
    %% synchronously, make sure not to block mb_master for too long.
    [{leader_events, {gen_event, start_link, [{local, leader_events}]},
      permanent, 1000, worker, dynamic},
     {leader_registry_server, {leader_registry_server, start_link, []},
      permanent, 1000, worker, [leader_registry_server]},
     {mb_master, {mb_master, start_link, []},
      permanent, infinity, supervisor, [mb_master]}].
