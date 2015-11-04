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

-export([get_type/0, get_remote_indexes/1, get_local_status/0, restart/0, get_status_mapping/0]).

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
