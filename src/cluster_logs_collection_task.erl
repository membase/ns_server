%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
-module(cluster_logs_collection_task).

-include("ns_common.hrl").

-export([start_link/2, start_link_ets_holder/0]).

-export([maybe_build_cluster_logs_task/0]).

-export([preflight_base_url/1]).

%% called remotely
-export([start_collection_per_node/3,
         start_upload_per_node/4]).

start_link(Nodes, BaseURL) ->
    proc_lib:start_link(erlang, apply, [fun collect_cluster_logs/2, [Nodes, BaseURL]]).

start_link_ets_holder() ->
    misc:start_event_link(
      fun () ->
              _ = ets:new(cluster_logs_collection_task_status, [named_table, public])
      end).


maybe_build_cluster_logs_task() ->
    Tasks = try ets:tab2list(cluster_logs_collection_task_status)
            catch T:E ->
                    ?log_debug("Ignoring exception trying to read cluster_logs_collection_task_status table: ~p:~p", [T,E]),
                    []
            end,

    case lists:keyfind(cluster, 1, Tasks) of
        false ->
            [];
        {cluster, Nodes, BaseURL, Timestamp, PidOrCompleted} ->
            [build_cluster_logs_task_tail(Tasks, Nodes, BaseURL, Timestamp, PidOrCompleted)]
    end.

build_cluster_logs_task_tail(Tasks, Nodes, BaseURL, Timestamp, PidOrCompleted) ->
    Status = case PidOrCompleted of
                 completed ->
                     completed;
                 _ ->
                     case is_process_alive(PidOrCompleted) of
                         true ->
                             running;
                         _ ->
                             cancelled
                     end
             end,

    NodeStatuses = [{N, build_node_task_status(Tasks, BaseURL, N)} || N <- Nodes],
    [{type, cluster_logs_collect},
     {status, Status},
     {timestamp, Timestamp},
     {perNode, NodeStatuses}].

build_node_task_status(Tasks, BaseURL, Node) ->
    case lists:keyfind({Node, collection}, 1, Tasks) of
        false ->
            [{status, starting}];
        {_, started, Path} ->
            [{status, started},
             {path, Path}];
        {_, died, _Reason} ->
            [{status, failed}];
        {_, {ok, Path, _Output}} ->
            case BaseURL =:= false of
                true ->
                    [{status, collected},
                     {path, Path}];
                _ ->
                    [{path, Path} | build_node_upload_task_status(Tasks, Node)]
            end;
        {_, {error, Status, _Output}} ->
            [{status, failed},
             {statusCode, Status}]
    end.

build_node_upload_task_status(Tasks, Node) ->
    case lists:keyfind({Node, upload}, 1, Tasks) of
        false ->
            [{status, startingUpload}];
        {_, started, URL} ->
            [{status, startedUpload},
             {url, URL}];
        {_, died, _Reason} ->
            [{status, failedUpload}];
        {_, {ok, URL}} ->
            [{status, uploaded},
             {url, URL}];
        {_, {error, URL, Status, Output}} ->
            [{status, failedUpload},
             {url, URL},
             {uploadStatusCode, Status},
             {uploadOutput, Output}]
    end.

format_timestamp({{Year,Month,Day},{Hour,Min,Sec}}) ->
    lists:flatten(
      io_lib:format("~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B~2.10.0B~2.10.0B",
                    [Year, Month, Day, Hour, Min, Sec])).

collect_cluster_logs(Nodes, BaseURL) ->
    Timestamp = erlang:universaltime(),
    TimestampS = format_timestamp(Timestamp),
    ets:delete_all_objects(cluster_logs_collection_task_status),
    update_ets_status({cluster, Nodes, BaseURL, Timestamp, self()}),

    CollectConcurrency = ns_config:read_key_fast(cluster_logs_collection_concurrency, 1024),
    {ok, CollectThrottle} = concurrency_throttle:start_link({CollectConcurrency, log_collection}, undefined),
    UploadConcurrency = ns_config:read_key_fast(cluster_logs_upload_concurrency, 1),
    {ok, UploadThrottle} = concurrency_throttle:start_link({UploadConcurrency, log_upload}, undefined),

    update_ets_status({collect_throttle, CollectThrottle}),
    update_ets_status({upload_throttle, UploadThrottle}),

    proc_lib:init_ack({ok, self()}),

    ns_heart:force_beat(),

    JustOneNode = case Nodes of
                      [_] -> true;
                      _ -> false
                  end,

    MaybeNoSingleNode = case (JustOneNode orelse
                              ns_config:read_key_fast(cluster_logs_no_single_node_diag, false)) of
                            true ->
                                [no_single_node_diag];
                            _ ->
                                []
                        end,

    Options = MaybeNoSingleNode,

    misc:parallel_map(
      fun (N) ->
              run_node_collection(N, BaseURL, TimestampS, Options)
      end, Nodes, infinity),

    update_ets_status({cluster, Nodes, BaseURL, Timestamp, completed}).


run_node_collection(Node, BaseURL, TimestampS, Options) ->
    misc:executing_on_new_process(
      fun () ->
              erlang:process_flag(trap_exit, true),
              do_run_node_collection(Node, BaseURL, TimestampS, Options)
      end).

update_ets_status(Tuple) ->
    ets:insert(cluster_logs_collection_task_status, Tuple).

lookup_throttle(ThrottleName) ->
    [{_, Pid}] = ets:lookup(cluster_logs_collection_task_status, ThrottleName),
    Pid.

get_token(ThrottleName) ->
    Pid = lookup_throttle(ThrottleName),
    concurrency_throttle:send_back_when_can_go(Pid, go),
    receive
        {'EXIT', _, Reason} = ExitMsg ->
            ?log_debug("Got exit waiting for token: ~p", [ExitMsg]),
            erlang:exit(Reason);
        go ->
            ok
    end.

put_token(ThrottleName) ->
    concurrency_throttle:is_done(lookup_throttle(ThrottleName)).

start_subtask(Node, Subtask, M, F, A) ->
    Pid = proc_lib:spawn_link(Node, M, F, A),
    receive
        {ack, Pid, Return} ->
            Return;
        {'EXIT', Pid, Reason} ->
            update_ets_status({{Node, Subtask}, died, Reason}),
            erlang:exit(Reason);
        {'EXIT', _Other, Reason} = Msg ->
            ?log_info("Got exit ~p while waiting for collectinfo slave on node ~p", [Msg, Node]),
            erlang:exit(Reason)
    end.

wait_child(P, Node, Subtask) ->
    ?log_debug("Got child to wait: ~p, node: ~p, task: ~p", [P, Node, Subtask]),
    receive
        {'EXIT', P, Reason} ->
            receive
                {P, Status} ->
                    update_ets_status({{Node, Subtask}, Status}),
                    ok
            after 0 ->
                    update_ets_status({{Node, Subtask}, died, Reason}),
                    error
            end;
        {'EXIT', _Other, Reason} = Msg ->
            ?log_info("got exit ~p while waiting for collectinfo slave on node ~p", [Msg, Node]),
            erlang:exit(Reason)
    end.

do_run_node_collection(Node, BaseURL, TimestampS, Options) ->
    get_token(collect_throttle),
    ?log_debug("Starting collection task for: ~p", [{Node, BaseURL, TimestampS, Options}]),
    {ok, P, Path} = start_subtask(Node, collection,
                                  cluster_logs_collection_task,
                                  start_collection_per_node,
                                  [TimestampS, self(), Options]),
    update_ets_status({{Node, collection}, started, Path}),
    case wait_child(P, Node, collection) of
        ok ->
            put_token(collect_throttle),
            maybe_upload_node_result(Node, Path, BaseURL, Options);
        Err ->
            Err
    end.

maybe_upload_node_result(_Node, _Path, false, _Options) ->
    ok;
maybe_upload_node_result(Node, Path, BaseURL, Options) ->
    get_token(upload_throttle),
    ?log_debug("Starting upload task for: ~p", [{Node, Path, BaseURL, Options}]),
    {ok, P, URL} = start_subtask(Node, upload,
                                 cluster_logs_collection_task,
                                 start_upload_per_node,
                                 [Path, BaseURL, self(), Options]),
    update_ets_status({{Node, upload}, started, URL}),
    wait_child(P, Node, upload).

start_collection_per_node(TimestampS, Parent, Options) ->
    Basename = "collectinfo-" ++ TimestampS ++ "-" ++ atom_to_list(node()) ++ ".zip",
    Filename = path_config:component_path(tmp, Basename),
    InitargsFilename = path_config:component_path(data, "initargs"),
    proc_lib:init_ack(Parent, {ok, self(), Filename}),
    MaybeSingleNode = case proplists:get_bool(no_single_node_diag, Options) of
                          false ->
                              ["--single-node-diag"];
                          _ ->
                              []
                      end,
    Args = ["--watch-stdin"] ++ MaybeSingleNode
        ++ ["--initargs=" ++ InitargsFilename, Filename],
    ?log_debug("spawning collectinfo: ~p", [Args]),
    {Status, Output} =
        misc:run_external_tool(path_config:component_path(bin, "cbcollect_info"),
                               Args, []),
    ?log_debug("Done"),
    case Status of
        0 ->
            Parent ! {self(), {ok, Filename, Output}};
        _ ->
            Parent ! {self(), {error, Status, Output}}
    end.

start_upload_per_node(Path, BaseURL, Parent, _Options) ->
    URL = BaseURL ++ mochiweb_util:quote_plus(filename:basename(Path)),
    proc_lib:init_ack(Parent, {ok, self(), URL}),
    Args = ["--watch-stdin", "--just-upload-into=" ++ URL, Path],
    ?log_debug("Spawning upload cbcollect_info: ~p", [Args]),
    {Status, Output} =
        misc:run_external_tool(path_config:component_path(bin, "cbcollect_info"),
                               Args),
    case Status of
        0 ->
            ?log_debug("uploaded ~s to ~s successfully. Deleting it", [Path, URL]),
            _ = file:delete(Path),
            Parent ! {self(), {ok, URL}};
        _ ->
            ?log_debug("upload of ~s to ~s failed with status ~p~n~s", [Path, URL, Status, Output]),
            Parent ! {self(), {error, URL, Status, Output}}
    end.

preflight_base_url(false) ->
    ok;
preflight_base_url(BaseURL) ->
    ?log_debug("Doing preflight_base_url(~s)", [BaseURL]),
    case httpc:request(head, {BaseURL, []}, [], []) of
        {ok, Result} ->
            ?log_debug("Got some result: ~p", [Result]),
            ok;
        {error, Reason} ->
            Msg = io_lib:format("Failed to check reachability of ~s: ~p", [BaseURL, Reason]),
            {error, iolist_to_binary(Msg)}
    end.
