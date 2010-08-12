%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
-module(ns_server).

-behavior(application).

-export([start/2, stop/1, ns_log_cat/1]).

start(_Type, _Args) ->
    supervisor:start_link({local, ns_server_cluster_sup},
                          gen_sup, {{one_for_one, 10, 1},
                                    [{ns_log_mf_h, {ns_log_mf_h, start_link, []},
                                      transient, 10, worker, [ns_log_mf_h]},
                                     {dist_manager, {dist_manager, start_link, []},
                                      permanent, 10, worker, [dist_manager]},
                                     {ns_cluster, {ns_cluster, start_link, []},
                                      permanent, 5000, worker, [ns_cluster]}
                                    ]}).

stop(_State) ->
    ok.

ns_log_cat(_) -> info.
