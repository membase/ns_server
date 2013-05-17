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

-export([start/2, stop/1, get_loglevel/1, restart/0, setup_babysitter_node/0, get_babysitter_node/0]).

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

    {ok, DataDir} = application:get_env(ns_server, path_config_datadir),
    InitArgs = init:get_arguments(),
    InitArgs1 = [{pid, os:getpid()} | InitArgs],
    InitArgs2 = case file:get_cwd() of
                    {ok, CWD} ->
                        [{cwd, CWD} | InitArgs1];
                    _ ->
                        InitArgs1
                end,
    ok = file:write_file(filename:join(DataDir, "initargs"), term_to_binary(InitArgs2)),

    %% To initialize logging static config must be setup thus this weird
    %% machinery is required to log messages from setup_static_config().
    self() ! done,
    log_pending(),

    case misc:get_env_default(ns_server, enable_mlockall, true) of
        true ->
            case mlockall:lock([current, future]) of
                ok ->
                    ?log_info("Locked myself into a memory successfully.");
                Error ->
                    ?log_warning("Could not lock "
                                 "myself into a memory: ~p. Ignoring.", [Error])
            end;
        false ->
            ok
    end,

    ns_server_cluster_sup:start_link().

restart() ->
    %% NOTE: starting and stopping in usual way is surprisingly
    %% hard. Because we normally do that from process which
    %% group_leader is application_master of ns_server application. So
    %% we just terminate and restart all childs instead.
    {ok, {_, ChildSpecs}} = ns_server_cluster_sup:init([]),
    %% we don't restart dist manager in order to avoid shutting
    %% down/restarting net_kernel
    DontRestart = [dist_manager, cb_couch_sup],
    ChildIds = [element(1, Spec) || Spec <- ChildSpecs] -- DontRestart,
    [supervisor:terminate_child(ns_server_cluster_sup, Id) || Id <- lists:reverse(ChildIds)],
    cb_couch_sup:restart_couch(),
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

%% If LogLevel is less restricitve than ThresholdLogLevel (meaning that more
%% message would be printed with that LogLevel) then return ThresholdLogLevel.
%% Otherwise return LogLevel itself.
adjust_loglevel(LogLevel, ThresholdLogLevel) ->
    case ale_utils:loglevel_enabled(LogLevel, ThresholdLogLevel) of
        true ->
            LogLevel;
        false ->
            ThresholdLogLevel
    end.

init_logging() ->
    StdLoggers = [?ERROR_LOGGER],
    AllLoggers = StdLoggers ++ ?LOGGERS,

    {ok, Dir} = application:get_env(error_logger_mf_dir),
    {ok, MaxB} = application:get_env(error_logger_mf_maxbytes),
    {ok, MaxF} = application:get_env(error_logger_mf_maxfiles),

    DefaultLogPath = filename:join(Dir, ?DEFAULT_LOG_FILENAME),
    ErrorLogPath = filename:join(Dir, ?ERRORS_LOG_FILENAME),
    ViewsLogPath = filename:join(Dir, ?VIEWS_LOG_FILENAME),
    MapreduceErrorsLogPath = filename:join(Dir,
                                           ?MAPREDUCE_ERRORS_LOG_FILENAME),
    CouchLogPath = filename:join(Dir, ?COUCHDB_LOG_FILENAME),
    DebugLogPath = filename:join(Dir, ?DEBUG_LOG_FILENAME),
    XdcrLogPath = filename:join(Dir, ?XDCR_LOG_FILENAME),
    XdcrErrorsLogPath = filename:join(Dir, ?XDCR_ERRORS_LOG_FILENAME),
    StatsLogPath = filename:join(Dir, ?STATS_LOG_FILENAME),

    DiskSinkParams = [{size, {MaxB, MaxF}}],

    ale:stop_sink(disk_default),
    ale:stop_sink(disk_error),
    ale:stop_sink(disk_views),
    ale:stop_sink(disk_mapreduce_errors),
    ale:stop_sink(disk_couchdb),
    ale:stop_sink(disk_xdcr),
    ale:stop_sink(disk_xdcr_errors),
    ale:stop_sink(disk_stats),
    ale:stop_sink(ns_log),

    lists:foreach(
      fun (Logger) ->
              ale:stop_logger(Logger)
      end, ?LOGGERS),

    ok = ale:start_sink(disk_default,
                        ale_disk_sink, [DefaultLogPath, DiskSinkParams]),
    ok = ale:start_sink(disk_error,
                        ale_disk_sink, [ErrorLogPath, DiskSinkParams]),
    ok = ale:start_sink(disk_views,
                        ale_disk_sink, [ViewsLogPath, DiskSinkParams]),
    ok = ale:start_sink(disk_mapreduce_errors,
                        ale_disk_sink,
                        [MapreduceErrorsLogPath, DiskSinkParams]),
    ok = ale:start_sink(disk_couchdb,
                        ale_disk_sink, [CouchLogPath, DiskSinkParams]),
    ok = ale:start_sink(disk_debug,
                        ale_disk_sink, [DebugLogPath, DiskSinkParams]),
    ok = ale:start_sink(disk_xdcr,
                        ale_disk_sink, [XdcrLogPath, DiskSinkParams]),
    ok = ale:start_sink(disk_xdcr_errors,
                        ale_disk_sink, [XdcrErrorsLogPath, DiskSinkParams]),
    ok = ale:start_sink(disk_stats,
                        ale_disk_sink, [StatsLogPath, DiskSinkParams]),
    ok = ale:start_sink(ns_log, raw, ns_log_sink, []),

    lists:foreach(
      fun (Logger) ->
              ok = ale:start_logger(Logger, debug)
      end, ?LOGGERS),

    lists:foreach(
      fun (Logger) ->
              ok = ale:set_loglevel(Logger, debug)
      end,
      StdLoggers),

    OverrideLoglevels = [{?STATS_LOGGER, warn},
                         {?NS_DOCTOR_LOGGER, warn}],

    MainFilesLoggers = AllLoggers -- [?XDCR_LOGGER, ?COUCHDB_LOGGER],

    lists:foreach(
      fun (Logger) ->
              LogLevel = proplists:get_value(Logger, OverrideLoglevels,
                                             get_loglevel(Logger)),

              ok = ale:add_sink(Logger, disk_default,
                                adjust_loglevel(LogLevel, info)),

              ok = ale:add_sink(Logger, disk_error,
                                adjust_loglevel(LogLevel, error)),

              %% no need to adjust loglevel for debug log since 'debug' is
              %% already the least restrictive loglevel
              ok = ale:add_sink(Logger, disk_debug, LogLevel)
      end, MainFilesLoggers),

    ok = ale:add_sink(?USER_LOGGER, ns_log, info),
    ok = ale:add_sink(?MENELAUS_LOGGER, ns_log, info),
    ok = ale:add_sink(?CLUSTER_LOGGER, ns_log, info),
    ok = ale:add_sink(?REBALANCE_LOGGER, ns_log, error),

    ok = ale:add_sink(?VIEWS_LOGGER, disk_views),
    ok = ale:add_sink(?MAPREDUCE_ERRORS_LOGGER, disk_mapreduce_errors),

    ok = ale:add_sink(?COUCHDB_LOGGER, disk_couchdb, get_loglevel(?COUCHDB_LOGGER)),
    ok = ale:add_sink(?XDCR_LOGGER, disk_xdcr, get_loglevel(?XDCR_LOGGER)),
    ok = ale:add_sink(?XDCR_LOGGER, disk_xdcr_errors,
                      adjust_loglevel(get_loglevel(?XDCR_LOGGER), error)),

    ok = ale:add_sink(?STATS_LOGGER, disk_stats, get_loglevel(?STATS_LOGGER)),
    ok = ale:add_sink(?NS_DOCTOR_LOGGER, disk_stats, get_loglevel(?NS_DOCTOR_LOGGER)),

    case misc:get_env_default(dont_suppress_stderr_logger, false) of
        true ->
            ale:stop_sink(stderr),
            ok = ale:start_sink(stderr, ale_stderr_sink, []),

            StderrLogLevel = get_loglevel(stderr),

            lists:foreach(
              fun (Logger) ->
                      LogLevel = get_loglevel(Logger),
                      ok = ale:add_sink(Logger, stderr,
                                        adjust_loglevel(LogLevel, StderrLogLevel))
              end, AllLoggers);
        false ->
            ok
    end,
    ale:sync_changes(infinity),
    ale:info(?NS_SERVER_LOGGER, "Started & configured logging").

stop(_State) ->
    ok.

setup_babysitter_node() ->
    {Name, _} = misc:node_name_host(node()),
    Babysitter = list_to_atom("babysitter_of_" ++ Name ++ "@127.0.0.1"),
    application:set_env(ns_server, babysitter_node, Babysitter),
    ignore.

get_babysitter_node() ->
    {ok, Node} = application:get_env(ns_server, babysitter_node),
    CookieString = case os:getenv("NS_SERVER_BABYSITTER_COOKIE") of
                       X when is_list(X) -> X
                   end,
    erlang:set_cookie(Node, list_to_atom(CookieString)),
    Node.
