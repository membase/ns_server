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
-export([start_link/1, update/2, get_status/2,
         get_indexes/1, get_indexes_version/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(REFRESH_INTERVAL,
        ns_config:get_timeout(index_status_keeper_refresh, 5000)).
-define(WORKER, index_status_keeper_worker).
-define(STALE_THRESHOLD,
        ns_config:read_key_fast(index_status_keeper_stale_threshold, 2)).

server_name(Indexer) ->
    list_to_atom(?MODULE_STRING "-" ++ atom_to_list(Indexer:get_type())).

start_link(Indexer) ->
    gen_server:start_link({local, server_name(Indexer)}, ?MODULE, Indexer, []).

update(Indexer, Status) ->
    gen_server:cast(server_name(Indexer), {update, Status}).

get_status(Indexer, Timeout) ->
    gen_server:call(server_name(Indexer), get_status, Timeout).

get_indexes(Indexer) ->
    gen_server:call(server_name(Indexer), get_indexes).

get_indexes_version(Indexer) ->
    gen_server:call(server_name(Indexer), get_indexes_version).

-record(state, {indexer :: atom(),
                num_connections,

                indexes,
                indexes_stale :: true | {false, non_neg_integer()},
                indexes_version,

                restart_pending,
                source :: local | {remote, [node()], non_neg_integer()}}).

init(Indexer) ->
    Self = self(),

    Self ! refresh,

    ns_pubsub:subscribe_link(ns_config_events, fun handle_config_event/2, Self),
    ns_pubsub:subscribe_link(ns_node_disco_events, fun handle_node_disco_event/2, Self),

    State = #state{indexer = Indexer,
                   num_connections = 0,
                   restart_pending = false,
                   source = get_source(Indexer)},

    {ok, set_indexes([], State)}.

handle_call(get_indexes, _From, #state{indexes = Indexes,
                                       indexes_stale = StaleInfo,
                                       indexes_version = Version} = State) ->
    {reply, {ok, Indexes, is_stale(StaleInfo), Version}, State};
handle_call(get_indexes_version, _From,
            #state{indexes_version = Version} = State) ->
    {reply, {ok, Version}, State};
handle_call(get_status, _From,
            #state{num_connections = NumConnections} = State) ->
    Status = [{num_connections, NumConnections}],
    {reply, {ok, Status}, State}.

handle_cast({update, Status}, #state{source = local} = State) ->
    NumConnections = proplists:get_value(index_num_connections, Status, 0),
    NeedsRestart = proplists:get_value(index_needs_restart, Status, false),

    NewState0 = State#state{num_connections = NumConnections},
    NewState = case NeedsRestart of
                   true ->
                       maybe_restart_indexer(NewState0);
                   false ->
                       NewState0
               end,

    {noreply, NewState};
handle_cast({update, _}, State) ->
    ?log_warning("Got unexpected status update when source is not local. Ignoring."),
    {noreply, State};
handle_cast({refresh_done, Result}, State) ->
    NewState =
        case Result of
            {ok, Indexes} ->
                set_indexes(Indexes, State);
            {stale, Indexes} ->
                set_stale(Indexes, State);
            {error, _} ->
                increment_stale(State)
        end,

    erlang:send_after(?REFRESH_INTERVAL, self(), refresh),
    {noreply, NewState};
handle_cast(restart_done, #state{restart_pending = true} = State) ->
    {noreply, State#state{restart_pending = false}};
handle_cast(notable_event, #state{indexer = Indexer} = State) ->
    misc:flush(notable_event),
    {noreply, State#state{source = get_source(Indexer)}}.

handle_info(refresh, State) ->
    refresh_status(State),
    {noreply, State};
handle_info(Msg, State) ->
    ?log_debug("Ignoring unknown msg: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal
maybe_restart_indexer(#state{restart_pending = false} = State) ->
    case ns_config:read_key_fast(dont_restart_indexer, false) of
        true ->
            State;
        false ->
            restart_indexer(State)
    end;
maybe_restart_indexer(State) ->
    State.

restart_indexer(#state{indexer = Indexer,
                       restart_pending = false,
                       source = local} = State) ->
    Self = self(),
    work_queue:submit_work(
      ?WORKER,
      fun () ->
              ?log_info("Restarting the ~p", [Indexer]),

              case Indexer:restart() of
                  {ok, _} ->
                      ?log_info("Restarted the ~p successfully", [Indexer]);
                  Error ->
                      ?log_error("Failed to restart the ~p: ~p", [Indexer, Error])
              end,

              gen_server:cast(Self, restart_done)
      end),

    State#state{restart_pending = true}.

refresh_status(State) ->
    Self = self(),
    work_queue:submit_work(
      ?WORKER,
      fun () ->
              gen_server:cast(Self, {refresh_done, grab_status(State)})
      end).

grab_status(#state{indexer = Indexer,
                   source = local}) ->
    case Indexer:get_local_status() of
        {ok, {[_|_] = Status}} ->
            process_status(Indexer, Status);
        {ok, Other} ->
            ?log_error("Got invalid status from the ~p:~n~p", [Indexer, Other]),
            {error, bad_status};
        Error ->
            Error
    end;
grab_status(#state{indexer = Indexer,
                   source = {remote, Nodes, NodesCount}}) ->
    case Nodes of
        [] ->
            {ok, []};
        _ ->
            Node = lists:nth(random:uniform(NodesCount), Nodes),

            try Indexer:get_remote_indexes(Node) of
                {ok, Indexes, Stale, _Version} ->
                    %% note that we're going to recompute the version instead
                    %% of using the one from the remote node; that's because
                    %% the version should be completely opaque; if we were to
                    %% use it, that would imply that we assume the same
                    %% algorithm for generation of the versions on all the
                    %% nodes
                    case Stale of
                        true ->
                            {stale, Indexes};
                        false ->
                            {ok, Indexes}
                    end;
                Error ->
                    ?log_error("Couldn't get indexes from node ~p: ~p", [Node, Error]),
                    {error, failed}
            catch
                T:E ->
                    ?log_error("Got exception while getting indexes from node ~p: ~p",
                               [Node, {T, E}]),
                    {error, failed}
            end
    end.

process_status(Indexer, Status) ->
    case lists:keyfind(<<"code">>, 1, Status) of
        {_, <<"success">>} ->
            RawIndexes =
                case lists:keyfind(<<"status">>, 1, Status) of
                    false ->
                        [];
                    {_, V} ->
                        V
                end,

            {ok, process_indexes(Indexer, RawIndexes)};
        _ ->
            ?log_error("Indexer returned unsuccessful status:~n~p", [Status]),
            {error, bad_status}
    end.

process_indexes(Indexer, Indexes) ->
    KeysMappingAtomToBin = Indexer:get_status_mapping(),
    lists:map(
      fun ({Index}) ->
              lists:foldl(fun ({Key, BinKey}, Acc) when is_atom(Key) ->
                                  {_, Val} = lists:keyfind(BinKey, 1, Index),
                                  [{Key, Val} | Acc];
                              ({ListOfKeys, BinKey}, Acc) when is_list(ListOfKeys) ->
                                  {_, Val} = lists:keyfind(BinKey, 1, Index),
                                  lists:foldl(fun (Key, Acc1) ->
                                                      [{Key, Val} | Acc1]
                                              end, Acc, ListOfKeys)
                          end, [], KeysMappingAtomToBin)
      end, Indexes).

get_source(Indexer) ->
    Config = ns_config:get(),
    case ns_cluster_membership:should_run_service(Config, Indexer:get_type(),
                                                  ns_node_disco:ns_server_node()) of
        true ->
            local;
        false ->
            IndexNodes = ns_cluster_membership:service_actual_nodes(Config, Indexer:get_type()),
            {remote, IndexNodes, length(IndexNodes)}
    end.

is_notable({{node, _, membership}, _}) ->
    true;
is_notable({nodes_wanted, _}) ->
    true;
is_notable({rest_creds, _}) ->
    true;
is_notable({{service_map, index}, _}) ->
    true;
is_notable(_) ->
    false.

handle_config_event(Event, Pid) ->
    case is_notable(Event) of
        true ->
            gen_server:cast(Pid, notable_event);
        false ->
            ok
    end,
    Pid.

handle_node_disco_event(Event, Pid) ->
    case Event of
        {ns_node_disco_events, _NodesOld, _NodesNew} ->
            gen_server:cast(Pid, notable_event);
        false ->
            ok
    end,
    Pid.

set_indexes(Indexes, #state{indexes_version = OldVersion} = State) ->
    Version = compute_version(Indexes, false),

    case Version =:= OldVersion of
        true ->
            State;
        false ->
            notify_change(State#state{indexes = Indexes,
                                      indexes_stale = {false, 0},
                                      indexes_version = Version})
    end.

set_stale(#state{indexes = Indexes} = State) ->
    Version = compute_version(Indexes, true),
    notify_change(State#state{indexes_stale = true,
                              indexes_version = Version}).

set_stale(Indexes, State) ->
    set_stale(State#state{indexes = Indexes}).

increment_stale(#state{indexes_stale = StaleInfo} = State) ->
    case StaleInfo of
        true ->
            %% we're already stale; no need to do anything
            State;
        {false, StaleCount} ->
            NewStaleCount = StaleCount + 1,

            case NewStaleCount >= ?STALE_THRESHOLD of
                true ->
                    set_stale(State);
                false ->
                    State#state{indexes_stale = {false, NewStaleCount}}
            end
    end.

compute_version(Indexes, IsStale) ->
    erlang:phash2({Indexes, IsStale}).

notify_change(#state{indexer = Indexer,
                     indexes_version = Version} = State) ->
    gen_event:notify(index_events, {indexes_change, Indexer:get_type(), Version}),
    State.

is_stale({false, _}) ->
    false;
is_stale(true) ->
    true.
