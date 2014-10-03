%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% @doc Implementation of diagnostics web requests
-module(diag_handler).
-author('NorthScale <info@northscale.com>').

-include("ns_common.hrl").
-include("ns_log.hrl").
-include_lib("kernel/include/file.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([do_diag_per_node/0, do_diag_per_node_binary/0,
         handle_diag/1,
         handle_sasl_logs/1, handle_sasl_logs/2,
         handle_diag_ale/1,
         arm_timeout/2, arm_timeout/1, disarm_timeout/1,
         grab_process_info/1, manifest/0,
         grab_all_tap_and_checkpoint_stats/0,
         grab_all_tap_and_checkpoint_stats/1,
         log_all_tap_and_checkpoint_stats/0,
         diagnosing_timeouts/1,
         %% rpc-ed to grab babysitter processes
         grab_process_infos/0]).

% Read the manifest.xml file
manifest() ->
    case file:read_file(filename:join(path_config:component_path(bin, ".."), "manifest.xml")) of
        {ok, C} ->
            string:tokens(binary_to_list(C), "\n");
        _ -> []
    end.

%% works like lists:foldl(Fun, Acc, binary:split(Binary, Separator, [global]))
%%
%% But without problems of binary:split. See MB-9534
split_fold_incremental(Binary, Separator, Fun, Acc) ->
    CP = binary:compile_pattern(Separator),
    Len = erlang:size(Binary),
    split_fold_incremental_loop(Binary, CP, Len, Fun, Acc, 0).

split_fold_incremental_loop(_Binary, _CP, Len, _Fun, Acc, Start) when Start > Len ->
    Acc;
split_fold_incremental_loop(Binary, CP, Len, Fun, Acc, Start) ->
    {MatchPos, MatchLen} =
        case binary:match(Binary, CP, [{scope, {Start, Len - Start}}]) of
            nomatch ->
                %% NOTE: 1 here will move Start _past_ Len on next
                %% loop iteration
                {Len, 1};
            MatchPair ->
                MatchPair
        end,
    NewPiece = binary:part(Binary, Start, MatchPos - Start),
    NewAcc = Fun(NewPiece, Acc),
    split_fold_incremental_loop(Binary, CP, Len, Fun, NewAcc, MatchPos + MatchLen).

-spec sanitize_backtrace(binary()) -> [binary()].
sanitize_backtrace(Backtrace) ->
    R = split_fold_incremental(
          Backtrace, <<"\n">>,
          fun (X, Acc) ->
                  if
                      size(X) =< 120 ->
                          [binary:copy(X) | Acc];
                      true ->
                          [binary:copy(binary:part(X, 1, 120)) | Acc]
                  end
          end, []),
    lists:reverse(R).

grab_process_info(Pid) ->
    PureInfo = erlang:process_info(Pid,
                                   [registered_name,
                                    status,
                                    initial_call,
                                    backtrace,
                                    error_handler,
                                    garbage_collection,
                                    heap_size,
                                    total_heap_size,
                                    links,
                                    memory,
                                    message_queue_len,
                                    reductions,
                                    trap_exit]),
    Backtrace = proplists:get_value(backtrace, PureInfo),
    NewBacktrace = sanitize_backtrace(Backtrace),
    lists:keyreplace(backtrace, 1, PureInfo, {backtrace, NewBacktrace}).

grab_all_tap_and_checkpoint_stats() ->
    grab_all_tap_and_checkpoint_stats(15000).

grab_all_tap_and_checkpoint_stats(Timeout) ->
    ActiveBuckets = ns_memcached:active_buckets(),
    ThisNodeBuckets = ns_bucket:node_bucket_names_of_type(node(), membase),
    InterestingBuckets = ordsets:intersection(lists:sort(ActiveBuckets),
                                              lists:sort(ThisNodeBuckets)),
    WorkItems = [{Bucket, Type} || Bucket <- InterestingBuckets,
                                   Type <- [<<"tap">>, <<"checkpoint">>, <<"dcp">>]],
    Results = misc:parallel_map(
                fun ({Bucket, Type}) ->
                        {ok, _} = timer2:kill_after(Timeout),
                        case ns_memcached:stats(Bucket, Type) of
                            {ok, V} -> V;
                            Crap -> Crap
                        end
                end, WorkItems, infinity),
    {WiB, WiT} = lists:unzip(WorkItems),
    lists:zip3(WiB, WiT, Results).

log_all_tap_and_checkpoint_stats() ->
    ?log_info("logging tap & checkpoint stats"),
    [begin
         ?log_info("~s:~s:~n~p",[Type, Bucket, Values])
     end || {Bucket, Type, Values} <- grab_all_tap_and_checkpoint_stats()],
    ?log_info("end of logging tap & checkpoint stats").

task_status_all() ->
    local_tasks:all() ++ ns_couchdb_api:get_tasks().

do_diag_per_node() ->
    ActiveBuckets = ns_memcached:active_buckets(),
    [{version, ns_info:version()},
     {manifest, manifest()},
     {config, ns_config_log:sanitize(ns_config:get_kv_list())},
     {basic_info, element(2, ns_info:basic_info())},
     {processes, grab_process_infos()},
     {babysitter_processes, (catch grab_babysitter_process_infos())},
     {memory, memsup:get_memory_data()},
     {disk, (catch ns_disksup:get_disk_data())},
     {active_tasks, task_status_all()},
     {master_events, (catch master_activity_events_keeper:get_history())},
     {ns_server_stats, (catch system_stats_collector:get_ns_server_stats())},
     {active_buckets, ActiveBuckets},
     {tap_stats, (catch grab_all_tap_and_checkpoint_stats(4000))}].

do_diag_per_node_binary() ->
    work_queue:submit_sync_work(
      diag_handler_worker,
      fun () ->
              (catch collect_diag_per_node_binary(40000))
      end).

collect_diag_per_node_binary(Timeout) ->
    ReplyRef = make_ref(),
    Parent = self(),
    {ChildPid, ChildRef} =
        spawn_monitor(
          fun () ->
                  Reply = fun (Key, Value) ->
                                  Parent ! {ReplyRef, {Key, Value}}
                          end,

                  ChildPid = self(),
                  proc_lib:spawn_link(
                    fun () ->
                            erlang:monitor(process, Parent),
                            erlang:monitor(process, ChildPid),

                            receive
                                {'DOWN', _, _, _, Reason} ->
                                    exit(ChildPid, Reason)
                            end
                    end),

                  try
                      collect_diag_per_node_binary_body(Reply)
                  catch
                      T:E ->
                          Reply(partial_results_reason,
                                {process_died, {T, E, erlang:get_stacktrace()}})
                  end
          end),

    TRef = erlang:send_after(Timeout, self(), timeout),

    try
        RV = collect_diag_per_node_binary_loop(ReplyRef, ChildRef, []),
        term_to_binary(RV)
    after
        erlang:cancel_timer(TRef),
        receive
            timeout -> ok
        after
            0 -> ok
        end,

        erlang:demonitor(ChildRef, [flush]),
        exit(ChildPid, kill),

        flush_leftover_replies(ReplyRef)
    end.

flush_leftover_replies(ReplyRef) ->
    receive
        {ReplyRef, _} ->
            flush_leftover_replies(ReplyRef)
    after
        0 -> ok
    end.

collect_diag_per_node_binary_loop(ReplyRef, ChildRef, Results) ->
    receive
        {ReplyRef, Item} ->
            collect_diag_per_node_binary_loop(ReplyRef, ChildRef, [Item | Results]);
        timeout ->
            [{partial_results_reason, timeout} | Results];
        {'DOWN', ChildRef, process, _, _} ->
            Results
    end.

collect_diag_per_node_binary_body(Reply) ->
    ActiveBuckets = ns_memcached:active_buckets(),

    Reply(processes, grab_process_infos()),
    Reply(babysitter_processes, (catch grab_babysitter_process_infos())),
    Reply(version, ns_info:version()),
    Reply(manifest, manifest()),
    Reply(config, ns_config_log:sanitize(ns_config:get_kv_list())),
    Reply(basic_info, element(2, ns_info:basic_info())),
    Reply(memory, memsup:get_memory_data()),
    Reply(disk, (catch ns_disksup:get_disk_data())),
    Reply(active_tasks, task_status_all()),
    Reply(master_events, (catch master_activity_events_keeper:get_history_raw())),
    Reply(ns_server_stats, (catch system_stats_collector:get_ns_server_stats())),
    Reply(active_buckets, ActiveBuckets),
    Reply(replication_docs, (catch xdc_rdoc_api:find_all_replication_docs(5000))),
    Reply(master_local_docs, [{Bucket, (catch capi_utils:capture_local_master_docs(Bucket, 10000))} || Bucket <- ActiveBuckets]),
    Reply(design_docs, [{Bucket, (catch capi_utils:full_live_ddocs(Bucket, 2000))} || Bucket <- ActiveBuckets]),
    Reply(tap_stats, (catch grab_all_tap_and_checkpoint_stats(4000))),
    Reply(ets_tables, (catch grab_all_ets_tables())),
    Reply(internal_settings, (catch menelaus_web:build_internal_settings_kvs())),
    Reply(logging, (catch ale:capture_logging_diagnostics())).

grab_babysitter_process_infos() ->
    rpc:call(ns_server:get_babysitter_node(), ?MODULE, grab_process_infos, [], 5000).

grab_process_infos() ->
    grab_process_infos_loop(erlang:processes(), []).

grab_process_infos_loop([], Acc) ->
    Acc;
grab_process_infos_loop([P | RestPids], Acc) ->
    NewAcc = [{P, (catch grab_process_info(P))} | Acc],
    grab_process_infos_loop(RestPids, NewAcc).

grab_all_ets_tables() ->
    lists:flatmap(
      fun (T) ->
              Contents =
                  try
                      ets:tab2list(T)
                  catch
                      _:_ -> failed
                  end,

              case Contents of
                  failed ->
                      [];
                  _ ->
                      [{T, ns_config_log:sanitize(Contents)}]
              end
      end, ets:all()).

diag_format_timestamp(EpochMilliseconds) ->
    SecondsRaw = trunc(EpochMilliseconds/1000),
    AsNow = {SecondsRaw div 1000000, SecondsRaw rem 1000000, 0},
    %% not sure about local time here
    {{YYYY, MM, DD}, {Hour, Min, Sec}} = calendar:now_to_local_time(AsNow),
    io_lib:format("~4.4.0w-~2.2.0w-~2.2.0w ~2.2.0w:~2.2.0w:~2.2.0w.~3.3.0w",
                  [YYYY, MM, DD, Hour, Min, Sec, EpochMilliseconds rem 1000]).

generate_diag_filename() ->
    {{YYYY, MM, DD}, {Hour, Min, Sec}} = calendar:now_to_local_time(now()),
    io_lib:format("ns-diag-~4.4.0w~2.2.0w~2.2.0w~2.2.0w~2.2.0w~2.2.0w.txt",
                  [YYYY, MM, DD, Hour, Min, Sec]).

diag_format_log_entry(Type, Code, Module, Node, TStamp, ShortText, Text) ->
    FormattedTStamp = diag_format_timestamp(TStamp),
    io_lib:format("~s ~s:~B:~s:~s(~s) - ~s~n",
                  [FormattedTStamp, Module, Code, Type, ShortText, Node, Text]).

handle_diag(Req) ->
    Params = Req:parse_qs(),
    MaybeContDisp = case proplists:get_value("mode", Params) of
                        "view" -> [];
                        _ -> [{"Content-Disposition", "attachment; filename=" ++ generate_diag_filename()}]
                    end,
    case proplists:get_value("noLogs", Params, "0") of
        "0" ->
            do_handle_diag(Req, MaybeContDisp);
        _ ->
            Resp = handle_just_diag(Req, MaybeContDisp),
            Resp:write_chunk(<<>>)
    end.

grab_per_node_diag(Nodes) ->
    {Results0, BadNodes} = rpc:multicall(Nodes,
                                         ?MODULE, do_diag_per_node_binary, [], 45000),
    {OldNodeResults, Results1} =
        lists:partition(
          fun ({_Node, {badrpc, {'EXIT', R}}}) ->
                  misc:is_undef_exit(?MODULE, do_diag_per_node_binary, [], R);
              (_) ->
                  false
          end,
          lists:zip(lists:subtract(Nodes, BadNodes), Results0)),

    OldNodes = [N || {N, _} <- OldNodeResults],
    Results = [{N, diag_failed} || N <- BadNodes] ++ Results1,

    {Results, OldNodes}.

handle_just_diag(Req, Extra) ->
    Resp = menelaus_util:reply_ok(Req, "text/plain; charset=utf-8", chunked, Extra),

    Resp:write_chunk(<<"logs:\n-------------------------------\n">>),
    lists:foreach(fun (#log_entry{node = Node,
                                  module = Module,
                                  code = Code,
                                  msg = Msg,
                                  args = Args,
                                  cat = Cat,
                                  tstamp = TStamp}) ->
                          try io_lib:format(Msg, Args) of
                              S ->
                                  CodeString = ns_log:code_string(Module, Code),
                                  Type = menelaus_alert:category_bin(Cat),
                                  TStampEpoch = misc:time_to_epoch_ms_int(TStamp),
                                  Resp:write_chunk(iolist_to_binary(diag_format_log_entry(Type, Code, Module, Node, TStampEpoch, CodeString, S)))
                          catch _:_ -> ok
                          end
                  end, lists:keysort(#log_entry.tstamp, ns_log:recent())),
    Resp:write_chunk(<<"-------------------------------\n\n\n">>),

    Nodes = case proplists:get_value("oneNode", Req:parse_qs(), "0") of
                "0" -> ns_node_disco:nodes_actual();
                _ -> [node()]
            end,
    {Results, OldNodes} = grab_per_node_diag(Nodes),

    handle_per_node_just_diag(Resp, Results),
    handle_per_node_just_diag_old_nodes(Resp, OldNodes),

    Buckets = lists:sort(fun (A,B) -> element(1, A) =< element(1, B) end,
                         ns_bucket:get_buckets()),

    Infos = [["nodes_info = ~p", menelaus_web:build_nodes_info()],
             ["buckets = ~p", ns_config_log:sanitize(Buckets)]],

    [begin
         Text = io_lib:format(Fmt ++ "~n~n", Args),
         Resp:write_chunk(list_to_binary(Text))
     end || [Fmt | Args] <- Infos],

    Resp.

write_chunk_format(Resp, Fmt, Args) ->
    Text = io_lib:format(Fmt, Args),
    Resp:write_chunk(list_to_binary(Text)).

handle_per_node_just_diag(_Resp, []) ->
    erlang:garbage_collect();
handle_per_node_just_diag(Resp, [{Node, DiagBinary} | Results]) ->
    erlang:garbage_collect(),

    Diag = case is_binary(DiagBinary) of
               true ->
                   try
                       binary_to_term(DiagBinary)
                   catch
                       error:badarg ->
                           ?log_error("Could not convert "
                                      "binary diag to term (node ~p)", [Node]),
                           {diag_failed, binary_to_term_failed}
                   end;
               false ->
                   DiagBinary
           end,
    do_handle_per_node_just_diag(Resp, Node, Diag),
    handle_per_node_just_diag(Resp, Results).

handle_per_node_just_diag_old_nodes(_Resp, []) ->
    erlang:garbage_collect();
handle_per_node_just_diag_old_nodes(Resp, [Node | Nodes]) ->
    erlang:garbage_collect(),

    PerNodeDiag = rpc:call(Node, ?MODULE, do_diag_per_node, [], 20000),
    do_handle_per_node_just_diag(Resp, Node, PerNodeDiag),
    handle_per_node_just_diag_old_nodes(Resp, Nodes).

do_handle_per_node_just_diag(Resp, Node, Failed) when not is_list(Failed) ->
    write_chunk_format(Resp, "per_node_diag(~p) = ~p~n~n~n", [Node, Failed]);
do_handle_per_node_just_diag(Resp, Node, PerNodeDiag) ->
    MasterEvents = proplists:get_value(master_events, PerNodeDiag, []),
    DiagNoMasterEvents = lists:keydelete(master_events, 1, PerNodeDiag),

    misc:executing_on_new_process(
      fun () ->
              write_chunk_format(Resp, "master_events(~p) =~n", [Node]),
              lists:foreach(
                fun (Event0) ->
                        Event = case is_binary(Event0) of
                                    true ->
                                        binary_to_term(Event0);
                                    false ->
                                        Event0
                                end,
                        misc:executing_on_new_process(
                          fun () ->
                                  lists:foreach(
                                    fun (JSON) ->
                                            write_chunk_format(Resp, "     ~p~n", [JSON])
                                    end, master_activity_events:event_to_jsons(Event))
                          end)
                end, MasterEvents),
              Resp:write_chunk(<<"\n\n">>)
      end),

    do_handle_per_node_processes(Resp, Node, DiagNoMasterEvents).

do_handle_per_node_processes(Resp, Node, PerNodeDiag) ->
    erlang:garbage_collect(),

    Processes = proplists:get_value(processes, PerNodeDiag),

    BabysitterProcesses0 = proplists:get_value(babysitter_processes, PerNodeDiag, []),
    %% it may be rpc or any other error; just pretend it's the process so that
    %% the error is visible
    BabysitterProcesses = case is_list(BabysitterProcesses0) of
                              true ->
                                  BabysitterProcesses0;
                              false ->
                                  [BabysitterProcesses0]
                          end,

    DiagNoProcesses = lists:keydelete(processes, 1,
                                       lists:keydelete(babysitter_processes, 1, PerNodeDiag)),

    misc:executing_on_new_process(
      fun () ->
              write_chunk_format(Resp, "per_node_processes(~p) =~n", [Node]),
              lists:foreach(
                fun (Process) ->
                        write_chunk_format(Resp, "     ~p~n", [Process])
                end, Processes),
              Resp:write_chunk(<<"\n\n">>)
      end),

    misc:executing_on_new_process(
      fun () ->
              write_chunk_format(Resp, "per_node_babysitter_processes(~p) =~n", [Node]),
              lists:foreach(
                fun (Process) ->
                        write_chunk_format(Resp, "     ~p~n", [Process])
                end, BabysitterProcesses),
              Resp:write_chunk(<<"\n\n">>)
      end),

    do_handle_per_node_stats(Resp, Node, DiagNoProcesses).

do_handle_per_node_stats(Resp, Node, PerNodeDiag)->
    %% pre 3.0 versions return stats as part of per node diagnostics; since
    %% number of samples may be quite substantial to cause memory issues while
    %% pretty-printing all of them in a bulk, to play safe we have this code
    %% to print samples one by one
    Stats0 = proplists:get_value(stats, PerNodeDiag, []),
    Stats = case is_list(Stats0) of
                true ->
                    Stats0;
                false ->
                    [{"_", [{'_', [Stats0]}]}]
            end,

    misc:executing_on_new_process(
      fun () ->
              lists:foreach(
                fun ({Bucket, BucketStats}) ->
                        lists:foreach(
                          fun ({Period, Samples}) ->
                                  write_chunk_format(Resp, "per_node_stats(~p, ~p, ~p) =~n",
                                                     [Node, Bucket, Period]),

                                  lists:foreach(
                                    fun (Sample) ->
                                            write_chunk_format(Resp, "     ~p~n", [Sample])
                                    end, Samples)
                          end, BucketStats)
                end, Stats),
              Resp:write_chunk(<<"\n\n">>)
      end),

    DiagNoStats = lists:keydelete(stats, 1, PerNodeDiag),
    do_handle_per_node_ets_tables(Resp, Node, DiagNoStats).

do_handle_per_node_ets_tables(Resp, Node, PerNodeDiag) ->
    EtsTables0 = proplists:get_value(ets_tables, PerNodeDiag, []),
    EtsTables = case is_list(EtsTables0) of
                    true ->
                        EtsTables0;
                    false ->
                        [{'_', [EtsTables0]}]
                end,

    misc:executing_on_new_process(
      fun () ->
              lists:foreach(
                fun ({Table, Values}) ->
                        write_chunk_format(Resp, "per_node_ets_tables(~p, ~p) =~n",
                                           [Node, Table]),

                        lists:foreach(
                          fun (Value) ->
                                  write_chunk_format(Resp, "     ~p~n", [Value])
                          end, Values),

                        Resp:write_chunk(<<"\n">>)
                end, EtsTables)
      end),

    DiagNoEtsTables = lists:keydelete(ets_tables, 1, PerNodeDiag),
    do_continue_handling_per_node_just_diag(Resp, Node, DiagNoEtsTables).

do_continue_handling_per_node_just_diag(Resp, Node, Diag) ->
    erlang:garbage_collect(),

    misc:executing_on_new_process(
      fun () ->
              write_chunk_format(Resp, "per_node_diag(~p) =~n", [Node]),
              write_chunk_format(Resp, "     ~p~n", [Diag])
      end),

    Resp:write_chunk(<<"\n\n">>).

do_handle_diag(Req, Extra) ->
    Resp = handle_just_diag(Req, Extra),

    Logs = [?DEBUG_LOG_FILENAME, ?STATS_LOG_FILENAME,
            ?DEFAULT_LOG_FILENAME, ?ERRORS_LOG_FILENAME,
            ?XDCR_LOG_FILENAME, ?XDCR_ERRORS_LOG_FILENAME,
            ?COUCHDB_LOG_FILENAME,
            ?VIEWS_LOG_FILENAME, ?MAPREDUCE_ERRORS_LOG_FILENAME,
            ?BABYSITTER_LOG_FILENAME,
            ?SSL_PROXY_LOG_FILENAME, ?REPORTS_LOG_FILENAME,
            ?XDCR_TRACE_LOG_FILENAME, ?ACCESS_LOG_FILENAME],

    lists:foreach(fun (Log) ->
                          handle_log(Resp, Log)
                  end, Logs),
    handle_memcached_logs(Resp),
    Resp:write_chunk(<<"">>).

handle_log(Resp, LogName) ->
    LogsHeader = io_lib:format("logs_node (~s):~n"
                               "-------------------------------~n", [LogName]),
    Resp:write_chunk(list_to_binary(LogsHeader)),
    ns_log_browser:stream_logs(LogName,
                               fun (Data) -> Resp:write_chunk(Data) end),
    Resp:write_chunk(<<"-------------------------------\n">>).


handle_memcached_logs(Resp) ->
    Config = ns_config:get(),
    Path = ns_config:search_node_prop(Config, memcached, log_path),
    Prefix = ns_config:search_node_prop(Config, memcached, log_prefix),

    {ok, AllFiles} = file:list_dir(Path),
    Logs = [filename:join(Path, F) || F <- AllFiles,
                                      string:str(F, Prefix) == 1],
    TsLogs = lists:map(fun(F) ->
                               case file:read_file_info(F) of
                                   {ok, Info} ->
                                       {F, Info#file_info.mtime};
                                   {error, enoent} ->
                                       deleted
                               end
                       end, Logs),

    Sorted = lists:keysort(2, lists:filter(fun (X) -> X /= deleted end, TsLogs)),

    Resp:write_chunk(<<"memcached logs:\n-------------------------------\n">>),

    lists:foreach(fun ({Log, _}) ->
                          handle_memcached_log(Resp, Log)
                  end, Sorted).

handle_memcached_log(Resp, Log) ->
    case file:open(Log, [raw, binary]) of
        {ok, File} ->
            try
                do_handle_memcached_log(Resp, File)
            after
                file:close(File)
            end;
        Error ->
            Resp:write_chunk(
              list_to_binary(io_lib:format("Could not open file ~s: ~p~n", [Log, Error])))
    end.

-define(CHUNK_SIZE, 65536).

do_handle_memcached_log(Resp, File) ->
    case file:read(File, ?CHUNK_SIZE) of
        eof ->
            ok;
        {ok, Data} ->
            Resp:write_chunk(Data)
    end.

handle_sasl_logs(LogName, Req) ->
    case ns_log_browser:log_exists(LogName) of
        true ->
            Resp = menelaus_util:reply_ok(Req, "text/plain; charset=utf-8", chunked),
            handle_log(Resp, LogName),
            Resp:write_chunk(<<"">>);
        false ->
            menelaus_util:reply_text(Req, "Requested log file not found.\r\n", 404)
    end.

handle_sasl_logs(Req) ->
    handle_sasl_logs(?DEBUG_LOG_FILENAME, Req).

plist_to_ejson_rewriter([Tuple|_] = ListOfTuples) when is_tuple(Tuple) ->
    Objects = [misc:rewrite(fun plist_to_ejson_rewriter/1, PL)
               || PL <- ListOfTuples],
    {stop, {Objects}};
plist_to_ejson_rewriter(_Other) ->
    continue.

handle_diag_ale(Req) ->
    PList = ale:capture_logging_diagnostics(),
    Objects = misc:rewrite(fun plist_to_ejson_rewriter/1, PList),
    menelaus_util:reply_json(Req, Objects).

arm_timeout(Millis) ->
    arm_timeout(Millis,
                fun (Pid) ->
                        Info = (catch grab_process_info(Pid)),
                        ?log_error("slow process info:~n~p~n", [Info])
                end).

arm_timeout(Millis, Callback) ->
    Pid = self(),
    spawn_link(fun () ->
                       receive
                           done -> ok
                       after Millis ->
                               erlang:unlink(Pid),
                               Callback(Pid)
                       end,
                       erlang:unlink(Pid)
               end).

disarm_timeout(Pid) ->
    Pid ! done.

diagnosing_timeouts(Body) ->
    try Body()
    catch exit:{timeout, _} = X ->
            timeout_diag_logger:log_diagnostics(X),
            exit(X)
    end.

-ifdef(EUNIT).

split_incremental(Binary, Separator) ->
    R = split_fold_incremental(Binary, Separator,
                               fun (Part, Acc) ->
                                       [Part | Acc]
                               end, []),
    lists:reverse(R).

split_incremental_test() ->
    String1 = <<"abc\n\ntext">>,
    String2 = <<"abc\n\ntext\n">>,
    String3 = <<"\nabc\n\ntext\n">>,
    Split1a = binary:split(String1, <<"\n">>, [global]),
    Split2a = binary:split(String2, <<"\n">>, [global]),
    Split3a = binary:split(String3, <<"\n">>, [global]),
    ?assertEqual(Split1a, split_incremental(String1, <<"\n">>)),
    ?assertEqual(Split2a, split_incremental(String2, <<"\n">>)),
    ?assertEqual(Split3a, split_incremental(String3, <<"\n">>)).

-endif.
