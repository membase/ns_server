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

-define(STAT_ENTRY, {bytes_read,
                     bytes_written,
                     cas_badval,
                     cas_hits,
                     cas_misses,
                     cmd_get,
                     cmd_set,
                     curr_connections,
                     curr_items,
                     decr_hits,
                     decr_misses,
                     delete_hits,
                     delete_misses,
                     ep_flusher_todo,
                     ep_queue_size,
                     get_hits,
                     get_misses,
                     incr_hits,
                     incr_misses,
                     mem_used}).

-record(stat_entry, ?STAT_ENTRY).

-record(stat_archive, {%% These are counters. Archive will only have rate.
                       bytes_read_max,
                       bytes_read_avg,
                       bytes_read_min,
                       bytes_written_max,
                       bytes_written_avg,
                       bytes_written_min,
                       cas_badval_max,
                       cas_badval_avg,
                       cas_badval_min,
                       cas_hits_max,
                       cas_hits_avg,
                       cas_hits_min,
                       cas_misses_max,
                       cas_misses_avg,
                       cas_misses_min,
                       cmd_get_max,
                       cmd_get_avg,
                       cmd_get_min,
                       cmd_set_max,
                       cmd_set_avg,
                       cmd_set_min,
                       decr_hits_max,
                       decr_hits_avg,
                       decr_hits_min,
                       decr_misses_max,
                       decr_misses_avg,
                       decr_misses_min,
                       delete_hits_max,
                       delete_hits_avg,
                       delete_hits_min,
                       delete_misses_max,
                       delete_misses_avg,
                       delete_misses_min,
                       get_hits_max,
                       get_hits_avg,
                       get_hits_min,
                       get_misses,
                       incr_hits,
                       incr_misses,
                       %% Gauge values; both gauge and rate
                       curr_connections_max,
                       curr_connections_avg,
                       curr_connections_min,
                       curr_connections_rate_max,
                       curr_connections_rate_avg,
                       curr_connections_rate_min,
                       curr_items_max,
                       curr_items_avg,
                       curr_items_min,
                       curr_items_rate_max,
                       curr_items_rate_avg,
                       curr_items_rate_min,
                       mem_used_min,
                       mem_used_avg,
                       mem_used_max,
                       mem_used_rate_max,
                       mem_used_rate_avg,
                       mem_used_rate_min,
                       %% Gauge values; gauge only.
                       ep_flusher_todo_max,
                       ep_flusher_todo_avg,
                       ep_flusher_todo_min,
                       ep_queue_size_max,
                       ep_queue_size_avg,
                       ep_queue_size_min}).
