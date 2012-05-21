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
%%
%% @doc This server syncs part of (replicated) ns_config to local
%% couch config.  Actual sync is performed by worker process that's
%% direct son of supervisor. ns_config changes are noted by gen_server
%% process that's son of worker process. And it's using ns_pubsub to
%% tap into ns_config changes.
%%
%% Such seemingly unusual design (with worker being parent of main
%% process) is to ensure that supervisor shutdown synchronizes with
%% worker death (which mutates world state). Main process does not
%% mutate world's state, so worker can exit without waiting for main
%% process death (it'll die soon but we don't care when).

-module(cb_config_couch_sync).

-behaviour(gen_server).

-export([start_link/0, set_db_and_ix_paths/2, get_db_and_ix_paths/0]).

%% gen_event callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-include("ns_common.hrl").

-record(state,
        {
          have_notable_change :: boolean(),
          sync_started :: boolean(),
          worker_pid :: pid()
        }).

start_link() ->
    proc_lib:start_link(erlang, apply, [fun start_worker_loop/0, []]).

start_worker_loop() ->
    erlang:process_flag(trap_exit, true),
    {ok, _} = gen_server:start_link({local, ?MODULE}, ?MODULE, [self()], []),
    do_config_sync(),
    proc_lib:init_ack({ok, self()}),
    worker_loop().

worker_loop() ->
    receive
        {'EXIT', _From, Reason} ->
            exit(Reason);
        {sync_config, Pid} ->
            do_config_sync(),
            Pid ! sync_done;
        X ->
            ?log_error("couch sync worker got unknown message: ~p~n", [X]),
            exit({unknown_message, X})
    end,
    worker_loop().

init([WorkerPid]) ->
    ns_pubsub:subscribe_link(ns_config_events, fun handle_config_event/2, []),
    {ok, maybe_start_sync(#state{have_notable_change = true,
                                 sync_started = false,
                                 worker_pid = WorkerPid})}.


-spec get_db_and_ix_paths() -> [{db_path | index_path, string()}].
get_db_and_ix_paths() ->
    DbPath = couch_config:get("couchdb", "database_dir"),
    IxPath = couch_config:get("couchdb", "view_index_dir", DbPath),
    [{db_path, DbPath},
     {index_path, IxPath}].

-spec set_db_and_ix_paths(DbPath :: string(), IxPath :: string()) -> ok.
set_db_and_ix_paths(DbPath, IxPath) ->
    couch_config:set("couchdb", "database_dir", DbPath),
    couch_config:set("couchdb", "view_index_dir", IxPath).

terminate(_Reason, _State) ->
    ok.
code_change(_OldVsn, State, _) ->
    {ok, State}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(notable_config_change, State) ->
    {noreply, maybe_start_sync(State#state{have_notable_change = true})};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(sync_done, State) ->
    {noreply, maybe_start_sync(State#state{sync_started = false})};
handle_info(_Event, State) ->
    {noreply, State}.

%% Auxiliary functions.

is_notable_event({buckets, _}) -> true;
is_notable_event({max_parallel_indexers, _}) -> true;
is_notable_event(_) -> false.

handle_config_event(KVPair, State) ->
    case is_notable_event(KVPair) of
        true -> gen_server:cast(?MODULE, notable_config_change);
        _ -> ok
    end,
    State.

maybe_start_sync(#state{have_notable_change = false} = State) ->
    State;
maybe_start_sync(#state{sync_started = true} = State) ->
    State;
maybe_start_sync(#state{worker_pid = Pid} = State) ->
    Pid ! {sync_config, self()},
    State#state{have_notable_change = false,
                sync_started = true}.

do_config_sync() ->
    Config = ns_config:get(),
    case ns_config:search_node(node(), Config, max_parallel_indexers) of
        false -> ok;
        {value, MaxParallelIndexers} ->
            couch_config:set("couchdb", "max_parallel_indexers", integer_to_list(MaxParallelIndexers), false)
    end.
