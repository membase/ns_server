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

-export([init/1]).


%% API

start_link(Name, ChildFun) ->
    supervisor:start_link({local, Name}, ?MODULE, {Name, ChildFun}).


%% supervisor callbacks

init({Name, ChildFun}) ->
    ns_pubsub:subscribe(
      ns_config_events,
      fun (Event, State) ->
              case Event of
                  {buckets, L} ->
                      Buckets = [B || {B, _} <-
                                          proplists:get_value(configs, L)],
                      update_childs(Name, ChildFun, Buckets);
                  _ -> ok
              end,
              State
      end, undefined),
    {ok, {{one_for_one, 3, 10},
          lists:flatmap(ChildFun, ns_bucket:get_bucket_names())}}.

%% Internal functions

update_childs(Name, ChildFun, Buckets) ->
    NewSpecs = lists:flatmap(ChildFun, Buckets),
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
