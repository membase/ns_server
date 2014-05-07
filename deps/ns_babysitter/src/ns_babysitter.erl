%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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

-module(ns_babysitter).

-behavior(application).

-export([start/2, stop/1]).

-include("ns_common.hrl").
-include_lib("ale/include/ale.hrl").

start(_, _) ->
    %% we're reading environment of ns_server application. Thus we
    %% need to load it.
    ok = application:load(ns_server),

    setup_static_config(),
    init_logging(),

    %% To initialize logging static config must be setup thus this weird
    %% machinery is required to log messages from setup_static_config().
    self() ! done,
    log_pending(),

    {have_host, true} = {have_host, ('nonode@nohost' =/= node())},

    Cookie =
        case erlang:get_cookie() of
            nocookie ->
                {A1, A2, A3} = erlang:now(),
                random:seed(A1, A2, A3),
                NewCookie = list_to_atom(misc:rand_str(16)),
                erlang:set_cookie(node(), NewCookie),
                NewCookie;
            SomeCookie ->
                SomeCookie
        end,

    ?log_info("babysitter cookie: ~p~n", [Cookie]),
    case application:get_env(cookiefile) of
        {ok, CookieFile} ->
            misc:atomic_write_file(CookieFile, erlang:atom_to_list(Cookie) ++ "\n"),
            ?log_info("Saved babysitter cookie to ~s", [CookieFile]);
        _ ->
            ok
    end,

    ns_babysitter_sup:start_link().

log_pending() ->
    receive
        done ->
            ok;
        {LogLevel, Fmt, Args} ->
            ?LOG(LogLevel, Fmt, Args),
            log_pending()
    end.

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
    {ok, Dir} = application:get_env(ns_server, error_logger_mf_dir),
    {ok, MaxB} = application:get_env(ns_server, error_logger_mf_maxbytes),
    {ok, MaxF} = application:get_env(ns_server, error_logger_mf_maxfiles),

    DiskSinkParams = [{size, {MaxB, MaxF}}],
    LogPath = filename:join(Dir, ?BABYSITTER_LOG_FILENAME),

    ok = ale:start_sink(babysitter_sink,
                        ale_disk_sink, [LogPath, DiskSinkParams]),

    ok = ale:start_logger(?NS_SERVER_LOGGER, debug),
    ok = ale:set_loglevel(?ERROR_LOGGER, debug),

    ok = ale:add_sink(?NS_SERVER_LOGGER, babysitter_sink, debug),
    ok = ale:add_sink(?ERROR_LOGGER, babysitter_sink, debug),

    case misc:get_env_default(ns_server, dont_suppress_stderr_logger, false) of
        true ->
            ale:stop_sink(stderr),
            ok = ale:start_sink(stderr, ale_stderr_sink, []),

            lists:foreach(
              fun (Logger) ->
                      ok = ale:add_sink(Logger, stderr, debug)
              end, [?NS_SERVER_LOGGER, ?ERROR_LOGGER]);
        false ->
            ok
    end,
    ale:info(?NS_SERVER_LOGGER, "Brought up babysitter logging").

stop(_) ->
    ok.
