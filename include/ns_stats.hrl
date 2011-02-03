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

-define(STAT_GAUGES,
        curr_items,
        %% used for disk_writes aggregation
        ep_flusher_todo,
        ep_queue_size,

        mem_used,                               % used by memcached
        curr_connections,                       % used by memcached

        curr_items_tot,
        %% ep_num_non_resident,
        ep_num_active_non_resident,             % needed by ep_resident_items_rate
        %% ep_keys_size,
        %% ep_values_size,
        %% ep_overhead

        vb_active_num,
        vb_replica_num,
        vb_pending_num,
        %% aggregated by collector: ep_vb_total

        vb_replica_curr_items,
        vb_pending_curr_items,

        vb_active_itm_memory,
        vb_replica_itm_memory,
        vb_pending_itm_memory,
        ep_kv_size,

        ep_num_active_non_resident,
        ep_num_replica_non_resident,
        ep_num_pending_non_resident,
        ep_num_non_resident,

        vb_active_ht_memory,
        vb_replica_ht_memory,
        vb_pending_ht_memory,
        %% aggregated by collector: ep_ht_memory

        vb_active_queue_pending,
        vb_replica_queue_pending,
        vb_pending_queue_pending,
        %% aggregated by collector: disk_writes

        vb_active_queue_memory,
        vb_replica_queue_memory,
        vb_pending_queue_memory,
        %% aggregated by collector: vb_total_queue_memory

        vb_active_queue_age,
        vb_replica_queue_age,
        vb_pending_queue_age
        %% aggregated by collector: vb_total_queue_age
).

-define(STAT_COUNTERS,
        %% those are used be memcached buckets
        bytes_read,
        bytes_written,
        cas_badval,
        cas_hits,

        cas_misses,                             % TODO: check! Used by misses aggregation

        % used by ops aggregation. Misses are used by misses aggregation
        cmd_get,
        cmd_set,
        decr_hits,
        decr_misses,
        delete_hits,
        delete_misses,
        incr_hits,
        incr_misses,

        %% TODO: used cache hit ratio ?
        get_hits,
        get_misses,

        %% ep_io_num_read,
        %% ep_total_persisted,

        evictions,

        %% ep_num_not_my_vbuckets,
        %% ep_oom_errors,
        %% ep_tmp_oom_errors,

        ep_bg_fetched,                          % needed by ep_cache_miss_rate
        %% ep_tap_bg_fetched,

        %% ep_num_eject_replicas,
        %% ep_num_value_ejects

        %% ep_ops_create: aggregated by stats_collector
        %% TODO aggregate: ep_ops_update
        ep_tap_queue_backoff,

        vb_active_ops_create,
        vb_replica_ops_create,
        vb_pending_ops_create,
        %% ep_ops_create: aggregated by stats_collector

        vb_active_queue_fill,
        vb_replica_queue_fill,
        vb_pending_queue_fill,
        %% vb_total_queue_fill: aggregated by stats_collector

        vb_active_queue_drain,
        vb_replica_queue_drain,
        vb_pending_queue_drain
        %% vb_total_queue_drain: aggregated by stats_collector
).

%% atom() timestamps and values are used by archiver for internal mnesia-related
%% things
-record(stat_entry, {timestamp :: integer() | atom(),
                     values :: [{atom(), number()}] | '_'}).

-record(tap_stream_stats, {count = 0,
                           qlen = 0,
                           queue_fill = 0,
                           queue_drain = 0,
                           queue_backoff = 0,
                           queue_backfillremaining = 0,
                           queue_itemondisk = 0}).

-define(TAP_STAT_GAUGES,
        ep_tap_rebalance_count, ep_tap_rebalance_qlen, ep_tap_rebalance_queue_backfillremaining, ep_tap_rebalance_queue_itemondisk,
        ep_tap_replica_count, ep_tap_replica_qlen, ep_tap_replica_queue_backfillremaining, ep_tap_replica_queue_itemondisk,
        ep_tap_user_count, ep_tap_user_qlen, ep_tap_user_queue_backfillremaining, ep_tap_user_queue_itemondisk,
        ep_tap_total_count, ep_tap_total_qlen, ep_tap_total_queue_backfillremaining, ep_tap_total_queue_itemondisk).
-define(TAP_STAT_COUNTERS,
        ep_tap_rebalance_queue_fill, ep_tap_rebalance_queue_drain, ep_tap_rebalance_queue_backoff,
        ep_tap_replica_queue_fill, ep_tap_replica_queue_drain, ep_tap_replica_queue_backoff,
        ep_tap_user_queue_fill, ep_tap_user_queue_drain, ep_tap_user_queue_backoff,
        ep_tap_total_queue_fill, ep_tap_total_queue_drain, ep_tap_total_queue_backoff).

-ifdef(NEED_TAP_STREAM_STATS_CODE).

-define(DEFINE_EXTRACT(N), extact_tap_stat(<<??N>>, V, Acc) ->
               Acc#tap_stream_stats{N = list_to_integer(binary_to_list(V))}).
?DEFINE_EXTRACT(qlen);
?DEFINE_EXTRACT(queue_fill);
?DEFINE_EXTRACT(queue_drain);
?DEFINE_EXTRACT(queue_backoff);
?DEFINE_EXTRACT(queue_backfillremaining);
?DEFINE_EXTRACT(queue_itemondisk);
%% we're using something that is always present to 'extract' count
extact_tap_stat(<<"type">>, _V, Acc) ->
    Acc#tap_stream_stats{count = 1};
extact_tap_stat(_K, _V, Acc) -> Acc.
-undef(DEFINE_EXTRACT).

-define(DEFINE_TO_KVLIST(N), {<<Prefix/binary, ??N>>, list_to_binary(integer_to_list(Record#tap_stream_stats.N))}).
tap_stream_stats_to_kvlist(Prefix, Record) ->
    [?DEFINE_TO_KVLIST(count),
     ?DEFINE_TO_KVLIST(qlen),
     ?DEFINE_TO_KVLIST(queue_fill),
     ?DEFINE_TO_KVLIST(queue_drain),
     ?DEFINE_TO_KVLIST(queue_backoff),
     ?DEFINE_TO_KVLIST(queue_backfillremaining),
     ?DEFINE_TO_KVLIST(queue_itemondisk)].
-undef(DEFINE_TO_KVLIST).

-define(DEFINE_ADDER(N), N = A#tap_stream_stats.N + B#tap_stream_stats.N).
add_tap_stream_stats(A, B) ->
    #tap_stream_stats{?DEFINE_ADDER(count),
                      ?DEFINE_ADDER(qlen),
                      ?DEFINE_ADDER(queue_fill),
                      ?DEFINE_ADDER(queue_drain),
                      ?DEFINE_ADDER(queue_backoff),
                      ?DEFINE_ADDER(queue_backfillremaining),
                      ?DEFINE_ADDER(queue_itemondisk)}.
-undef(DEFINE_ADDER).

-endif. % NEED_TAP_STREAM_STATS_CODE
