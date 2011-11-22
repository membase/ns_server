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
%% @doc Supervisor for the menelaus application.

-module(menelaus_sup).
-author('Northscale <info@northscale.com>').

-behaviour(supervisor).

-define(START_OK, 1).
-define(START_FAIL, 2).

%% External exports
-export([start_link/0, upgrade/0]).

%% supervisor callbacks
-export([init/1]).

-export([ns_log_cat/1, ns_log_code_string/1]).

%% @spec start_link() -> ServerRet
%% @doc API for starting the supervisor.
start_link() ->
    Result = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    WConfig = menelaus_web:webconfig(),
    Port = proplists:get_value(port, WConfig),
    case Result of
        {ok, _Pid} ->
            ns_log:log(?MODULE, ?START_OK,
                       "Couchbase Server has started on web port ~p on node ~p.",
                       [Port, node()]);
        _Err ->
            %% The exact error message is not logged here since this
            %% is a supervisor start, but a more helpful message
            %% should've been logged before.
            ns_log:log(?MODULE, ?START_FAIL,
                       "Couchbase Server has failed to start on web port ~p on node ~p. " ++
                       "Perhaps another process has taken port ~p already? " ++
                       "If so, please stop that process first before trying again.",
                       [Port, node(), Port])
    end,
    Result.

%% @spec upgrade() -> ok
%% @doc Add processes if necessary.
upgrade() ->
    {ok, {_, Specs}} = init([]),

    Old = sets:from_list(
            [Name || {Name, _, _, _} <- supervisor:which_children(?MODULE)]),
    New = sets:from_list([Name || {Name, _, _, _, _, _} <- Specs]),
    Kill = sets:subtract(Old, New),

    sets:fold(fun (Id, ok) ->
                      supervisor:terminate_child(?MODULE, Id),
                      supervisor:delete_child(?MODULE, Id),
                      ok
              end, ok, Kill),

    [supervisor:start_child(?MODULE, Spec) || Spec <- Specs],
    ok.

%% @spec init([]) -> SupervisorTree
%% @doc supervisor callback.
init([]) ->
    Web = {menelaus_web,
           {menelaus_web, start_link, []},
           permanent, 5000, worker, dynamic},

    Alerts = {menelaus_web_alerts_srv,
              {menelaus_web_alerts_srv, start_link, []},
              permanent, 5000, worker, dynamic},

    WebEvent = {menelaus_event,
                {menelaus_event, start_link, []},
                permanent, 5000, worker, dynamic},

    HotKeysKeeper = {hot_keys_keeper,
                     {hot_keys_keeper, start_link, []},
                     permanent, 5000, worker, dynamic},

    Processes = [Web, WebEvent, HotKeysKeeper, Alerts],
    {ok, {{one_for_one, 10, 10}, Processes}}.

ns_log_cat(?START_OK) ->
    info;
ns_log_cat(?START_FAIL) ->
    crit.

ns_log_code_string(?START_OK) ->
    "web start ok";
ns_log_code_string(?START_FAIL) ->
    "web start fail".
