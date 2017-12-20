%% @author Couchbase <info@couchbase.com>
%% @copyright 2018 Couchbase, Inc.
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
%% @doc this module implements access to analytics service via REST API
%%

-module(cbas_rest).

-include("ns_common.hrl").

-export([get_stats/0]).

get_stats() ->
    case ns_cluster_membership:should_run_service(ns_config:latest(), cbas, node()) of
        true ->
            do_get_stats();
        false ->
            []
    end.

get_port() ->
    ns_config:read_key_fast({node, node(), cbas_admin_port}, 9110).

get_timeout() ->
    30000.

do_get_stats() ->
    index_rest:get_json(cbas, "analytics/node/stats", get_port(), get_timeout()).
