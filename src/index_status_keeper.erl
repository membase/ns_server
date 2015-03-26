%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
-module(index_status_keeper).

-include("ns_common.hrl").

-behavior(gen_server).

%% API
-export([start_link/0, update/3, get/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

update(NumConnections, NeedsRestart, Indexes) ->
    gen_server:cast(?MODULE, {update, NumConnections, NeedsRestart, Indexes}).

get(Timeout) ->
    gen_server:call(?MODULE, get, Timeout).

-record(state, {num_connections,
                indexes,

                restarter_pid}).

init([]) ->
    process_flag(trap_exit, true),

    {ok, #state{num_connections = 0,
                indexes = [],

                restarter_pid = undefined}}.


handle_call(get, _From, State) ->
    {reply, [{num_connections, State#state.num_connections},
             {indexes, State#state.indexes}],
     State}.

handle_cast({update, NumConnections, NeedsRestart, Indexes}, State) ->
    NewState0 = State#state{num_connections = NumConnections,
                            indexes = Indexes},
    NewState = case NeedsRestart of
                   true ->
                       maybe_restart_indexer(NewState0);
                   false ->
                       NewState0
               end,

    {noreply, NewState}.

handle_info({'EXIT', Pid, Reason}, #state{restarter_pid = Pid} = State) ->
    case Reason of
        normal ->
            ?log_info("Restarted the indexer successfully");
        _ ->
            ?log_error("Failed to restart the indexer: ~p", [Reason])
    end,
    {noreply, State#state{restarter_pid = undefined}};
handle_info(Msg, State) ->
    ?log_debug("Ignoring unknown msg: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, #state{restarter_pid = MaybePid}) ->
    case MaybePid of
        undefined ->
            ok;
        _ ->
            misc:wait_for_process(MaybePid, infinity)
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal
maybe_restart_indexer(#state{restarter_pid = undefined} = State) ->
    case ns_config:read_key_fast(dont_restart_indexer, false) of
        true ->
            State;
        false ->
            restart_indexer(State)
    end;
maybe_restart_indexer(State) ->
    State.

restart_indexer(#state{restarter_pid = undefined} = State) ->
    ?log_info("Restarting the indexer"),

    Pid = proc_lib:spawn_link(
            fun () ->
                    {ok, _} = ns_ports_setup:restart_port_by_name(indexer)
            end),

    State#state{restarter_pid = Pid}.
