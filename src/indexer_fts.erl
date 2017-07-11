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
         per_index_stat/2, global_index_stat/1, compute_gauges/1,
         get_service_stats/0, service_stat_prefix/0, service_event_name/0,
         compute_service_stats/1]).

get_indexes() ->
    index_status_keeper:get_indexes(?MODULE).

get_type() ->
    fts.

get_port() ->
    ns_config:read_key_fast({node, node(), fts_http_port}, 8094).

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
     {hosts, <<"hosts">>}].

start_keeper() ->
    index_status_keeper:start_link(?MODULE).

get_gauges() ->
    [num_mutations_to_index, doc_count, num_recs_to_persist, num_bytes_used_disk,
    num_pindexes_actual, num_pindexes_target].

get_counters() ->
    [total_bytes_indexed, total_compaction_written_bytes, total_queries,
    total_queries_slow, total_queries_timeout, total_queries_error,
    total_bytes_query_results, total_term_searchers, total_request_time].

get_computed() ->
    [].

get_service_stats() ->
    [num_bytes_used_ram].

grab_stats() ->
    index_rest:get_json(fts, "api/nsstats", get_port(), get_timeout()).

prefix() ->
    "@" ++ atom_to_list(get_type()) ++ "-".

service_stat_prefix() ->
    atom_to_list(get_type()) ++ "_".

service_event_name() ->
    "@" ++ atom_to_list(get_type()).

per_index_stat(Index, Metric) ->
    iolist_to_binary([atom_to_list(get_type()), <<"/">>, Index, $/, Metric]).

global_index_stat(StatName) ->
    iolist_to_binary([atom_to_list(get_type()), <<"/">>, StatName]).

compute_service_stats(_Stats) ->
    [].

compute_gauges(_Gauges) ->
    [].
