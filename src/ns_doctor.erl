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
-module(ns_doctor).

-define(STALE_TIME, 5000000). % 5 seconds in microseconds
-define(LOG_INTERVAL, 60000). % How often to dump current status to the logs

-include("ns_common.hrl").

-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
%% API
-export([get_nodes/0, get_node/1,
         get_tasks_version/0, build_tasks_list/1]).

-record(state, {
          nodes :: dict(),
          tasks_hash_nodes :: undefined | dict(),
          tasks_hash :: undefined | integer(),
          tasks_version :: undefined | string()
         }).

-define(doctor_info(Msg), ale:info(?NS_DOCTOR_LOGGER, Msg)).
-define(doctor_info(Fmt, Args), ale:info(?NS_DOCTOR_LOGGER, Fmt, Args)).

-define(doctor_warning(Msg), ale:warn(?NS_DOCTOR_LOGGER, Msg)).
-define(doctor_warning(Fmt, Args), ale:warn(?NS_DOCTOR_LOGGER, Fmt, Args)).

-define(doctor_error(Msg), ale:error(?NS_DOCTOR_LOGGER, Msg)).
-define(doctor_error(Fmt, Args), ale:error(?NS_DOCTOR_LOGGER, Fmt, Args)).


%% gen_server handlers

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    self() ! acquire_initial_status,
    ns_pubsub:subscribe(ns_config_events, fun handle_config_event/2, undefined),
    case misc:get_env_default(dont_log_stats, false) of
        false ->
            timer:send_interval(?LOG_INTERVAL, log);
        _ -> ok
    end,
    {ok, #state{nodes=dict:new()}}.

-spec handle_rebalance_status_change(NewValue :: term(), State :: term()) -> {term(), boolean()}.
handle_rebalance_status_change(running, _) ->
    {running, true};
handle_rebalance_status_change(_, running) ->
    {not_running, true};
handle_rebalance_status_change(_, State) ->
    {State, false}.

handle_config_event({rebalance_status, NewValue}, State) ->
    {NewState, Changed} = handle_rebalance_status_change(NewValue, State),
    case Changed of
        true ->
            ns_doctor ! rebalance_status_changed;
        _ -> ok
    end,
    NewState;
handle_config_event(_, State) ->
    State.


handle_call(get_tasks_version, _From, State) ->
    NewState = maybe_refresh_tasks_version(State),
    {reply, NewState#state.tasks_version, NewState};

handle_call({get_node, Node}, _From, #state{nodes=Nodes} = State) ->
    Status = dict:fetch(Node, Nodes),
    LiveNodes = [node() | nodes()],
    {reply, annotate_status(Node, Status, now(), LiveNodes), State};

handle_call(get_nodes, _From, #state{nodes=Nodes} = State) ->
    Now = erlang:now(),
    LiveNodes = [node()|nodes()],
    Nodes1 = dict:map(
               fun (Node, Status) ->
                       annotate_status(Node, Status, Now, LiveNodes)
               end, Nodes),
    {reply, Nodes1, State}.


handle_cast({heartbeat, Name, Status}, State) ->
    Nodes = update_status(Name, Status, State#state.nodes),
    NewState0 = State#state{nodes=Nodes},
    NewState = maybe_refresh_tasks_version(NewState0),
    case NewState0#state.tasks_hash =/= NewState#state.tasks_hash of
        true ->
            gen_event:notify(buckets_events, {significant_buckets_change, Name});
        _ ->
            ok
    end,
    {noreply, NewState};

handle_cast(Msg, State) ->
    ?doctor_warning("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info(rebalance_status_changed, State) ->
    %% force hash recomputation next time maybe_refresh_tasks_version is called
    {noreply, State#state{tasks_hash_nodes = undefined}};
handle_info(acquire_initial_status, #state{nodes=NodeDict} = State) ->
    Replies = ns_heart:status_all(),
    %% Get an initial status so we don't start up thinking everything's down
    Nodes = lists:foldl(fun ({Node, Status}, Dict) ->
                                update_status(Node, Status, Dict)
                        end, NodeDict, Replies),
    ?doctor_info("Got initial status ~p~n", [lists:sort(dict:to_list(Nodes))]),
    {noreply, State#state{nodes=Nodes}};

handle_info(log, #state{nodes=NodeDict} = State) ->
    ?doctor_info("Current node statuses:~n~p",
                 [lists:sort(dict:to_list(NodeDict))]),
    {noreply, State};

handle_info(Info, State) ->
    ?doctor_warning("Unexpected message ~p in state",
                    [Info]),
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API

get_nodes() ->
    try gen_server:call(?MODULE, get_nodes) of
        Nodes -> Nodes
    catch
        E:R ->
            ?doctor_error("Error attempting to get nodes: ~p", [{E, R}]),
            dict:new()
    end.

get_node(Node) ->
    try gen_server:call(?MODULE, {get_node, Node}) of
        Status -> Status
    catch
        E:R ->
            ?doctor_error("Error attempting to get node ~p: ~p", [Node, {E, R}]),
            []
    end.

get_tasks_version() ->
    gen_server:call(?MODULE, get_tasks_version).

build_tasks_list(NodeNeededP) ->
    NodesDict = gen_server:call(?MODULE, get_nodes),
    do_build_tasks_list(NodesDict, NodeNeededP).

%% Internal functions

is_significant_buckets_change(OldStatus, NewStatus) ->
    [OldActiveBuckets, OldReadyBuckets,
     NewActiveBuckets, NewReadyBuckets] =
        [lists:sort(proplists:get_value(Field, Status, []))
         || Status <- [OldStatus, NewStatus],
            Field <- [active_buckets, ready_buckets]],
    OldActiveBuckets =/= NewActiveBuckets
        orelse OldReadyBuckets =/= NewReadyBuckets.

update_status(Name, Status0, Dict) ->
    Status = [{last_heard, erlang:now()} | Status0],
    PrevStatus = case dict:find(Name, Dict) of
                     {ok, V} -> V;
                     error -> []
                 end,
    case is_significant_buckets_change(PrevStatus, Status) of
        true ->
            NeedBuckets = lists:sort(ns_bucket:node_bucket_names(Name)),
            OldReady = lists:sort(proplists:get_value(ready_buckets, PrevStatus, [])),
            NewReady = lists:sort(proplists:get_value(ready_buckets, Status, [])),
            case ordsets:intersection(ordsets:subtract(OldReady, NewReady), NeedBuckets) of
                [] ->
                    ok;
                MissingBuckets ->
                    MissingButActive = ordsets:intersection(lists:sort(proplists:get_value(active_buckets, Status, [])),
                                                            MissingBuckets),
                    ?log_error("The following buckets became not ready on node ~p: ~p, those of them are active ~p",
                               [Name, MissingBuckets, MissingButActive])
            end,
            case ordsets:subtract(NewReady, OldReady) of
                [] -> ok;
                NewlyReady ->
                    ?log_info("The following buckets became ready on node ~p: ~p", [Name, NewlyReady])
            end,
            gen_event:notify(buckets_events, {significant_buckets_change, Name});
        _ ->
            ok
    end,
    dict:store(Name, Status, Dict).

annotate_status(Node, Status, Now, LiveNodes) ->
    LastHeard = proplists:get_value(last_heard, Status),
    Stale = case timer:now_diff(Now, LastHeard) of
                T when T > ?STALE_TIME ->
                    [ stale | Status];
                _ -> Status
            end,
    case lists:member(Node, LiveNodes) of
        true ->
            Stale;
        false ->
            [ down | Stale ]
    end.

maybe_refresh_tasks_version(#state{nodes = Nodes,
                                   tasks_hash_nodes = VersionNodes} = State)
  when Nodes =:= VersionNodes ->
    State;
maybe_refresh_tasks_version(State) ->
    Nodes = State#state.nodes,
    TasksHashesSet =
        dict:fold(
          fun (_Node, NodeInfo, Set) ->
                  lists:foldl(
                    fun (Task, Set0) ->
                            case proplists:get_value(type, Task) of
                                indexer ->
                                    sets:add_element(erlang:phash2(
                                                       {lists:keyfind(design_document, 1, Task),
                                                        lists:keyfind(set, 1, Task)}),
                                                     Set0);
                                _ ->
                                    Set0
                            end
                    end, Set, proplists:get_value(local_tasks, NodeInfo, []))
          end, sets:new(), Nodes),
    TasksAndRebalanceHash = erlang:phash2({erlang:phash2(TasksHashesSet),
                                           case ns_cluster_membership:get_rebalance_status() of
                                               {running, _} -> running;
                                               _ -> not_running
                                           end}),
    case TasksAndRebalanceHash =:= State#state.tasks_hash of
        true ->
            %% hash did not change, only nodes. Cool
            State#state{tasks_hash_nodes = Nodes};
        _ ->
            %% hash changed. Generate new version
            State#state{tasks_hash_nodes = Nodes,
                        tasks_hash = TasksAndRebalanceHash,
                        tasks_version = integer_to_list(TasksAndRebalanceHash)}
    end.

task_operation(extract, indexer, RawTask) ->
    {_, ChangesDone} = lists:keyfind(changes_done, 1, RawTask),
    {_, TotalChanges} = lists:keyfind(total_changes, 1, RawTask),
    {_, BucketName} = lists:keyfind(set, 1, RawTask),
    {_, DDocId} = lists:keyfind(design_document, 1, RawTask),
    {{indexer, BucketName, DDocId}, {ChangesDone, TotalChanges}};
task_operation(extract, _, _) ->
    ignore;

task_operation(finalize, {indexer, BucketName, DDocId}, {ChangesDone, TotalChanges}) ->
    Progress = erlang:min((ChangesDone * 100) div TotalChanges, 100),
    [{type, indexer},
     {recommendedRefreshPeriod, 2.0},
     {status, running},
     {bucket, BucketName},
     {designDocument, DDocId},
     {changesDone, ChangesDone},
     {totalChanges, TotalChanges},
     {progress, Progress}].

task_operation(fold, {indexer, _, _},
               {ChangesDone1, TotalChanges1},
               {ChangesDone2, TotalChanges2}) ->
    {ChangesDone1 + ChangesDone2, TotalChanges1 + TotalChanges2}.


do_build_tasks_list(NodesDict, NeedNodeP) ->
    TasksDict =
        dict:fold(
          fun (Node, NodeInfo, TasksDict) ->
                  case NeedNodeP(Node) of
                      true ->
                          NodeTasks = proplists:get_value(local_tasks, NodeInfo, []),
                          lists:foldl(
                            fun (RawTask, TasksDict0) ->
                                    case task_operation(extract, proplists:get_value(type, RawTask), RawTask) of
                                        ignore -> TasksDict0;
                                        {Signature, Value} ->
                                            NewValue =
                                                case dict:find(Signature, TasksDict0) of
                                                    {ok, ValueOld} ->
                                                        task_operation(fold, Signature, ValueOld, Value);
                                                    error ->
                                                        Value
                                                end,
                                            dict:store(Signature, NewValue, TasksDict0)
                                    end
                            end, TasksDict, NodeTasks);
                      false ->
                          TasksDict
                  end
          end,
          dict:new(),
          NodesDict),
    PreRebalanceTasks = dict:fold(fun (Signature, Value, Acc) ->
                                          [{struct, task_operation(finalize, Signature, Value)} | Acc]
                                  end, [], TasksDict),
    RebalanceTask0 =
        case ns_cluster_membership:get_rebalance_status() of
            {running, PerNode} ->
                [{type, rebalance},
                 {recommendedRefreshPeriod, 0.25},
                 {status, running},
                 {progress, case lists:foldl(fun ({_, Progress}, {Total, Count}) ->
                                                     {Total + Progress, Count + 1}
                                             end, {0, 0}, PerNode) of
                                {_, 0} -> 0;
                                {TotalRebalanceProgress, RebalanceNodesCount} ->
                                    TotalRebalanceProgress * 100.0 / RebalanceNodesCount
                            end},
                 {perNode,
                  {struct, [{Node, {struct, [{progress, Progress * 100}]}}
                            || {Node, Progress} <- PerNode]}}];
            _ ->
                [{type, rebalance},
                 {status, notRunning}
                 | case ns_config:search(rebalance_status) of
                       {value, {none, ErrorMessage}} ->
                           [{errorMessage, iolist_to_binary(ErrorMessage)}];
                       _ -> []
                   end]
        end,
    RebalanceTask = {struct, RebalanceTask0},
    [RebalanceTask | PreRebalanceTasks].
