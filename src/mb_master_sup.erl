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
-module(mb_master_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-export([start_link/0]).

-export([init/1]).


start_link() ->
    master_activity_events:note_became_master(),
    supervisor:start_link({local, mb_master_sup}, ?MODULE, []).


init([]) ->
    {ok, {{one_for_one, 3, 10}, child_specs()}}.


%%
%% Internal functions
%%

%% @private
%% @doc The list of child specs.
child_specs() ->
    [{ns_orchestrator, {ns_orchestrator, start_link, []},
      permanent, 20, worker, [ns_orchestrator]},
     {ns_tick, {ns_tick, start_link, []},
      permanent, 10, worker, [ns_tick]},
     {auto_failover, {auto_failover, start_link, []},
      permanent, 10, worker, [auto_failover]}].
