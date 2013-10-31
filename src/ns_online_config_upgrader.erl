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

upgrade_config(OldVersion, NewVersion) ->
    true = (OldVersion =/= NewVersion),
    true = (NewVersion =< [2, 5]),

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
            [{set, dynamic_config_version, [2, 5]} |
             upgrade_config_from_2_0_to_2_5(Config)];
        {value, [2, 5]} ->
            [{set, dynamic_config_version, [3, 0]}]
    end.

upgrade_config_from_pre_2_0_to_2_0(Config) ->
    ?log_info("Performing online config upgrade to 2.0 version"),
    maybe_add_buckets_uuids(Config).

upgrade_config_from_2_0_to_2_5(Config) ->
    ?log_info("Performing online config upgrade to 2.5 version"),
    create_server_groups(Config).

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

create_server_groups(Config) ->
    {value, Nodes} = ns_config:search(Config, nodes_wanted),
    [{set, server_groups, [[{uuid, <<"0">>},
                            {name, <<"Group 1">>},
                            {nodes, Nodes}]]}].

