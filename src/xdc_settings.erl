%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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

-module(xdc_settings).

-export([get_global_setting/1, update_global_settings/1,
         get_all_global_settings/0, extract_per_replication_settings/1,
         get_all_settings_snapshot/1, get_all_settings_snapshot_by_doc_id/1,
         settings_specs/0, per_replication_settings_specs/0]).

-include("couch_db.hrl").

get_global_setting(Key) ->
    Ref = make_ref(),
    case ns_config:read_key_fast({xdcr, Key}, Ref) of
        Ref ->
            Specs = settings_specs(),
            {Key, _, _, Default} = lists:keyfind(Key, 1, Specs),
            Default;
        V ->
            V
    end.

update_global_settings(KVList0) ->
    KVList = [{{xdcr, K}, V} || {K, V} <- KVList0],
    ns_config:set(KVList),
    ns_config:sync_announcements().

get_all_global_settings() ->
    Settings0 = [{Key, Default} || {Key, _, _, Default} <- settings_specs()],

    lists:map(
      fun ({Key, Default}) ->
              Value = ns_config:read_key_fast({xdcr, Key}, Default),
              {Key, Value}
      end, Settings0).

extract_per_replication_settings(#doc{body={Props}}) ->
    extract_per_replication_settings(Props);
extract_per_replication_settings(Props) ->
    InterestingKeys = [couch_util:to_binary(element(1, Spec)) ||
                          Spec <- xdc_settings:per_replication_settings_specs()],

    [{K, V} || {K, V} <- Props, lists:member(K, InterestingKeys)].

get_all_settings_snapshot(Props) ->
    GlobalSettings = get_all_global_settings(),
    ReplicationSettings0 = extract_per_replication_settings(Props),
    ReplicationSettings = [{couch_util:to_existing_atom(K), V} ||
                              {K, V} <- ReplicationSettings0],
    misc:update_proplist(GlobalSettings, ReplicationSettings).

get_all_settings_snapshot_by_doc_id(DocId) when is_binary(DocId) ->
    {ok, #doc{body={Props}}} = xdc_rdoc_api:get_full_replicator_doc(DocId),
    get_all_settings_snapshot(Props).

settings_specs() ->
    [{max_concurrent_reps,              per_replication, {int, 2, 256},              16},
     {checkpoint_interval,              per_replication, {int, 10, 14400},           1800},
     {doc_batch_size_kb,                per_replication, {int, 10, 10000},           2048},
     {failure_restart_interval,         per_replication, {int, 1, 300},              30},
     {worker_batch_size,                per_replication, {int, 500, 10000},          500},
     {connection_timeout,               per_replication, {int, 10, 10000},           180},
     {worker_processes,                 per_replication, {int, 1, 128},               4},
     {http_connections,                 per_replication, {int, 1, 100},              20},
     {retries_per_request,              per_replication, {int, 1, 100},              2},
     {optimistic_replication_threshold, per_replication, {int, 0, 20 * 1024 * 1024}, 256},
     {socket_options,                   per_replication, term,                       [{keepalive, true}, {nodelay, false}]},
     {pause_requested,                  per_replication, bool,                       false},
     {supervisor_max_r,                 per_replication, {int, 1, 1000},             25},
     {supervisor_max_t,                 per_replication, {int, 1, 1000},             5}].

per_replication_settings_specs() ->
    [{Key, Type} || {Key, per_replication, Type, _Default} <- settings_specs()].
