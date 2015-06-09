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
-export([start_link/0, update/1, get_status/1, get_indexes/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(REFRESH_INTERVAL,
        ns_config:get_timeout(index_status_keeper_refresh, 5000)).
-define(WORKER, index_status_keeper_worker).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

update(Status) ->
    gen_server:cast(?MODULE, {update, Status}).

get_status(Timeout) ->
    gen_server:call(?MODULE, get_status, Timeout).

get_indexes() ->
    gen_server:call(?MODULE, get_indexes).

-record(state, {num_connections,
                indexes,

                restart_pending,
                source :: local | {remote, [node()], non_neg_integer()}}).

init([]) ->
    Self = self(),

    Self ! refresh,

    ns_pubsub:subscribe_link(ns_config_events, fun handle_config_event/2, Self),
    ns_pubsub:subscribe_link(ns_node_disco_events, fun handle_node_disco_event/2, Self),

    {ok, #state{num_connections = 0,
                indexes = [],
                restart_pending = false,
                source = get_source()}}.

handle_call(get_indexes, _From, #state{indexes = Indexes} = State) ->
    {reply, {ok, Indexes}, State};
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
handle_cast({refresh_done, Status}, State) ->
    NewState =
        case Status of
            failed ->
                State;
            _ ->
                State#state{indexes = Status}
        end,

    erlang:send_after(?REFRESH_INTERVAL, self(), refresh),
    {noreply, NewState};
handle_cast(restart_done, #state{restart_pending = true} = State) ->
    {noreply, State#state{restart_pending = false}};
handle_cast(notable_event, State) ->
    misc:flush(notable_event),
    {noreply, State#state{source = get_source()}}.

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

restart_indexer(#state{restart_pending = false,
                       source = local} = State) ->
    Self = self(),
    work_queue:submit_work(
      ?WORKER,
      fun () ->
              ?log_info("Restarting the indexer"),

              case ns_ports_setup:restart_port_by_name(indexer) of
                  {ok, _} ->
                      ?log_info("Restarted the indexer successfully");
                  Error ->
                      ?log_error("Failed to restart the indexer: ~p", [Error])
              end,

              gen_server:cast(Self, restart_done)
      end),

    State#state{restart_pending = true}.

refresh_status(State) ->
    Self = self(),
    work_queue:submit_work(
      ?WORKER,
      fun () ->
              Status = case grab_status(State) of
                           {ok, S} ->
                               S;
                           {error, _} ->
                               failed
                       end,
              gen_server:cast(Self, {refresh_done, Status})
      end).

grab_status(#state{source = local}) ->
    case index_rest:get_json("getIndexStatus") of
        {ok, {[_|_] = Status}} ->
            process_status(Status);
        {ok, Other} ->
            ?log_error("Got invalid status from the indexer:~n~p", [Other]),
            {error, bad_status};
        Error ->
            Error
    end;
grab_status(#state{source = {remote, Nodes, NodesCount}}) ->
    case Nodes of
        [] ->
            {ok, []};
        _ ->
            Node = lists:nth(random:uniform(NodesCount), Nodes),

            try remote_api:get_indexes(Node) of
                {ok, _} = R ->
                    R;
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

            {ok, process_indexes(RawIndexes)};
        _ ->
            ?log_error("Indexer returned unsuccessful status:~n~p", [Status]),
            {error, bad_status}
    end.

process_indexes(Indexes) ->
    lists:map(
      fun ({Index}) ->
              {_, Id} = lists:keyfind(<<"defnId">>, 1, Index),
              {_, Name} = lists:keyfind(<<"name">>, 1, Index),
              {_, Bucket} = lists:keyfind(<<"bucket">>, 1, Index),
              {_, IndexStatus} = lists:keyfind(<<"status">>, 1, Index),
              {_, Definition} = lists:keyfind(<<"definition">>, 1, Index),
              {_, Completion} = lists:keyfind(<<"completion">>, 1, Index),
              {_, Hosts} = lists:keyfind(<<"hosts">>, 1, Index),

              [{id, Id},
               {bucket, Bucket},
               {index, Name},
               {status, IndexStatus},
               {definition, Definition},
               {progress, Completion},
               {hosts, Hosts}]
      end, Indexes).

get_source() ->
    Config = ns_config:get(),
    case ns_cluster_membership:should_run_service(Config, index, ns_node_disco:ns_server_node()) of
        true ->
            local;
        false ->
            IndexNodes = ns_cluster_membership:index_active_nodes(Config, actual),
            {remote, IndexNodes, length(IndexNodes)}
    end.

is_notable({{node, _, membership}, _}) ->
    true;
is_notable({nodes_wanted, _}) ->
    true;
is_notable({rest_creds, _}) ->
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
