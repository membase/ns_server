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

-export([do_diag_per_node/0, handle_diag/1, handle_sasl_logs/1]).


%% I'm trying to avoid consing here, but, probably, too much
diag_filter_out_config_password_list([], UnchangedMarker) ->
    UnchangedMarker;
diag_filter_out_config_password_list([X | Rest], UnchangedMarker) ->
    NewX = diag_filter_out_config_password_rec(X, UnchangedMarker),
    case diag_filter_out_config_password_list(Rest, UnchangedMarker) of
        UnchangedMarker ->
            case NewX of
                UnchangedMarker -> UnchangedMarker;
                _ -> [NewX | Rest]
            end;
        NewRest -> [case NewX of
                        UnchangedMarker -> X;
                        _ -> NewX
                    end | NewRest]
    end.

diag_filter_out_config_password_rec(Config, UnchangedMarker) when is_tuple(Config) ->
    case Config of
        {password, _} ->
            {password, 'filtered-out'};
        {pass, _} ->
            {pass, 'filtered-out'};
        _ -> case diag_filter_out_config_password_rec(tuple_to_list(Config), UnchangedMarker) of
                 UnchangedMarker -> Config;
                 List -> list_to_tuple(List)
             end
    end;
diag_filter_out_config_password_rec(Config, UnchangedMarker) when is_list(Config) ->
    diag_filter_out_config_password_list(Config, UnchangedMarker);
diag_filter_out_config_password_rec(_Config, UnchangedMarker) -> UnchangedMarker.

diag_filter_out_config_password(Config) ->
    UnchangedMarker = make_ref(),
    case diag_filter_out_config_password_rec(Config, UnchangedMarker) of
        UnchangedMarker -> Config;
        NewConfig -> NewConfig
    end.

% Read the manifest.txt file, wherever it might exist across different versions and O/S'es.
%
manifest() ->
    % The cwd should look like /opt/membase with a /opt/membase/bin symlink
    % to the right /opt/membase/VERSION/bin directory.
    %
    RV = lists:filter(fun ({ok, _}) -> true;
                          ({error, _}) -> false
                      end,
                      lists:map(fun file:read_file/1,
                                ["./bin/../manifest.txt", "./bin/../src/manifest.txt"])),
    case RV of
        [{ok, C}|_] ->
            lists:sort(string:tokens(binary_to_list(C), "\n"));
        [] -> []
    end.

do_diag_per_node() ->
    [{version, ns_info:version()},
     {manifest, manifest()},
     {config, diag_filter_out_config_password(ns_config:get_diag())},
     {basic_info, element(2, ns_info:basic_info())},
     {processes, [{Pid, erlang:process_info(Pid,
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
                                             trap_exit])}
                  || Pid <- erlang:processes()]},
     {memory, memsup:get_memory_data()},
     {disk, disksup:get_disk_data()}].

diag_multicall(Mod, F, Args) ->
    Nodes = [node() | nodes()],
    {Results, BadNodes} = rpc:multicall(Nodes, Mod, F, Args, 5000),
    lists:zipwith(fun (Node,Res) -> {Node, Res} end,
                  lists:subtract(Nodes, BadNodes),
                  Results)
        ++ lists:map(fun (Node) -> {Node, diag_failed} end,
                     BadNodes).

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

diag_format_log_entry(Entry) ->
    [Type, Code, Module,
     TStamp, ShortText, Text] = lists:map(fun (K) ->
                                                  proplists:get_value(K, Entry)
                                          end,
                                          [type, code, module, tstamp, shortText, text]),
    FormattedTStamp = diag_format_timestamp(TStamp),
    io_lib:format("~s ~s:~B:~s:~s - ~s~n",
                  [FormattedTStamp, Module, Code, Type, ShortText, Text]).

get_logs() ->
    try ns_log_browser:get_logs_as_file(all, all, []) of
        X -> X
    catch
        error:try_again ->
            timer:sleep(250),
            get_logs()
    end.

handle_diag(Req) ->
    Buckets = lists:sort(fun (A,B) -> element(1, A) =< element(1, B) end,
                         ns_bucket:get_buckets()),
    Logs = lists:flatmap(fun ({struct, Entry}) -> diag_format_log_entry(Entry) end,
                         menelaus_alert:build_logs([{"limit", "1000000"}])),
    Infos = [["per_node_diag = ~p", diag_multicall(?MODULE, do_diag_per_node, [])],
             ["nodes_info = ~p", menelaus_web:build_nodes_info(fakepool, true, normal, "127.0.0.1")],
             ["buckets = ~p", Buckets],
             ["logs:~n-------------------------------~n~s", Logs],
             ["logs_node:~n-------------------------------~n"]],
    Text = lists:flatmap(fun ([Fmt | Args]) ->
                                 io_lib:format(Fmt ++ "~n~n", Args)
                         end, Infos),
    Resp = Req:ok({"text/plain; charset=utf-8",
                   [{"Content-Disposition", "attachment; filename=" ++ generate_diag_filename()},
                    {"Content-Type", "text/plain"}
                    | menelaus_util:server_header()],
                   chunked}),
    Resp:write_chunk(list_to_binary(Text)),
    handle_logs(Resp).

handle_logs(Resp) ->
    TempFile = get_logs(),
    {ok, IO} = file:open(TempFile, [raw, binary]),
    stream_logs(Resp, IO),
    file:close(IO),
    file:delete(TempFile).

stream_logs(Resp, IO) ->
    case file:read(IO, 65536) of
        eof ->
            Resp:write_chunk(<<"">>),
            ok;
        {ok, Data} ->
            Resp:write_chunk(Data),
            stream_logs(Resp, IO)
    end.

handle_sasl_logs(Req) ->
    Resp = Req:ok({"text/plain; charset=utf-8",
            menelaus_util:server_header(),
            chunked}),
    handle_logs(Resp).
