%% @author Couchbase <info@couchbase.com>
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
-module(rest_utils).

-export([request/6]).

request(Type, URL, Method, Headers, Body, Timeout) ->
    system_stats_collector:increment_counter({Type, requests}, 1),

    Start = os:timestamp(),
    RV = lhttpc:request(URL, Method, Headers, Body, Timeout, []),
    case RV of
        {ok, {{Code, _}, _, _}} ->
            Diff = timer:now_diff(os:timestamp(), Start),
            system_stats_collector:add_histo({Type, latency}, Diff),

            Class = (Code div 100) * 100,
            system_stats_collector:increment_counter({Type, status, Class}, 1);
        _ ->
            system_stats_collector:increment_counter({Type, failed_requests}, 1)
    end,

    RV.
