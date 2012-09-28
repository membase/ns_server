%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

-module(xdc_vbucket_rep_worker).

%% public API
-export([start_link/5]).

-include("xdc_replicator.hrl").

%% in XDCR the Source should always from local with record #db{}, while
%% the target should always from remote with record #httpdb{}. There is
%% no intra-cluster XDCR
start_link(Cp, #db{} = Source, #httpdb{} = Target,
           ChangesManager, _MaxConns) ->
    Pid = spawn_link(fun() ->
                             erlang:monitor(process, ChangesManager),
                             queue_fetch_loop(Source, Target, Cp, ChangesManager)
                     end),
    ?xdcr_debug("create queue_fetch_loop process (pid: ~p) within replicator (pid: ~p) "
                "Source: ~p, Target: ~p, ChangesManager: ~p",
                [Pid, Cp, Source#db.name, Target#httpdb.url, ChangesManager]),

    {ok, Pid}.

queue_fetch_loop(Source, Target, Cp, ChangesManager) ->
    ?xdcr_debug("fetch changes from changes manager at ~p (target: ~p)",
               [ChangesManager, Target#httpdb.url]),
    ChangesManager ! {get_changes, self()},
    receive
        {'DOWN', _, _, _, _} ->
            ok = gen_server:call(Cp, {worker_done, self()}, infinity);
        {changes, ChangesManager, Changes, ReportSeq} ->
            IdRevs = find_missing(Changes, Target),
            NumChecked = length(Changes),
            local_process_batch(
                      IdRevs, Cp, Source, Target, #batch{}),
            ok = gen_server:call(Cp, {report_seq_done, ReportSeq, NumChecked, length(IdRevs)}, infinity),
            ?xdcr_debug("Worker reported completion of seq ~p", [ReportSeq]),
            queue_fetch_loop(Source, Target, Cp, ChangesManager)
    end.

local_process_batch([], _Cp, _Src, _Tgt, #batch{docs = []}) ->
    ok;
local_process_batch([], Cp, #db{} = Source, #httpdb{} = Target,
                    #batch{docs = Docs, size = Size}) ->
    ?xdcr_debug("worker process flushing a batch docs of total size ~p bytes",
                [Size]),
    ok = flush_docs(Target, Docs),
    local_process_batch([], Cp, Source, Target, #batch{});
local_process_batch([IdRevs | Rest], Cp, #db{} = Source,
                    #httpdb{} = Target, Batch) ->
    {ok, {_, DocList, _}} = fetch_doc(
                                      Source, IdRevs, fun local_doc_handler/2,
                                      {Target, [], Cp}),
    Batch2 = lists:foldl(
                         fun(Doc, Batch0) ->
                                 maybe_flush_docs(Target, Batch0, Doc)
                         end,
                         Batch, DocList),
    local_process_batch(Rest, Cp, Source, Target, Batch2).

fetch_doc(Source, {Id, _Rev}, DocHandler, Acc) ->
    couch_api_wrap:open_doc(
      Source, Id, [deleted], DocHandler, Acc).


local_doc_handler({ok, Doc}, {Target, DocList, Cp}) ->
    {ok, {Target, [Doc | DocList], Cp}};
local_doc_handler(_, Acc) ->
    {ok, Acc}.

maybe_flush_docs(#httpdb{} = Target, Batch, Doc) ->
    #batch{docs = DocAcc, size = SizeAcc} = Batch,
    JsonDoc = couch_doc:to_json_base64(Doc),

    %% env parameter can override the ns_config parameter
    {value, DefaultDocBatchSize} = ns_config:search(xdcr_doc_batch_size_kb),
    DocBatchSize = misc:getenv_int("XDCR_DOC_BATCH_SIZE_KB", DefaultDocBatchSize),

    DocBatchSizeByte = 1024*DocBatchSize,
    case SizeAcc + iolist_size(JsonDoc) of
        SizeAcc2 when SizeAcc2 > DocBatchSizeByte ->
            ?xdcr_debug("Worker flushing doc batch of size ~p bytes "
                        "(batch limit: ~p)", [SizeAcc2, DocBatchSizeByte]),
            flush_docs(Target, [JsonDoc | DocAcc]),
            #batch{};
        SizeAcc2 ->
            #batch{docs = [JsonDoc | DocAcc], size = SizeAcc2}
    end.

flush_docs(_Target, []) ->
    ok;
flush_docs(Target, DocList) ->
    case couch_api_wrap:update_docs(Target, DocList, [delay_commit],
                                    replicated_changes) of
        ok ->
            ?xdcr_debug("worker process replicated ~p docs to target ~p",
                        [length(DocList), Target#httpdb.url]),
            ok;
        {ok, {Props}} ->
            DbUri = couch_api_wrap:db_uri(Target),
            ?xdcr_error("Replicator: couldn't write document `~s`, revision `~s`,"
                        " to target database `~s`. Error: `~s`, reason: `~200s`.",
                        [get_value(<<"id">>, Props, ""), get_value(<<"rev">>, Props, ""), DbUri,
                         get_value(<<"error">>, Props, ""), get_value(<<"reason">>, Props, "")]),
            exit({failed_write, Props})
    end.

find_missing(DocInfos, Target) ->
    {IdRevs, AllRevsCount} = lists:foldr(
                               fun(#doc_info{id = Id, rev = Rev}, {IdRevAcc, CountAcc}) ->
                                       {[{Id, Rev} | IdRevAcc], CountAcc + 1}
                               end,
                               {[], 0}, DocInfos),
    {ok, Missing} = couch_api_wrap:get_missing_revs(Target, IdRevs),

    ?xdcr_debug("after conflict resolution at target (~p), out of all ~p docs "
                "the number of docs we need to replicate is: ~p",
                [Target#httpdb.url, AllRevsCount, length(Missing)]),
    Missing.
