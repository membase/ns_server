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
%% Run a set of processes per bucket

-module(ns_bucket_sup).

-behaviour(supervisor).

-export([start_link/0, notify/1]).

-export([init/1]).


%% API

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% buckets key got updated
notify(Config) ->
    ChildSpecs = child_specs(Config),
    CurrentChildren = [Id || {Id, Pid, _, _} <-
                                 supervisor:which_children(?MODULE),
                             Pid /= undefined],
    ZombieChildren = [Child || Child <- CurrentChildren,
                               not lists:keymember(Child, 1, ChildSpecs)],
    lists:foreach(fun (Id) -> supervisor:terminate_child(?MODULE, Id) end,
                  ZombieChildren),
    NewChildSpecs = [ChildSpec || ChildSpec = {Id, _} <- ChildSpecs,
                                  not lists:member(Id, CurrentChildren)],
    lists:foreach(fun (ChildSpec) ->
                          supervisor:start_child(?MODULE, ChildSpec) end,
                  NewChildSpecs),
    lists:foreach(fun ({Bucket, BucketConfig}) ->
                          ns_bucket_sup:notify(Bucket, BucketConfig) end,
                  proplists:get_value(configs, Config)).


%% supervisor callbacks

init([]) ->
    {ok, {{one_for_one, 3, 10},
          child_specs()}}.


%% Internal functions
child_specs() ->
    Configs = ns_bucket:get_buckets(),
    ChildSpecs = child_specs(Configs),
    error_logger:info_msg("~p:child_specs(): ChildSpecs = ~p~n",
                          [?MODULE, ChildSpecs]),
    ChildSpecs.

child_specs(Configs) ->
    lists:append([child_spec(B) || {B, _} <- Configs]).

child_spec(Bucket) ->
    [{{ns_orchestrator, Bucket}, {ns_orchestrator, start_link, [Bucket]},
      permanent, 10, worker, [ns_orchestrator]},
     {{stats_collector, Bucket}, {stats_collector, start_link, [Bucket]},
      permanent, 10, worker, [stats_collector]},
     {{stats_archiver, Bucket}, {stats_archiver, start_link, [Bucket]},
      permanent, 10, worker, [stats_archiver]}].
