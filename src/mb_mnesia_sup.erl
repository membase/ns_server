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
-module(mb_mnesia_sup).

-behavior(supervisor).

%% API
-export ([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%
%% API
%%

%% @doc Start the supervisor.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


%%
%% Supervisor callbacks
%%

init([]) ->
    {ok, {{one_for_one, 10, 1},
          [{mb_mnesia_events, {gen_event, start_link, [{local, mb_mnesia_events}]},
            permanent, 10, worker, dynamic},
           {mb_mnesia, {mb_mnesia, start_link, []},
            permanent, 5000, worker, [mb_mnesia]}]}}.
