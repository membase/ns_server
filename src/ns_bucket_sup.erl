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

-export([start_link/2]).

-export([init/1, update_childs/2]).


%% API

start_link(Name, ChildFun) ->
    RV = supervisor:start_link({local, Name}, ?MODULE, ChildFun),
    ns_pubsub:subscribe(ns_config_events,
                        fun (Event, State) ->
                                case Event of
                                    {buckets, _} ->
                                        update_childs(Name, ChildFun);
                                    _ -> ok
                                end,
                                State
                        end, undefined),
    RV.

%% supervisor callbacks

init(ChildFun) ->
    {ok, {{one_for_one, 3, 10},
          child_specs(ChildFun)}}.

%% Internal functions
child_specs(ChildFun) ->
    Configs = ns_bucket:get_buckets(),
    lists:append([ChildFun(B) || {B, _} <- Configs]).

update_childs(Name, ChildFun) ->
    NewSpecs = child_specs(ChildFun),
    NewIds = [element(1, X) || X <- NewSpecs],
    OldSpecs = supervisor:which_children(Name),
    RunningIds = [element(1, X) || X <- OldSpecs],
    ToStart = NewIds -- RunningIds,
    ToStop = RunningIds -- NewIds,
    lists:foreach(fun (StartId) ->
                          Tuple = lists:keyfind(StartId, 1, NewSpecs),
                          true = is_tuple(Tuple),
                          ?log_info("~s: Starting new child: ~p~n",
                                    [Name, Tuple]),
                          supervisor:start_child(Name, Tuple)
                  end, ToStart),
    lists:foreach(fun (StopId) ->
                          Tuple = lists:keyfind(StopId, 1, OldSpecs),
                          true = is_tuple(Tuple),
                          ?log_info("~s: Stopping child for dead bucket: ~p~n",
                                    [Name, Tuple]),
                          supervisor:terminate_child(Name, StopId),
                          supervisor:delete_child(Name, StopId)
                  end, ToStop).
