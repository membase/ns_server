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
-export([start_link/0, update/1, get/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(REFRESH_INTERVAL,
        ns_config:get_timeout(index_status_keeper_refresh, 5000)).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

update(Status) ->
    gen_server:cast(?MODULE, {update, Status}).

get(Timeout) ->
    gen_server:call(?MODULE, get, Timeout).

-record(state, {num_connections,
                indexes,

                pending_refresh,
                restarter_pid}).

init([]) ->
    process_flag(trap_exit, true),

    self() ! refresh,
    {ok, #state{num_connections = 0,
                indexes = dict:new(),

                pending_refresh = false,
                restarter_pid = undefined}}.


handle_call(get, _From, State) ->
    Indexes = [V || {_, V} <- dict:to_list(State#state.indexes)],

    {reply, [{num_connections, State#state.num_connections},
             {indexes, Indexes}],
     State}.

handle_cast({update, Status}, State) ->
    NumConnections = proplists:get_value(index_num_connections, Status, 0),
    NeedsRestart = proplists:get_value(index_needs_restart, Status, false),

    NewState0 = State#state{num_connections = NumConnections},
    NewState = case NeedsRestart of
                   true ->
                       maybe_restart_indexer(NewState0);
                   false ->
                       NewState0
               end,

    {noreply, NewState}.

handle_info(refresh, State) ->
    {noreply, maybe_refresh(need_refresh(State))};
handle_info({'EXIT', Pid, Reason}, #state{restarter_pid = Pid} = State) ->
    case Reason of
        normal ->
            ?log_info("Restarted the indexer successfully");
        _ ->
            ?log_error("Failed to restart the indexer: ~p", [Reason])
    end,
    {noreply, maybe_refresh(State#state{restarter_pid = undefined})};
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

need_refresh(State) ->
    State#state{pending_refresh = true}.

maybe_refresh(#state{pending_refresh = false} = State) ->
    State;
maybe_refresh(#state{restarter_pid = Pid} = State) when Pid =/= undefined ->
    State;
maybe_refresh(State) ->
    NewState =
        case grab_status() of
            {ok, Status} ->
                State#state{indexes = Status};
            {error, _} ->
                State
        end,

    erlang:send_after(?REFRESH_INTERVAL, self(), refresh),
    NewState#state{pending_refresh = false}.

grab_status() ->
    case index_rest:get_json("getIndexStatus") of
        {ok, {[_|_] = Status}} ->
            process_status(Status);
        {ok, Other} ->
            ?log_error("Got invalid status from the indexer:~n~p", [Other]),
            {error, bad_status};
        Error ->
            Error
    end.

process_status(Status) ->
    case lists:keyfind(<<"code">>, 1, Status) of
        {_, <<"success">>} ->
            RawIndexes =
                case lists:keyfind(<<"status">>, 1, Status) of
                    false ->
                        [];
                    {_, V} ->
                        V
                end,

            {ok, dict:from_list(process_indexes(RawIndexes))};
        _ ->
            ?log_error("Indexer returned unsuccessful status:~n~p", [Status]),
            {error, bad_status}
    end.

process_indexes(Indexes) ->
    lists:map(
      fun ({Index}) ->
              {_, Name} = lists:keyfind(<<"name">>, 1, Index),
              {_, Bucket} = lists:keyfind(<<"bucket">>, 1, Index),
              {_, IndexStatus} = lists:keyfind(<<"status">>, 1, Index),
              {_, Definition} = lists:keyfind(<<"definition">>, 1, Index),
              {_, Completion} = lists:keyfind(<<"completion">>, 1, Index),
              {_, Hosts} = lists:keyfind(<<"hosts">>, 1, Index),

              Props = [{bucket, Bucket},
                       {index, Name},
                       {status, IndexStatus},
                       {definition, Definition},
                       {progress, Completion},
                       {hosts, Hosts}],
              Key = {Bucket, Name},

              {Key, Props}
      end, Indexes).
