% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_memcached_port).

-behaviour(gen_server).

-record(state, {port}).

-define(SERVER, {local, ?MODULE}).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

%% API
start_link() ->
    gen_server:start_link(?SERVER, ?MODULE, [], []).


%% gen_server callbacks
init([]) ->
    Config = ns_config:get(),
    MCPort = ns_config:search_prop(Config, memcached, port),
    ISaslPath = ns_config:search_prop(Config, isasl, path),
    AdminUser = ns_config:search_prop(Config, memcached, admin_user),
    Command = "./bin/memcached/memcached", % TODO get this from the config
    PluginPath = "./bin",
    EnginePath = "./bin",
    Args = ["-p", integer_to_list(MCPort),
            "-X", filename:join(PluginPath, "/memcached/stdin_term_handler.so"),
            "-E", filename:join(EnginePath, "/bucket_engine/bucket_engine.so"),
            "-r", % Needed so we'll dump core
            "-e", lists:flatten(
                    io_lib:format(
                      "admin=~s;engine=~s;default_bucket_name=default;auto_create=false",
                      [AdminUser, filename:join(EnginePath, "/ep-engine/ep.so")]))],
    Opts = [{args, Args},
            {env, [{"MEMCACHED_TOP_KEYS", "100"},
                   {"ISASL_PWFILE", ISaslPath},
                   {"ISASL_DB_CHECK_TIME", "1"}]},
            use_stdio,
            stderr_to_stdout,
            stream,
            exit_status],
    Port = open_port({spawn_executable, Command}, Opts),
    {ok, #state{port=Port}}.


handle_call(Request, _From, State) ->
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({_Port, {data, Msg}}, State) ->
    error_logger:info_msg("Message from memcached:~n~s~n",
                          [Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
