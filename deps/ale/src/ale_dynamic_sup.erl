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

-module(ale_dynamic_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_child/3, restart_child/1, stop_child/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(Id, M, Args),
        {Id, {M, start_link, Args}, permanent, 5000, worker, [M]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child(Id, Module, Args) ->
    supervisor:start_child(?MODULE,
                           ?CHILD(Id, Module, Args)).

restart_child(Id) ->
    case supervisor:terminate_child(?MODULE, Id) of
        ok ->
            supervisor:restart_child(?MODULE, Id);
        Other ->
            Other
    end.

stop_child(Id) ->
    case supervisor:terminate_child(?MODULE, Id) of
        ok ->
            supervisor:delete_child(?MODULE, Id);
        Other ->
            Other
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10},
           []} }.
