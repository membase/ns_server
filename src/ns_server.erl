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

-export([start/2, stop/1, get_loglevel/1, restart/0, setup_node_names/0, get_babysitter_node/0,
         get_babysitter_cookie/0,
         start_disk_sink/2]).

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
    setup_env(),
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
    InitArgs3 =
        lists:foldl(
          fun ({App, _, _}, Acc) ->
                  Env = lists:append([[misc:inspect_term(K),
                                       misc:inspect_term(V)] ||
                                         {K, V} <- application:get_all_env(App)]),
                  dict:append_list(App, Env, Acc)
          end, dict:from_list(InitArgs2), application:loaded_applications()),
    ok = misc:write_file(filename:join(DataDir, "initargs"),
                         term_to_binary(dict:to_list(InitArgs3))),

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

setup_env() ->
    case os:getenv("CHILD_ERLANG_ENV_ARGS") of
        false ->
            ok;
        EnvArgsStr ->
            {ok, EnvArgs} = couch_util:parse_term(EnvArgsStr),
            lists:foreach(
              fun ({App, Values}) ->
                      lists:foreach(
                        fun ({K, V}) ->
                                application:set_env(App, K, V)
                        end, Values)
              end, EnvArgs)
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
    StdLoggers = [?ALE_LOGGER, ?ERROR_LOGGER],
    AllLoggers = StdLoggers ++ ?LOGGERS,

    lists:foreach(
      fun (Logger) ->
              ale:stop_logger(Logger)
      end, ?LOGGERS ++ [?ACCESS_LOGGER]),

    ok = start_disk_sink(disk_default, ?DEFAULT_LOG_FILENAME),
    ok = start_disk_sink(disk_error, ?ERRORS_LOG_FILENAME),
    ok = start_disk_sink(disk_views, ?VIEWS_LOG_FILENAME),
    ok = start_disk_sink(disk_mapreduce_errors, ?MAPREDUCE_ERRORS_LOG_FILENAME),
    ok = start_disk_sink(disk_couchdb, ?COUCHDB_LOG_FILENAME),
    ok = start_disk_sink(disk_debug, ?DEBUG_LOG_FILENAME),
    ok = start_disk_sink(disk_xdcr, ?XDCR_LOG_FILENAME),
    ok = start_disk_sink(disk_xdcr_errors, ?XDCR_ERRORS_LOG_FILENAME),
    ok = start_disk_sink(disk_stats, ?STATS_LOG_FILENAME),
    ok = start_disk_sink(disk_reports, ?REPORTS_LOG_FILENAME),
    ok = start_disk_sink(xdcr_trace, ?XDCR_TRACE_LOG_FILENAME),
    ok = start_disk_sink(disk_access, ?ACCESS_LOG_FILENAME),

    ok = start_sink(ns_log, ns_log_sink, []),

    lists:foreach(
      fun (Logger) ->
              ok = ale:start_logger(Logger, debug)
      end, ?LOGGERS -- [?XDCR_TRACE_LOGGER]),

    lists:foreach(
      fun (Logger) ->
              ok = ale:set_loglevel(Logger, debug)
      end,
      StdLoggers),

    ok = ale:start_logger(?XDCR_TRACE_LOGGER, get_loglevel(?XDCR_TRACE_LOGGER),
                          xdcr_trace_log_formatter),

    ok = ale:start_logger(?ACCESS_LOGGER, info, menelaus_access_log_formatter),

    OverrideLoglevels = [{?STATS_LOGGER, warn},
                         {?NS_DOCTOR_LOGGER, warn}],

    MainFilesLoggers = AllLoggers -- [?XDCR_LOGGER, ?COUCHDB_LOGGER,
                                      ?ERROR_LOGGER, ?XDCR_TRACE_LOGGER,
                                      ?MAPREDUCE_ERRORS_LOGGER],

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

    ok = ale:add_sink(?ERROR_LOGGER, disk_debug, get_loglevel(?ERROR_LOGGER)),
    ok = ale:add_sink(?ERROR_LOGGER, disk_reports, get_loglevel(?ERROR_LOGGER)),

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

    ok = ale:add_sink(?XDCR_TRACE_LOGGER, xdcr_trace, debug),

    ok = ale:add_sink(?ACCESS_LOGGER, disk_access, get_loglevel(?ACCESS_LOGGER)),

    case misc:get_env_default(dont_suppress_stderr_logger, false) of
        true ->
            ok = start_sink(stderr, ale_stderr_sink, []),
            StderrLogLevel = get_loglevel(stderr),

            lists:foreach(
              fun (Logger) ->
                      LogLevel = get_loglevel(Logger),
                      ok = ale:add_sink(Logger, stderr,
                                        adjust_loglevel(LogLevel, StderrLogLevel))
              end, AllLoggers ++ [?ACCESS_LOGGER] -- [?XDCR_TRACE_LOGGER]);
        false ->
            ok
    end,
    ale:info(?NS_SERVER_LOGGER, "Started & configured logging").

start_sink(Name, Module, Args) ->
    ale:stop_sink(Name),
    ale:start_sink(Name, Module, Args).

start_disk_sink(Name, FileName) ->
    {ok, Dir} = application:get_env(error_logger_mf_dir),
    PerSinkOpts = misc:get_env_default(list_to_atom("disk_sink_opts_" ++ atom_to_list(Name)), []),
    DiskSinkOpts = PerSinkOpts ++ misc:get_env_default(disk_sink_opts, []),

    Path = filename:join(Dir, FileName),
    start_sink(Name, ale_disk_sink, [Path, DiskSinkOpts]).

stop(_State) ->
    ok.

setup_node_names() ->
    Name =  misc:node_name_short(),
    Babysitter = list_to_atom("babysitter_of_" ++ Name ++ "@127.0.0.1"),
    Couchdb = list_to_atom("couchdb_" ++ Name ++ "@127.0.0.1"),
    application:set_env(ns_server, ns_couchdb_node, Couchdb),
    application:set_env(ns_server, babysitter_node, Babysitter),
    erlang:set_cookie(Couchdb, get_babysitter_cookie()),
    ignore.

get_babysitter_cookie() ->
    case os:getenv("NS_SERVER_BABYSITTER_COOKIE") of
        X when is_list(X) -> list_to_atom(X)
    end.

get_babysitter_node() ->
    {ok, Node} = application:get_env(ns_server, babysitter_node),
    erlang:set_cookie(Node, get_babysitter_cookie()),
    Node.
