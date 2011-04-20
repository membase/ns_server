%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
-module(ns_bootstrap).

-export([start/0, override_resolver/0]).

start() ->
    try
        %% Check disk space every minute instead of every 30
        application:set_env(os_mon, disk_space_check_interval, 1),
        ok = application:start(sasl),
        application:start(os_mon),
        case erlang:system_info(system_architecture) of
            "win32" -> inet_db:set_lookup([native, file]);
            _ -> ok
        end,
        ok = application:start(ns_server),
        case os:getenv("DONT_START_COUCH") of
            false ->
                case erlang:system_info(system_architecture) of
                    "win32" -> ok;
                    _ ->
                        ok = application:start(couch)
                end;
            _ -> ok
        end
    catch T:E ->
            timer:sleep(500),
            erlang:T(E)
    end.

override_resolver() ->
    inet_db:set_lookup([file, dns]),
    start().
