%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(ale_disk_sink).

-behaviour(gen_server).

%% API
-export([start_link/2, start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("ale.hrl").

-record(state, {name      :: atom(),
                path      :: string()}).

-define(DEFAULT_MAX_SIZE, 10 * 1024 * 1024).
-define(DEFAULT_MAX_FILES, 10).

-define(DISK_LOG_DEFAULTS, [{format, external},
                            {type, wrap},
                            {size, {?DEFAULT_MAX_SIZE, ?DEFAULT_MAX_FILES}}]).

-spec start_link(atom(), string()) -> {ok, pid()} | ignore | {error, any()}.
start_link(Name, Path) ->
    start_link(Name, Path, []).

-spec start_link(atom(), string(),
                 [{size, {pos_integer(), pos_integer()} | infinity}]) ->
                        {ok, pid()} | ignore | {error, any()}.
start_link(Name, Path, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, Path, Opts], []).

init([Name, Path, Opts]) ->
    process_flag(trap_exit, true),

    case ale_utils:supported_opts(Opts, [size]) of
        false ->
            {stop, invalid_opts};
        true ->
            DiskLogOptions = disk_log_opts(Name, Path, Opts),

            case disk_log:open(DiskLogOptions) of
                {ok, Name} ->
                    {ok, #state{name=Name, path=Path}};
                Error ->
                    {stop, Error}
            end
    end.

handle_call({log, Msg}, _From, #state{name=Name} = State) ->
    Bytes = unicode:characters_to_binary(Msg),
    RV    = disk_log:blog(Name, Bytes),
    {reply, RV, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{name=Name} = _State) ->
    ok = disk_log:close(Name).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

disk_log_opts(Name, Path, Opts) ->
    UserOpts = ale_utils:interesting_opts(Opts, [size]),
    UserOpts1 = [{name, Name}, {file, Path} | UserOpts],
    %% this prefers user supplied values
    ale_utils:proplists_merge(UserOpts1, ?DISK_LOG_DEFAULTS).
