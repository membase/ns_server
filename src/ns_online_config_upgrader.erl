%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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

-module(ns_online_config_upgrader).

-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([upgrade_config/2, upgrade_config_on_join/1]).

%% exported for /diag/eval invocation for hot patching
-export([maybe_add_vbucket_map_history/1]).

upgrade_config_on_join(OldVersion) ->
    case OldVersion =:= [2, 0] of
        true ->
            ok;
        false ->
            ns_config:set(dynamic_config_version, OldVersion),
            ok = ns_config:upgrade_config_explicitly(fun do_upgrade_config_on_join/1)
    end.

do_upgrade_config_on_join(Config) ->
    case ns_config:search(Config, dynamic_config_version) of
        {value, undefined} ->
            [{set, dynamic_config_version, [2, 0]} |
             upgrade_config_on_join_from_pre_2_0_to_2_0(Config)];
        {value, [2, 0]} ->
            []
    end.

upgrade_config(OldVersion, NewVersion) ->
    true = (OldVersion =/= NewVersion),
    true = (NewVersion =< [2, 0]),

    ns_config:set(dynamic_config_version, OldVersion),
    ok = ns_config:upgrade_config_explicitly(
           fun (Config) ->
                   do_upgrade_config(Config, NewVersion)
           end).

do_upgrade_config(Config, FinalVersion) ->
    case ns_config:search(Config, dynamic_config_version) of
        {value, undefined} ->
            [{set, dynamic_config_version, [2, 0]} |
             upgrade_config_from_pre_2_0_to_2_0(Config)];
        {value, FinalVersion} ->
            [];
        {value, [2, 0]} ->
            [{set, dynamic_config_version, [2, 2]} |
             upgrade_config_from_2_0_to_2_2(Config)]
    end.

upgrade_config_on_join_from_pre_2_0_to_2_0(Config) ->
    ?log_info("Adding some 2.0 specific keys to the config"),
    maybe_add_vbucket_map_history(Config).

upgrade_config_from_pre_2_0_to_2_0(Config) ->
    ?log_info("Performing online config upgrade to 2.0 version"),
    maybe_add_buckets_uuids(Config).

upgrade_config_from_2_0_to_2_2(Config) ->
    ?log_info("Performing online config upgrade to 2.2 version"),
    upgrade_xdcr_settings(Config).

maybe_add_vbucket_map_history(Config) ->
    maybe_add_vbucket_map_history(Config, ?VBMAP_HISTORY_SIZE).

maybe_add_vbucket_map_history(Config, HistorySize) ->
    case ns_config:search(Config, vbucket_map_history) of
        {value, _} -> [];
        false ->
            Buckets = ns_bucket:get_buckets(Config),
            History = lists:flatmap(
                        fun ({_Bucket, BucketConfig}) ->
                                case proplists:get_value(map, BucketConfig, []) of
                                    [] -> [];
                                    Map ->
                                        case ns_rebalancer:unbalanced(Map, proplists:get_value(servers, BucketConfig, []), chain) of
                                            true ->
                                                [];
                                            false ->
                                                MapOptions = [{max_slaves, proplists:get_value(max_slaves, BucketConfig, 10)}],
                                                [{Map, MapOptions}]
                                        end
                                end
                        end, Buckets),
            UniqueHistory = lists:usort(History),
            FinalHistory = lists:sublist(UniqueHistory, HistorySize),
            [{set, vbucket_map_history, FinalHistory}]
    end.

maybe_add_buckets_uuids(Config) ->
    case ns_config:search(Config, buckets) of
        {value, Buckets} ->
            Configs = proplists:get_value(configs, Buckets, []),
            NewConfigs = lists:map(fun maybe_add_bucket_uuid/1, Configs),

            case NewConfigs =:= Configs of
                true ->
                    [];
                false ->
                    NewBuckets = misc:update_proplist(Buckets,
                                                      [{configs, NewConfigs}]),
                    [{set, buckets, NewBuckets}]
            end;
        false ->
            []
    end.

maybe_add_bucket_uuid({BucketName, BucketConfig} = Bucket) ->
    case proplists:get_value(uuid, BucketConfig) of
        undefined ->
            {BucketName, [{uuid, couch_uuids:random()} | BucketConfig]};
        _UUID ->
            Bucket
    end.

upgrade_xdcr_settings(Config) ->
    Mapping0 = [{list_to_atom("xdcr_" ++ atom_to_list(Key)), {xdcr, Key}}
                || {Key, _, _, _} <- xdc_settings:settings_specs()],
    Mapping = dict:from_list(Mapping0),
    ns_config:fold(
      fun (Key, Value, Acc) ->
              case dict:find(Key, Mapping) of
                  {ok, NewKey} ->
                      [{set, NewKey, Value} | Acc];
                  error ->
                      Acc
              end
      end, [], Config).

-ifdef(EUNIT).

add_vbucket_map_history_test() ->
    %% existing history is not overwritten
    OldCfg1 = [[{vbucket_map_history, [some_history]}]],
    ?assertEqual([], maybe_add_vbucket_map_history(OldCfg1)),

    %% empty history for no buckets
    OldCfg2 = [[{buckets,
                 [{configs, []}]}]],
    ?assertEqual([{set, vbucket_map_history, []}],
                 maybe_add_vbucket_map_history(OldCfg2)),

    %% empty history if there are some buckets but no maps
    OldCfg3 = [[{buckets,
                 [{configs,
                   [{"default", []}]}]}]],
    ?assertEqual([{set, vbucket_map_history, []}],
                 maybe_add_vbucket_map_history(OldCfg3)),

    %% empty history if there's a map but it's unbalanced
    OldCfg4 = [[{buckets,
                 [{configs,
                   [{"default",
                     [{map, [[n1, n2],
                             [n1, undefined],
                             [n1, undefined],
                             [n1, undefined]]},
                      {servers, [n1, n2, n3]}]}]}]}]],
    ?assertEqual([{set, vbucket_map_history, []}],
                 maybe_add_vbucket_map_history(OldCfg4)),

    %% finally generate some history
    Map1 = [[n1, n2],
            [n1, n2],
            [n2, n1],
            [n2, n1]],
    BucketConfig1 =
        [{num_replicas, 1},
         {num_vbuckets, 4},
         {servers, [n1, n2]},
         {max_slaves, 10},
         {map, Map1}],
    OldCfg5 = [[{buckets,
                 [{configs,
                   [{"default", BucketConfig1}]}]}]],
    ?assertEqual([{set, vbucket_map_history, [{Map1, [{max_slaves, 10}]}]}],
                 maybe_add_vbucket_map_history(OldCfg5)),

    %% don't return duplicated items in map history
    OldCfg6 = [[{buckets,
                 [{configs,
                   [{"default", BucketConfig1},
                    {"test", BucketConfig1}]}]}]],
    ?assertEqual([{set, vbucket_map_history, [{Map1, [{max_slaves, 10}]}]}],
                 maybe_add_vbucket_map_history(OldCfg6)),

    %% don't return more than history size items
    Map2 = [[n2, n1],
            [n2, n1],
            [n1, n2],
            [n1, n2]],
    BucketConfig2 =
        [{num_replicas, 1},
         {num_vbuckets, 4},
         {servers, [n1, n2]},
         {max_slaves, 10},
         {map, Map2}],
    OldCfg7 = [[{buckets,
                 [{configs,
                   [{"default", BucketConfig1},
                    {"test", BucketConfig2}]}]}]],
    ?assertMatch([{set, vbucket_map_history, [{_, [{max_slaves, 10}]}]}],
                 maybe_add_vbucket_map_history(OldCfg7, 1)),

    ok.

add_buckets_uuids_test() ->
    OldCfg1 = [[{buckets,
                 [{configs, []}]}]],
    ?assertEqual([],
                 maybe_add_buckets_uuids(OldCfg1)),

    OldCfg2 = [[{buckets,
                 [{configs, [{"default", []}]}]}]],
    ?assertMatch([{set, buckets, [{configs, [{"default", [{uuid, _}]}]}]}],
                 maybe_add_buckets_uuids(OldCfg2)),

    OldCfg3 = [[{buckets,
                 [{configs, [{"default", [{uuid, some_uuid}]}]}]}]],
    ?assertEqual([],
                 maybe_add_buckets_uuids(OldCfg3)),

    OldCfg4 = [[{buckets,
                 [{configs, [{"default", []}]},
                  {other, other}]}]],
    ?assertMatch([{set, buckets, [{configs, [{"default", [{uuid, _}]}]},
                                  {other, other}]}],
                 maybe_add_buckets_uuids(OldCfg4)),

    OldCfg5 = [[{buckets,
                 [{configs, [{"default", [{bucket_prop, bucket_prop}]},
                             {"bucket", [{uuid, some_uuid}]}]},
                  {other, other}]}]],
    ?assertMatch([{set, buckets,
                   [{configs, [{"default", [{uuid, _},
                                            {bucket_prop, bucket_prop}]},
                               {"bucket", [{uuid, some_uuid}]}]},
                    {other, other}]}],
                 maybe_add_buckets_uuids(OldCfg5)),

    OldCfg6 = [[]],
    ?assertEqual([],
                 maybe_add_buckets_uuids(OldCfg6)),

    ok.

upgrade_xdcr_settings_test() ->
    Cfg = [[{xdcr_max_concurrent_reps, 32},
            {xdcr_checkpoint_interval, 1800},
            {xdcr_doc_batch_size_kb, 2048},
            {xdcr_failure_restart_interval, 30},
            {xdcr_worker_batch_size, 500},
            {xdcr_connection_timeout, 180},
            {xdcr_worker_processes, 4},
            {xdcr_http_connections, 20},
            {xdcr_retries_per_request, 2},
            {xdcr_optimistic_replication_threshold, 256}]],

    ?assertEqual([{set, {xdcr, max_concurrent_reps}, 32},
                  {set, {xdcr, checkpoint_interval}, 1800},
                  {set, {xdcr, doc_batch_size_kb}, 2048},
                  {set, {xdcr, failure_restart_interval}, 30},
                  {set, {xdcr, worker_batch_size}, 500},
                  {set, {xdcr, connection_timeout}, 180},
                  {set, {xdcr, worker_processes}, 4},
                  {set, {xdcr, http_connections}, 20},
                  {set, {xdcr, retries_per_request}, 2},
                  {set, {xdcr, optimistic_replication_threshold}, 256}],
                 lists:reverse(upgrade_xdcr_settings(Cfg))).

-endif.
