%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
-module(index_stats_sup).

-include("ns_common.hrl").

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children =
        [{index_stats_children_sup,
          {supervisor, start_link, [{local, index_stats_children_sup}, ?MODULE, child]},
          permanent, infinity, supervisor, []},
         {index_status_keeper_sup, {index_status_keeper_sup, start_link, []},
          permanent, infinity, supervisor, []},
         {index_stats_worker, {erlang, apply, [fun start_link_worker/0, []]},
          permanent, 1000, worker, []}],
    {ok, {{one_for_all,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          Children}};
init(child) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.

is_notable_event({buckets, _}) ->
    true;
is_notable_event({{node, Node, membership}, _}) when Node =:= node() ->
    true;
is_notable_event({rest_creds, _}) ->
    true;
is_notable_event(_) ->
    false.

handle_cfg_event(Event) ->
    case is_notable_event(Event) of
        false ->
            ok;
        true ->
            work_queue:submit_work(index_stats_worker, fun refresh_children/0)
    end.

compute_wanted_children(Indexer, Config) ->
    case ns_cluster_membership:should_run_service(Config, Indexer:get_type(), node()) of
        false ->
            [];
        true ->
            StaticChildren = [{Indexer, index_stats_collector}],

            %% Stats archiver and reader for Service specific stats
            ServiceChildren = [{Indexer, Mod, Indexer:service_event_name()}
                               || Mod <- [stats_archiver, stats_reader]],

            BucketCfgs = ns_bucket:get_buckets(Config),
            BucketNames = [Name || {Name, BConfig} <- BucketCfgs,
                                   lists:keyfind(type, 1, BConfig) =:= {type, membase}],
            PerBucketChildren =
                [{Indexer, Mod, Name}
                 || Name <- BucketNames,
                    Mod <- [stats_archiver, stats_reader]],

            lists:sort(StaticChildren ++ PerBucketChildren ++ ServiceChildren)
    end.

refresh_children() ->
    RunningChildren0 = [Id || {Id, _, _, _} <- supervisor:which_children(index_stats_children_sup)],
    RunningChildren = lists:sort(RunningChildren0),
    Config = ns_config:get(),
    WantedChildren0 = compute_wanted_children(indexer_fts, Config) ++
        compute_wanted_children(indexer_gsi, Config) ++
        compute_wanted_children(indexer_cbas, Config),
    WantedChildren = lists:sort(WantedChildren0),
    ToStart = ordsets:subtract(WantedChildren, RunningChildren),
    ToStop = ordsets:subtract(RunningChildren, WantedChildren),
    lists:foreach(fun stop_child/1, ToStop),
    lists:foreach(fun start_child/1, ToStart),
    ok.

child_spec({Indexer, Mod, Name}) when Name =:= "@index" orelse Name =:= "@fts" orelse Name =:= "@cbas" ->
    {{Indexer, Mod, Name}, {Mod, start_link, [Name]},
     permanent, 1000, worker, []};
child_spec({Indexer, Mod, Name}) when Mod =:= stats_archiver; Mod =:= stats_reader ->
    {{Indexer, Mod, Name}, {Mod, start_link, [Indexer:prefix() ++ Name]},
     permanent, 1000, worker, []};
child_spec({Indexer, Mod}) ->
    {{Indexer, Mod}, {Mod, start_link, [Indexer]}, permanent, 1000, worker, []}.

start_child(Id) ->
    {ok, _Pid} = supervisor:start_child(index_stats_children_sup, child_spec(Id)).

stop_child(Id) ->
    ok = supervisor:terminate_child(index_stats_children_sup, Id),
    ok = supervisor:delete_child(index_stats_children_sup, Id).

start_link_worker() ->
    RV = {ok, _} = work_queue:start_link(
                     index_stats_worker,
                     fun () ->
                             ns_pubsub:subscribe_link(ns_config_events, fun handle_cfg_event/1)
                     end),
    work_queue:submit_work(index_stats_worker, fun refresh_children/0),
    RV.
