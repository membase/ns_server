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
-module(indexer_gsi).

-include_lib("eunit/include/eunit.hrl").

-export([start_keeper/0, get_status/1, get_indexes/0, get_indexes_version/0]).

-export([get_type/0, get_remote_indexes/1, get_local_status/0, restart/0, get_status_mapping/0,
        get_gauges/0, get_counters/0, get_computed/0, grab_stats/0, prefix/0,
        per_index_stat/2, global_index_stat/1, compute_gauges/1]).

get_status(Timeout) ->
    index_status_keeper:get_status(?MODULE, Timeout).

get_indexes() ->
    index_status_keeper:get_indexes(?MODULE).

get_indexes_version() ->
    index_status_keeper:get_indexes_version(?MODULE).

get_type() ->
    index.

get_port() ->
    ns_config:read_key_fast({node, node(), indexer_http_port}, 9102).

get_timeout() ->
    ns_config:get_timeout(index_rest_request, 10000).

get_remote_indexes(Node) ->
    remote_api:get_indexes(Node).

get_local_status() ->
    index_rest:get_json(indexer, "getIndexStatus", get_port(), get_timeout()).

restart() ->
    ns_ports_setup:restart_port_by_name(indexer).

get_status_mapping() ->
    [{id, <<"defnId">>},
     {index, <<"name">>},
     {bucket, <<"bucket">>},
     {status, <<"status">>},
     {definition, <<"definition">>},
     {progress, <<"completion">>},
     {hosts, <<"hosts">>}].

start_keeper() ->
    index_status_keeper:start_link(?MODULE).

get_gauges() ->
    [disk_size, data_size, num_docs_pending, num_docs_queued,
     items_count, frag_percent].

get_counters() ->
    [num_requests, num_rows_returned, num_docs_indexed,
     scan_bytes_read, total_scan_duration].

get_computed() ->
    [disk_overhead_estimate].

grab_stats() ->
    index_rest:get_json(indexer, "stats?async=true", get_port(), get_timeout()).

prefix() ->
    "@" ++ atom_to_list(get_type()) ++ "-".

per_index_stat(Index, Metric) ->
    iolist_to_binary([atom_to_list(get_type()), <<"/">>, Index, $/, Metric]).

global_index_stat(StatName) ->
    iolist_to_binary([atom_to_list(get_type()), <<"/">>, StatName]).

compute_gauges(Gauges) ->
    compute_disk_overhead_estimates(Gauges).

compute_disk_overhead_estimates(Stats) ->
    Dict = lists:foldl(
             fun ({StatKey, Value}, D) ->
                     {Bucket, Index, Metric} = StatKey,
                     Key = {Bucket, Index},

                     case Metric of
                         <<"frag_percent">> ->
                             misc:dict_update(
                               Key,
                               fun ({_, DiskSize}) ->
                                       {Value, DiskSize}
                               end, {undefined, undefined}, D);
                         <<"disk_size">> ->
                             misc:dict_update(
                               Key,
                               fun ({Frag, _}) ->
                                       {Frag, Value}
                               end, {undefined, undefined}, D);
                         _ ->
                             D
                     end
             end, dict:new(), Stats),

    dict:fold(
      fun ({Bucket, Index}, {Frag, DiskSize}, Acc) ->
              if
                  Frag =/= undefined andalso DiskSize =/= undefined ->
                      Est = (DiskSize * Frag) div 100,
                      [{{Bucket, Index, <<"disk_overhead_estimate">>}, Est} | Acc];
                  true ->
                      Acc
              end
      end, [], Dict).

compute_disk_overhead_estimates_test() ->
    In = [{{<<"a">>, <<"idx1">>, <<"disk_size">>}, 100},
          {{<<"a">>, <<"idx1">>, <<"frag_percent">>}, 0},
          {{<<"b">>, <<"idx2">>, <<"frag_percent">>}, 100},
          {{<<"b">>, <<"idx2">>, <<"disk_size">>}, 100},
          {{<<"b">>, <<"idx3">>, <<"disk_size">>}, 100},
          {{<<"b">>, <<"idx3">>, <<"frag_percent">>}, 50},
          {{<<"b">>, <<"idx3">>, <<"m">>}, 42}],
    Out = lists:keysort(1, compute_disk_overhead_estimates(In)),

    Expected0 = [{{<<"a">>, <<"idx1">>, <<"disk_overhead_estimate">>}, 0},
                 {{<<"b">>, <<"idx2">>, <<"disk_overhead_estimate">>}, 100},
                 {{<<"b">>, <<"idx3">>, <<"disk_overhead_estimate">>}, 50}],
    Expected = lists:keysort(1, Expected0),

    ?assertEqual(Expected, Out).
