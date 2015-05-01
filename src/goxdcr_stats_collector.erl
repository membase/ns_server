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
-module(goxdcr_stats_collector).

-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

-include("ns_common.hrl").

-include("ns_stats.hrl").

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link(Bucket) ->
    gen_server:start_link(?MODULE, Bucket, []).

init(Bucket) ->
    ns_pubsub:subscribe_link(ns_tick_event),
    {ok, Bucket}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

latest_tick(TS, NumDropped) ->
    receive
        {tick, TS1} ->
            latest_tick(TS1, NumDropped + 1)
    after 0 ->
            if NumDropped > 0 ->
                    ?stats_warning("Dropped ~b ticks", [NumDropped]);
               true ->
                    ok
            end,
            TS
    end.

get_stats(Bucket) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        true ->
            goxdcr_rest:stats(Bucket);
        false ->
            []
    end.

handle_info({tick, TS0}, Bucket) ->
    TS = latest_tick(TS0, 0),
    Stats = get_stats(Bucket),

    RepStats = transform_stats(Stats),

    gen_event:notify(ns_stats_event,
                     {stats, "@xdcr-" ++ Bucket,
                      #stat_entry{timestamp = TS,
                                  values = RepStats}}),
    {noreply, Bucket};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

transform_stats_loop([], Acc, TotalChangesLeft, TotalDocsRepQueue) ->
    {Acc, TotalChangesLeft, TotalDocsRepQueue};
transform_stats_loop([In | T], Reps, TotalChangesLeft, TotalDocsRepQueue) ->
    {RepID, RepStats} = In,
    PerRepStats = [{iolist_to_binary([<<"replications/">>, RepID, <<"/">>, StatK]),
                    StatV} || {StatK, StatV} <- RepStats, is_number(StatV)],
    NewTotalChangesLeft = TotalChangesLeft + proplists:get_value(<<"changes_left">>, RepStats, 0),
    NewTotalDocsRepQueue = TotalDocsRepQueue + proplists:get_value(<<"docs_rep_queue">>, RepStats, 0),
    transform_stats_loop(T, [PerRepStats | Reps], NewTotalChangesLeft, NewTotalDocsRepQueue).

transform_stats(Stats) ->
    {RepStats, TotalChangesLeft, TotalDocsRepQueue} = transform_stats_loop(Stats, [], 0, 0),

    GlobalList = [{<<"replication_changes_left">>, TotalChangesLeft},
                  {<<"replication_docs_rep_queue">>, TotalDocsRepQueue}],

    lists:sort(lists:append([GlobalList | RepStats])).
