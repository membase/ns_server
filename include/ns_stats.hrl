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
        mem_used).

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
        ep_io_num_read).

-record(stat_entry, {timestamp, ?STAT_GAUGES, ?STAT_COUNTERS}).
-define(STAT_FIELD_START, 2).
-define(STAT_SIZE, 22).
