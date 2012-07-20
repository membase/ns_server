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

-export([upgrade_config/2]).

%% exported for /diag/eval invocation for hot patching
-export([maybe_add_vbucket_map_history/1]).

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
            []
    end.

upgrade_config_from_pre_2_0_to_2_0(Config) ->
    ?log_info("Performing online config upgrade to 2.0 version"),
    maybe_add_vbucket_map_history(Config).

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
                                        case ns_rebalancer:unbalanced(Map, proplists:get_value(servers, BucketConfig, [])) of
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

-endif.
