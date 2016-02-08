%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
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
-module(rebalance_progress).

-export([init/1, init/2, get_progress/1, update/3]).

-record(progress, {
          per_service :: dict(),
          aggregated  :: dict()
         }).

init(LiveNodes) ->
    init(LiveNodes, [kv]).

init(LiveNodes, Services) ->
    do_init([{S, ns_cluster_membership:service_nodes(LiveNodes, S)} ||
                S <- Services]).

do_init(Services) ->
    aggregate(init_per_service(Services)).

init_per_service(Services) ->
    dict:from_list([{Service, init_service(Nodes)} ||
                       {Service, Nodes} <- Services]).

init_service(Nodes) ->
    dict:from_list([{N, 0} || N <- Nodes]).

get_progress(#progress{aggregated = Aggregated}) ->
    Aggregated.

update(Service, ServiceProgress, #progress{per_service = PerService}) ->
    aggregate(do_update(Service, ServiceProgress, PerService)).

do_update(Service, ServiceProgress, PerService) ->
    dict:update(Service,
                fun (OldServiceProgress) ->
                        dict:merge(fun (_, _, New) ->
                                           New
                                   end, OldServiceProgress, ServiceProgress)
                end, PerService).

aggregate(PerService) ->
    Aggregated0 =
        dict:fold(
          fun (_, ServiceProgress, AggAcc) ->
                  dict:fold(
                    fun (Node, NodeProgress, Acc) ->
                            misc:dict_update(
                              Node,
                              fun ({Count, Sum}) ->
                                      {Count + 1, Sum + NodeProgress}
                              end, {0, 0}, Acc)
                    end, AggAcc, ServiceProgress)
          end, dict:new(), PerService),

    Aggregated =
        dict:map(fun (_, {Count, Sum}) ->
                         Sum / Count
                 end, Aggregated0),

    #progress{per_service = PerService,
              aggregated = Aggregated}.
