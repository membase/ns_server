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

-include_lib("ale/include/ale.hrl").
-include("ns_common.hrl").

log_pending() ->
    receive
        done ->
            ok;
        {LogLevel, Fmt, Args} ->
            ?LOG(LogLevel, Fmt, Args),
            log_pending()
    end.

start(_Type, _Args) ->
    setup_static_config(),
    init_logging(),

    %% To initialize logging static config must be setup thus this weird
    %% machinery is required to log messages from setup_static_config().
    self() ! done,
    log_pending(),

    ns_server_cluster_sup:start_link().

get_config_path() ->
    case application:get_env(ns_server, config_path) of
        {ok, V} -> V;
        _ ->
             erlang:error("config_path parameter for ns_server application is missing!")
    end.

setup_static_config() ->
    Terms = case file:consult(get_config_path()) of
                {ok, T} when is_list(T) ->
                    T;
                _ ->
                    erlang:error("failed to read static config: " ++ get_config_path() ++ ". It must be readable file with list of pairs~n")
            end,
    self() ! {info, "Static config terms:~n~p", [Terms]},
    lists:foreach(fun ({K,V}) ->
                          case application:get_env(ns_server, K) of
                              undefined ->
                                  application:set_env(ns_server, K, V);
                              _ ->
                                  self() ! {warn,
                                            "not overriding parameter ~p, which is given from command line",
                                            [K]}
                          end
                  end, Terms).

init_logging() ->
    {ok, Dir} = application:get_env(error_logger_mf_dir),
    {ok, MaxB} = application:get_env(error_logger_mf_maxbytes),
    {ok, MaxF} = application:get_env(error_logger_mf_maxfiles),

    Path = filename:join(Dir, "log"),

    ok = ale:start_logger(?NS_SERVER_LOGGER, info),

    ok = ale:start_sink(disk, ale_disk_sink, [Path, [{size, {MaxB, MaxF}}]]),

    ok = ale:add_sink(?ERROR_LOGGER_LOGGER, disk),
    ok = ale:add_sink(?NS_SERVER_LOGGER, disk),

    case misc:get_env_default(dont_suppress_stderr_logger, false) of
        true ->
            ok = ale:start_sink(stderr, ale_stderr_sink, []),
            ok = ale:add_sink(?NS_SERVER_LOGGER, stderr),
            ok = ale:add_sink(?ERROR_LOGGER_LOGGER, stderr);
        false ->
            ok
    end.

stop(_State) ->
    ok.
