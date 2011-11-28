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

-export([start/2, stop/1, get_loglevel/1, restart/0]).

-include("ns_common.hrl").
-include_lib("ale/include/ale.hrl").

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

restart() ->
    %% NOTE: starting and stopping in usual way is surprisingly
    %% hard. Because we normally do that from process which
    %% group_leader is application_master of ns_server application. So
    %% we just terminate and restart all childs instead.
    {ok, {_, ChildSpecs}} = ns_server_cluster_sup:init([]),
    ChildIds = [element(1, Spec) || Spec <- ChildSpecs],
    [supervisor:terminate_child(ns_server_cluster_sup, Id) || Id <- lists:reverse(ChildIds)],
    [supervisor:restart_child(ns_server_cluster_sup, Id) || Id <- ChildIds].

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

get_loglevel(LoggerName) ->
    {ok, DefaultLogLevel} = application:get_env(loglevel_default),
    LoggerNameStr = atom_to_list(LoggerName),
    Key = list_to_atom("loglevel_" ++ LoggerNameStr),
    misc:get_env_default(Key, DefaultLogLevel).

init_logging() ->
    StdLoggers = [?ERROR_LOGGER_LOGGER],
    AllLoggers = StdLoggers ++ ?LOGGERS,

    {ok, Dir} = application:get_env(error_logger_mf_dir),
    {ok, MaxB} = application:get_env(error_logger_mf_maxbytes),
    {ok, MaxF} = application:get_env(error_logger_mf_maxfiles),

    DefaultLogPath = filename:join(Dir, ?DEFAULT_LOG_FILENAME),
    ErrorLogPath = filename:join(Dir, ?ERRORS_LOG_FILENAME),

    DiskSinkParams = [{size, {MaxB, MaxF}}],

    ale:stop_sink(disk_default),
    ale:stop_sink(disk_error),
    ale:stop_sink(ns_log),

    lists:foreach(
      fun (Logger) ->
              ale:stop_logger(Logger)
      end, ?LOGGERS),

    ok = ale:start_sink(disk_default,
                        ale_disk_sink, [DefaultLogPath, DiskSinkParams]),
    ok = ale:start_sink(disk_error,
                        ale_disk_sink, [ErrorLogPath, DiskSinkParams]),
    ok = ale:start_sink(ns_log, ns_log_sink, []),

    lists:foreach(
      fun (Logger) ->
              LogLevel = get_loglevel(Logger),
              ok = ale:start_logger(Logger, LogLevel)
      end, ?LOGGERS),

    lists:foreach(
      fun (Logger) ->
              LogLevel = get_loglevel(Logger),
              ok = ale:set_loglevel(Logger, LogLevel)
      end,
      StdLoggers),

    lists:foreach(
      fun (Logger) ->
              ok = ale:add_sink(Logger, disk_default),
              ok = ale:add_sink(Logger, disk_error, error)
      end, AllLoggers),

    ok = ale:add_sink(?USER_LOGGER, ns_log),
    ok = ale:add_sink(?MENELAUS_LOGGER, ns_log),
    ok = ale:add_sink(?CLUSTER_LOGGER, ns_log, info),

    case misc:get_env_default(dont_suppress_stderr_logger, false) of
        true ->
            ale:stop_sink(stderr),
            ok = ale:start_sink(stderr, ale_stderr_sink, []),

            lists:foreach(
              fun (Logger) ->
                      ok = ale:add_sink(Logger, stderr)
              end, AllLoggers);
        false ->
            ok
    end.

stop(_State) ->
    ok.
