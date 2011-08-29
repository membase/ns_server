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

-export([start/2, stop/1]).

-include("ns_common.hrl").

start(_Type, _Args) ->
    setup_static_config(),
    ns_server_cluster_sup:start_link().

get_config_path() ->
    case application:get_env(ns_server, config_path) of
        {ok, V} -> V;
        _ -> ?log_error("config_path parameter for ns_server application is missing!"),
             erlang:error("config_path parameter for ns_server application is missing!")
    end.

setup_static_config() ->
    Terms = case file:consult(get_config_path()) of
                {ok, T} when is_list(T) ->
                    T;
                _ ->
                    erlang:error("failed to read static config: " ++ get_config_path() ++ ". It must be readable file with list of pairs~n")
            end,
    ?log_info("Static config terms:~n~p", [Terms]),
    lists:foreach(fun ({K,V}) ->
                          case application:get_env(ns_server, K) of
                              undefined ->
                                  application:set_env(ns_server, K, V);
                              _ ->
                                  ?log_warning("not overriding parameter ~p, which is given from command line", [K])
                          end
                  end, Terms).

stop(_State) ->
    ok.
