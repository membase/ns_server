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
-module(indexer_fts).

-export([start_keeper/0, get_indexes/0]).

-export([get_type/0, get_remote_indexes/1, get_local_status/0, restart/0, get_status_mapping/0,
         get_gauges/0, get_counters/0, get_computed/0, grab_stats/0, prefix/0,
         per_index_stat/2, global_index_stat/1, compute_gauges/1]).

get_indexes() ->
    index_status_keeper:get_indexes(?MODULE).

get_type() ->
    fts.

get_port() ->
    ns_config:read_key_fast({node, node(), fts_http_port}, 9110).

get_timeout() ->
    ns_config:get_timeout(fts_rest_request, 10000).

get_remote_indexes(Node) ->
    remote_api:get_fts_indexes(Node).

get_local_status() ->
    index_rest:get_json(fts, "api/nsstatus", get_port(), get_timeout()).

restart() ->
    ns_ports_setup:restart_port_by_name(fts).

get_status_mapping() ->
    [{[index, id], <<"name">>},
     {bucket, <<"bucket">>},
     {status, <<"status">>},
     {progress, <<"completion">>},
     {hosts, <<"hosts">>}].

start_keeper() ->
    index_status_keeper:start_link(?MODULE).

get_gauges() ->
    [doc_count, num_pindexes].

get_counters() ->
    [timer_batch_execute_count, timer_batch_merge_count, timer_batch_store_count,
     timer_iterator_next_count, timer_iterator_seek_count, timer_iterator_seek_first_count,
     timer_reader_get_count, timer_reader_iterator_count, timer_writer_delete_count,
     timer_writer_get_count, timer_writer_iterator_count, timer_writer_set_count,
     timer_opaque_set_count, timer_rollback_count, timer_data_update_count,
     timer_data_delete_count, timer_snapshot_start_count, timer_opaque_get_count].

get_computed() ->
    [].

grab_stats() ->
    index_rest:get_json(fts, "api/nsstats", get_port(), get_timeout()).

prefix() ->
    "@" ++ atom_to_list(get_type()) ++ "-".

per_index_stat(Index, Metric) ->
    iolist_to_binary([atom_to_list(get_type()), <<"/">>, Index, $/, Metric]).

global_index_stat(StatName) ->
    iolist_to_binary([atom_to_list(get_type()), <<"/">>, StatName]).

compute_gauges(_Gauges) ->
    [].
