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

-export([start/0, stop/0, remote_stop/1, override_resolver/0]).

start() ->
    try
        %% Check disk space every minute instead of every 30
        application:set_env(os_mon, disk_space_check_interval, 1),
        ok = application:start(ale),
        application:start(os_mon),
        case erlang:system_info(system_architecture) of
            "win32" -> inet_db:set_lookup([native, file]);
            _ -> ok
        end,
        ok = application:start(ns_server)
    catch T:E ->
            timer:sleep(500),
            erlang:T(E)
    end.

stop() ->
    RV = try
             ok = application:stop(ns_server),
             application:stop(os_mon),
             application:stop(ale),

             ok
         catch T:E ->
                 {T, E}
         end,

    case RV of
        ok -> init:stop();
        X -> X
    end.

%% Call ns_bootstrap:stop on a remote node and exit with status indicating the
%% success of the call.
remote_stop(Node) ->
    RV = rpc:call(Node, ns_bootstrap, stop, []),
    ExitStatus = case RV of
                     ok -> 0;
                     _ -> 1
                 end,
    init:stop(ExitStatus).

override_resolver() ->
    inet_db:set_lookup([file, dns]),
    start().
