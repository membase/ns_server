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

-module(stats_collector).

-include_lib("eunit/include/eunit.hrl").

-include("ns_stats.hrl").

-behaviour(gen_server).

-define(STATS_TIMER, 1000).

-define(l2r(KeyName),
        l2r(KeyName, V, Rec) ->
               Rec#stat_entry{KeyName=list_to_integer(V)}).



%% API
-export([start_link/1]).

-record(state, {bucket, counters}).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

start_link(Bucket) ->
    gen_server:start_link(?MODULE, Bucket, []).

init(Bucket) ->
    ns_pubsub:subscribe(ns_tick_event),
    {ok, #state{bucket=Bucket}}.

handle_call(unhandled, unhandled, unhandled) ->
    unhandled.

handle_cast(unhandled, unhandled) ->
    unhandled.

handle_info({tick, TS}, #state{bucket=Bucket, counters=Counters} = State) ->
    case catch ns_memcached:stats(Bucket) of
        {ok, Stats} ->
            TS1 = latest_tick(TS),
            {Entry, NewCounters} = parse_stats(TS1, Stats, Counters),
            case Counters of % Don't send event with undefined values
                undefined ->
                    ok;
                _ ->
                    gen_event:notify(ns_stats_event, {stats, Bucket, Entry})
            end,
            {noreply, State#state{counters=NewCounters}};
        _ ->
            {noreply, State}
    end;
handle_info(_Msg, State) -> % Don't crash on delayed responses to calls
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Internal functions
latest_tick(TS) ->
    receive
        {tick, TS1} ->
            latest_tick(TS1)
    after 0 ->
            TS
    end.

parse_stats(TS, Stats, LastCounters) ->
    Dict = dict:from_list([{binary_to_atom(K, latin1), V} || {K, V} <- Stats]),
    Gauges = [list_to_integer(binary_to_list(dict:fetch(K, Dict)))
              || K <- [?STAT_GAUGES]],
    Counters = [list_to_integer(binary_to_list(dict:fetch(K, Dict)))
                || K <- [?STAT_COUNTERS]],
    Deltas = case LastCounters of
                 undefined ->
                     lists:duplicate(length([?STAT_COUNTERS]), undefined);
                 _ ->
                     lists:zipwith(fun (A, B) ->
                                           Res = A - B,
                                           if Res < 0 -> 0;
                                              true -> Res
                                           end
                                   end, Counters, LastCounters)
             end,
    {list_to_tuple([stat_entry, TS] ++ Gauges ++ Deltas), Counters}.


%% Tests

parse_stats_test() ->
    Now = now(),
    Input =
        [{"conn_yields","0"},
         {"threads","4"},
         {"rejected_conns","0"},
         {"limit_maxbytes","67108864"},
         {"bytes_written","580019"},
         {"bytes_read","10332"},
         {"cas_badval","0"},
         {"cas_hits","0"},
         {"cas_misses","0"},
         {"decr_hits","0"},
         {"decr_misses","0"},
         {"incr_hits","0"},
         {"incr_misses","0"},
         {"delete_hits","0"},
         {"delete_misses","0"},
         {"get_misses","0"},
         {"get_hits","0"},
         {"auth_errors","0"},
         {"auth_cmds","0"},
         {"cmd_flush","0"},
         {"cmd_set","0"},
         {"cmd_get","0"},
         {"connection_structures","11"},
         {"total_connections","11"},
         {"curr_connections","11"},
         {"daemon_connections","10"},
         {"rusage_system","0.074827"},
         {"rusage_user","0.124334"},
         {"pointer_size","64"},
         {"libevent","1.4.13-stable"},
         {"version","1.4.4_209_g7b9e75f"},
         {"time","1277842911"},
         {"uptime","632"},
         {"pid","19742"},
         {"ep_warmup","true"},
         {"ep_dbinit","0"},
         {"ep_dbname","/Users/sean/northscale/ns_server/data/ns_1/default"},
         {"ep_tap_keepalive","0"},
         {"ep_tap_total_fetched","0"},
         {"ep_tap_total_queue","0"},
         {"ep_warmup_time","0"},
         {"ep_warmed_up","0"},
         {"ep_warmup_thread","complete"},
         {"mem_used","0"},
         {"curr_items","0"},
         {"ep_flush_duration_highwat","1"},
         {"ep_flush_duration","1"},
         {"ep_commit_time","1"},
         {"ep_flusher_state","running"},
         {"ep_flusher_todo","0"},
         {"ep_queue_size","0"},
         {"ep_item_commit_failed","0"},
         {"ep_item_flush_failed","0"},
         {"ep_total_persisted","0"},
         {"ep_total_enqueued","256"},
         {"ep_too_old","0"},
         {"ep_too_young","0"},
         {"ep_data_age_highwat","0"},
         {"ep_data_age","0"},
         {"ep_max_txn_size","50000"},
         {"ep_queue_age_cap","5"},
         {"ep_min_data_age","1"},
         {"ep_storage_age_highwat","0"},
         {"ep_storage_age","0"},
         {"ep_version","0.0.1_191_ga1119ca"}],

    {#stat_entry{timestamp=Now,
                 bytes_read=10332,
                 bytes_written=580019,
                 cas_badval=0,
                 cas_hits=0,
                 cas_misses=0,
                 cmd_get=0,
                 cmd_set=0,
                 curr_connections=11,
                 curr_items=0,
                 decr_hits=0,
                 decr_misses=0,
                 delete_hits=0,
                 delete_misses=0,
                 ep_flusher_todo=0,
                 ep_queue_size=0,
                 get_hits=0,
                 get_misses=0,
                 incr_hits=0,
                 incr_misses=0,
                 mem_used=0},
     [10332,580019,0,0,0,0,0,0,0,0,0,0,0,0,0]} =
         parse_stats(Now, Input,
                    lists:duplicate(length([?STAT_COUNTERS]), 0)).
