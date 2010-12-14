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
        curr_connections,
        curr_items,
        ep_flusher_todo,
        ep_queue_size,
        mem_used,
        curr_items_tot,
        ep_num_non_resident,
        ep_keys_size,
        ep_values_size,
        ep_overhead).

-define(STAT_COUNTERS,
        bytes_read,
        bytes_written,
        cas_badval,
        cas_hits,
        cas_misses,
        cmd_get,
        cmd_set,
        decr_hits,
        decr_misses,
        delete_hits,
        delete_misses,
        get_hits,
        get_misses,
        incr_hits,
        incr_misses,
        ep_io_num_read,
        ep_total_persisted,
        evictions,
        ep_num_not_my_vbuckets,
        ep_oom_errors,
        ep_tmp_oom_errors,
        ep_bg_fetched,
        ep_tap_bg_fetched,
        ep_num_eject_replicas,
        ep_num_value_ejects).

%% atom() timestamps and values are used by archiver for internal mnesia-related
%% things
-record(stat_entry, {timestamp :: integer() | atom(),
                     values :: [{atom(), number()}] | '_'}).
