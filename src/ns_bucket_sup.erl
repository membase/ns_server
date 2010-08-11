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

-include("ns_common.hrl").

-export([start_link/0]).

-export([init/1, update_childs/0]).


%% API

start_link() ->
    RV = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    ns_pubsub:subscribe(ns_config_events,
                        fun (Event, State) ->
                                case Event of
                                    {buckets, _} ->
                                        update_childs();
                                    _ -> ok
                                end,
                                State
                        end, undefined),
    RV.

%% supervisor callbacks

init([]) ->
    {ok, {{one_for_one, 3, 10},
          child_specs()}}.

%% Internal functions
child_specs() ->
    Configs = ns_bucket:get_buckets(),
    ChildSpecs = child_specs(Configs),
    ?log_info("~p:child_specs(): ChildSpecs = ~p~n",
              [?MODULE, ChildSpecs]),
    ChildSpecs.

child_specs(Configs) ->
    lists:append([child_spec(B) || {B, _} <- Configs]).

update_childs() ->
    NewSpecs = child_specs(),
    NewIds = [element(1, X) || X <- NewSpecs],
    OldSpecs = supervisor:which_children(?MODULE),
    RunningIds = [element(1, X) || X <- OldSpecs],
    ToStart = NewIds -- RunningIds,
    ToStop = RunningIds -- NewIds,
    lists:foreach(fun (StartId) ->
                          Tuple = lists:keyfind(StartId, 1, NewSpecs),
                          true = is_tuple(Tuple),
                          ?log_info("Starting new ns_bucket_sup child: ~p~n", [Tuple]),
                          supervisor:start_child(?MODULE, Tuple)
                  end, ToStart),
    lists:foreach(fun (StopId) ->
                          Tuple = lists:keyfind(StopId, 1, OldSpecs),
                          true = is_tuple(Tuple),
                          ?log_info("Stopping ns_bucket_sup child for dead bucket: ~p~n", [Tuple]),
                          supervisor:terminate_child(?MODULE, StopId),
                          supervisor:delete_child(?MODULE, StopId)
                  end, ToStop).

child_spec(Bucket) ->
    [{{stats_collector, Bucket}, {stats_collector, start_link, [Bucket]},
      permanent, 10, worker, [stats_collector]},
     {{stats_archiver, Bucket}, {stats_archiver, start_link, [Bucket]},
      permanent, 10, worker, [stats_archiver]}].
