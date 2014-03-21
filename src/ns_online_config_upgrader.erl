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
    true = (NewVersion =< [3, 0]),

    ns_config:set(dynamic_config_version, OldVersion),
    ok = ns_config:upgrade_config_explicitly(
           fun (Config) ->
                   do_upgrade_config(Config, NewVersion)
           end).

do_upgrade_config(Config, FinalVersion) ->
    case ns_config:search(Config, dynamic_config_version) of
        {value, undefined} ->
            [{set, dynamic_config_version, [2, 0]}];
        {value, FinalVersion} ->
            [];
        {value, [2, 0]} ->
            [{set, dynamic_config_version, [2, 5]} |
             upgrade_config_from_2_0_to_2_5(Config)];
        {value, [2, 5]} ->
            [{set, dynamic_config_version, [3, 0]} |
            upgrade_config_from_2_5_to_3_0(Config)]
    end.

upgrade_config_from_2_0_to_2_5(Config) ->
    ?log_info("Performing online config upgrade to 2.5 version"),
    create_server_groups(Config).

upgrade_config_from_2_5_to_3_0(Config) ->
    ?log_info("Performing online config upgrade to 3.0 version"),
    ns_config_auth:upgrade(Config).

create_server_groups(Config) ->
    {value, Nodes} = ns_config:search(Config, nodes_wanted),
    [{set, server_groups, [[{uuid, <<"0">>},
                            {name, <<"Group 1">>},
                            {nodes, Nodes}]]}].
