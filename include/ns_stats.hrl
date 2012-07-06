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

-include("ns_common.hrl").

-define(stats_debug(Msg), ale:debug(?STATS_LOGGER, Msg)).
-define(stats_debug(Fmt, Args), ale:debug(?STATS_LOGGER, Fmt, Args)).

-define(stats_info(Msg), ale:info(?STATS_LOGGER, Msg)).
-define(stats_info(Fmt, Args), ale:info(?STATS_LOGGER, Fmt, Args)).

-define(stats_warning(Msg), ale:warn(?STATS_LOGGER, Msg)).
-define(stats_warning(Fmt, Args), ale:warn(?STATS_LOGGER, Fmt, Args)).

-define(stats_error(Msg), ale:error(?STATS_LOGGER, Msg)).
-define(stats_error(Fmt, Args), ale:error(?STATS_LOGGER, Fmt, Args)).

-define(STAT_GAUGES,

        %% Size of active couch data on disk
        couch_docs_data_size,
        %% Size of active couch view data on disk
        couch_views_data_size,
        %% Size of active and inactive couch data on disk (as reported by couch)
        couch_docs_disk_size,
        %% Size of active and inactive couch view data on disk (as reported by couch)
        couch_views_disk_size,
        %% Total size of couch data on disk
        couch_docs_actual_disk_size,
        %% Total size of couch view data on disk
        couch_views_actual_disk_size,

        %% Num items in active vbuckets.
        curr_items,

        mem_used,
        curr_connections,

        ep_mem_high_wat,
        ep_mem_low_wat,

        %% Num current items including those not active (replica, (NOT
        %% including dead) and pending states)
        curr_items_tot,

        %% Extra memory used by rep queues, etc..
        ep_overhead,
        ep_max_data_size,
        %% number of oom errors since boot. _not_ used by GUI, but
        %% used for oom alerts
        ep_oom_errors,

        %% Number of active vBuckets
        vb_active_num,
        %% Number of replica vBuckets
        vb_replica_num,
        %% Number of pending vBuckets
        vb_pending_num,
        ep_vb_total,

        % used for disk_write_queue computation in menelaus_stats
        ep_queue_size,
        ep_flusher_todo,

        %% Number of in memory items for replica vBuckets
        vb_replica_curr_items,
        %% Number of in memory items for pending vBuckets
        vb_pending_curr_items,

        %% Total item memory (K-V memory on UI)
        vb_active_itm_memory,
        %% Total item memory (K-V memory on UI)
        vb_replica_itm_memory,
        %% Total item memory (K-V memory on UI)
        vb_pending_itm_memory,

        %% Memory used to store keys and values. (K-V memory for total
        %% column) (includes dead vbuckets, apparently)
        ep_kv_size,

        %% Number of non-resident items in active vbuckets.
        vb_active_num_non_resident,
        %% Number of non-resident items in replica vbuckets
        vb_replica_num_non_resident,
        %% Number of non-resident items in pending vbuckets
        vb_pending_num_non_resident,
        %% The number of non-resident items (does not include dead
        %% vbuckets)
        ep_num_non_resident,

        %% Memory used to store keys and values (hashtable memory)
        vb_active_ht_memory,
        %% Memory used to store keys and values
        vb_replica_ht_memory,
        %% Memory used to store keys and values
        vb_pending_ht_memory,

        %% aggregated by collector: ep_ht_memory

        %% Active items in disk queue (incremented when item is
        %% dirtied and decremented when it's cleaned)
        vb_active_queue_size,
        %% Replica items in disk queue
        vb_replica_queue_size,
        %% Pending items in disk queue
        vb_pending_queue_size,
        %% aggregated by collector: vb_total_queue_size
        ep_diskqueue_items,

        %% Sum of disk queue item age in milliseconds
        vb_active_queue_age,
        %% Sum of disk queue item age in milliseconds
        vb_replica_queue_age,
        %% Sum of disk queue item age in milliseconds
        vb_pending_queue_age,
        %% aggregated by collector: vb_total_queue_age

        %% used by alerts
        ep_item_commit_failed
).

-define(STAT_COUNTERS,
        %% those are used be memcached buckets
        bytes_read,
        bytes_written,
        cas_badval,
        cas_hits,

        cas_misses,                             % Used by misses aggregation

        %% this is memcached-level stats
        % used by ops aggregation. Misses are used by misses aggregation
        cmd_get,
        cmd_set,
        decr_hits,
        decr_misses,
        delete_hits,
        delete_misses,
        incr_hits,
        incr_misses,

        %% XDCR related stats
        ep_num_ops_del_meta,
        ep_num_ops_get_meta,
        ep_num_ops_set_meta,

        %% this is memcached protocol hits & misses for get requests
        get_hits,
        get_misses,

        %% Number of io read operations
        %% ep_io_num_read,
        %% Total number of items persisted.
        %% ep_total_persisted,

        %% this is default bucket type evictions
        evictions,

        %% Number of times Not My VBucket exception happened during
        %% runtime
        %% ep_num_not_my_vbuckets,

        %% Number of times unrecoverable OOMs happened while
        %% processing operations
        %% ep_oom_errors,

        %% Number of times temporary OOMs happened while processing
        %% operations
        ep_tmp_oom_errors,

        %% Number of items fetched from disk.
        ep_bg_fetched,                          % needed by ep_cache_miss_rate
        %% Number of tap disk fetches
        %% ep_tap_bg_fetched,

        %% Number of times replica item values got ejected from memory
        %% to disk
        %% ep_num_eject_replicas,

        %% Number of times item values got ejected from memory to disk
        ep_num_value_ejects,

        %% Number of create operations
        vb_active_ops_create,
        %% Number of create operations
        vb_replica_ops_create,
        %% Number of create operations
        vb_pending_ops_create,
        %% ep_ops_create: aggregated by stats_collector

        %% Number of update operations
        vb_active_ops_update,
        %% Number of update operations
        vb_replica_ops_update,
        %% Number of update operations
        vb_pending_ops_update,
        %% ep_ops_update: aggregated by stats_collector

        %% Total enqueued items
        vb_active_queue_fill,
        %% Total enqueued items
        vb_replica_queue_fill,
        %% Total enqueued items
        vb_pending_queue_fill,
        %% vb_total_queue_fill: aggregated by stats_collector
        ep_diskqueue_fill,

        %% Number of times item values got ejected
        vb_active_eject,
        %% Number of times item values got ejected
        vb_replica_eject,
        %% Number of times item values got ejected
        vb_pending_eject,
        %% Number of times item values got ejected from memory to disk
        ep_num_value_ejects,

        %% Total drained items
        vb_active_queue_drain,
        %% Total drained items
        vb_replica_queue_drain,
        %% Total drained items
        vb_pending_queue_drain,
        %% vb_total_queue_drain: aggregated by stats_collector
        ep_diskqueue_drain
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
                           queue_itemondisk = 0,
                           total_backlog_size = 0}).

-define(TAP_STAT_GAUGES,
        ep_tap_rebalance_count, ep_tap_rebalance_qlen, ep_tap_rebalance_queue_backfillremaining, ep_tap_rebalance_queue_itemondisk, ep_tap_rebalance_total_backlog_size,
        ep_tap_replica_count, ep_tap_replica_qlen, ep_tap_replica_queue_backfillremaining, ep_tap_replica_queue_itemondisk, ep_tap_replica_total_backlog_size,
        ep_tap_user_count, ep_tap_user_qlen, ep_tap_user_queue_backfillremaining, ep_tap_user_queue_itemondisk, ep_tap_user_total_backlog_size,
        ep_tap_total_count, ep_tap_total_qlen, ep_tap_total_queue_backfillremaining, ep_tap_total_queue_itemondisk, ep_tap_total_total_backlog_size).
-define(TAP_STAT_COUNTERS,
        ep_tap_rebalance_queue_fill, ep_tap_rebalance_queue_drain, ep_tap_rebalance_queue_backoff,
        ep_tap_replica_queue_fill, ep_tap_replica_queue_drain, ep_tap_replica_queue_backoff,
        ep_tap_user_queue_fill, ep_tap_user_queue_drain, ep_tap_user_queue_backoff,
        ep_tap_total_queue_fill, ep_tap_total_queue_drain, ep_tap_total_queue_backoff).

-ifdef(NEED_TAP_STREAM_STATS_CODE).

-define(DEFINE_EXTRACT(A, N), extract_agg_stat(<<??A>>, V, Acc) ->
               Acc#tap_stream_stats{N = list_to_integer(binary_to_list(V))}).
?DEFINE_EXTRACT(qlen, qlen);
?DEFINE_EXTRACT(fill, queue_fill);
?DEFINE_EXTRACT(drain, queue_drain);
?DEFINE_EXTRACT(backoff, queue_backoff);
?DEFINE_EXTRACT(backfill_remaining, queue_backfillremaining);
?DEFINE_EXTRACT(itemondisk, queue_itemondisk);
?DEFINE_EXTRACT(total_backlog_size, total_backlog_size);
?DEFINE_EXTRACT(count, count);
extract_agg_stat(_K, _V, Acc) -> Acc.
-undef(DEFINE_EXTRACT).

-define(DEFINE_TO_KVLIST(N), {<<Prefix/binary, ??N>>, list_to_binary(integer_to_list(Record#tap_stream_stats.N))}).
tap_stream_stats_to_kvlist(Prefix, Record) ->
    [?DEFINE_TO_KVLIST(count),
     ?DEFINE_TO_KVLIST(qlen),
     ?DEFINE_TO_KVLIST(queue_fill),
     ?DEFINE_TO_KVLIST(queue_drain),
     ?DEFINE_TO_KVLIST(queue_backoff),
     ?DEFINE_TO_KVLIST(queue_backfillremaining),
     ?DEFINE_TO_KVLIST(queue_itemondisk),
     ?DEFINE_TO_KVLIST(total_backlog_size)].
-undef(DEFINE_TO_KVLIST).

-define(DEFINE_ADDER(N), N = A#tap_stream_stats.N + B#tap_stream_stats.N).
add_tap_stream_stats(A, B) ->
    #tap_stream_stats{?DEFINE_ADDER(count),
                      ?DEFINE_ADDER(qlen),
                      ?DEFINE_ADDER(queue_fill),
                      ?DEFINE_ADDER(queue_drain),
                      ?DEFINE_ADDER(queue_backoff),
                      ?DEFINE_ADDER(queue_backfillremaining),
                      ?DEFINE_ADDER(queue_itemondisk),
                      ?DEFINE_ADDER(total_backlog_size)}.
-undef(DEFINE_ADDER).

-define(DEFINE_SUBTRACTOR(N), N = A#tap_stream_stats.N - B#tap_stream_stats.N).
sub_tap_stream_stats(A, B) ->
    #tap_stream_stats{?DEFINE_SUBTRACTOR(count),
                      ?DEFINE_SUBTRACTOR(qlen),
                      ?DEFINE_SUBTRACTOR(queue_fill),
                      ?DEFINE_SUBTRACTOR(queue_drain),
                      ?DEFINE_SUBTRACTOR(queue_backoff),
                      ?DEFINE_SUBTRACTOR(queue_backfillremaining),
                      ?DEFINE_SUBTRACTOR(queue_itemondisk),
                      ?DEFINE_SUBTRACTOR(total_backlog_size)}.
-undef(DEFINE_SUBTRACTOR).

-endif. % NEED_TAP_STREAM_STATS_CODE
