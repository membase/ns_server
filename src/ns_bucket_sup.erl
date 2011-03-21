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

-export([start_link/3]).

-export([init/1]).


%% API
start_link(Name, ChildFun, WorkQueue) ->
    supervisor:start_link({local, Name}, ?MODULE, {Name, ChildFun, WorkQueue}).


%% supervisor callbacks

init({Name, ChildFun, WorkQueue}) ->
    ns_pubsub:subscribe(
      ns_config_events,
      fun (Event, State) ->
              case Event of
                  {buckets, L} ->
                      Buckets = get_this_node_bucket_names(proplists:get_value(configs, L, [])),
                      work_queue:submit_work(WorkQueue,
                                             fun () ->
                                                     update_childs(Name, ChildFun, Buckets)
                                             end);
                  _ -> ok
              end,
              State
      end, undefined),
    {ok, {{one_for_one, 3, 10},
          lists:flatmap(ChildFun,
                        get_this_node_bucket_names(ns_bucket:get_buckets()))}}.

get_this_node_bucket_names(BucketsConfigs) ->
    Node = node(),
    [B || {B, C} <- BucketsConfigs,
          lists:member(Node, proplists:get_value(servers, C, []))].

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
