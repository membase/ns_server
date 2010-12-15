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
-module(ns_heart).

-behaviour(gen_server).

-define(EXPENSIVE_CHECK_INTERVAL, 10000). % In ms

-export([start_link/0, status_all/0, expensive_checks/0,
         buckets_replication_statuses/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% gen_server handlers

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    timer:send_interval(1000, beat),
    timer:send_interval(?EXPENSIVE_CHECK_INTERVAL, do_expensive_checks),
    self() ! do_expensive_checks,
    {ok, undefined}.

handle_call(status, _From, State) ->
    {reply, current_status(State), State};
handle_call(Request, _From, State) ->
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(beat, State) ->
    misc:flush(beat),
    ns_doctor:heartbeat(current_status(State)),
    {noreply, State};
handle_info(do_expensive_checks, _State) ->
    {noreply, expensive_checks()}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API
status_all() ->
    {Replies, _} = gen_server:multi_call([node() | nodes()], ?MODULE, status, 5000),
    Replies.

stats() ->
    Stats = [wall_clock, context_switches, garbage_collection, io, reductions,
             run_queue, runtime],
    [{Stat, statistics(Stat)} || Stat <- Stats].

%% Internal fuctions
buckets_replication_statuses() ->
    BucketConfigs = ns_bucket:get_buckets(),
    [{Bucket, replication_status(Bucket, BucketConfig)} ||
        {Bucket, BucketConfig} <- BucketConfigs].

current_status(Expensive) ->
    ClusterCompatVersion = case (catch list_to_integer(os:getenv("MEMBASE_CLUSTER_COMPAT_VERSION"))) of
                               X when is_integer(X) -> X;
                               _ -> 1
                           end,
    [{active_buckets, ns_memcached:active_buckets()},
     {memory, erlang:memory()},
     {cluster_compatibility_version, ClusterCompatVersion}
     | element(2, ns_info:basic_info())] ++ Expensive.

expensive_checks() ->
    ReplicationStatus = buckets_replication_statuses(),
    BasicData = [{replication, ReplicationStatus},
                 {system_memory_data, memsup:get_system_memory_data()},
                 {statistics, stats()}],
    case misc:raw_read_file("/proc/meminfo") of
        {ok, Contents} ->
            [{meminfo, Contents} | BasicData];
        _ -> BasicData
    end.

replication_status(Bucket, BucketConfig) ->
    %% First, check that replication is running
    case proplists:get_value(map, BucketConfig) of
        undefined ->
            1.0;
        Map ->
            case [R || {N, _, _} = R <- ns_bucket:map_to_replicas(Map),
                            N == node()] of
                [] ->
                    %% No replicas for this node
                    1.0;
                Replicas ->
                    try
                        Replicators = ns_vbm_sup:replicators([node()],
                                                             Bucket),
                        case Replicas -- Replicators of
                            [] ->
                                %% Ok, running
                                case ns_memcached:backfilling(Bucket) of
                                    true ->
                                        0.5;
                                    false ->
                                        1.0
                                end;
                            _ ->
                                %% Replication isn't even running
                                0.0
                        end
                    catch
                        _:_ ->
                            0.0
                    end
            end
    end.
