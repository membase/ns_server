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
            %% get docinfo of missing ids
            MissingDocInfoList = find_missing(Changes, Target),
            NumChecked = length(Changes),
            %% use ptr in docinfo to fetch document from storage
            {ok, DataRepd} = local_process_batch(
                               MissingDocInfoList, Cp, Source, Target, #batch{}),
            ok = gen_server:call(Cp, {report_seq_done, ReportSeq, NumChecked, length(MissingDocInfoList), DataRepd}, infinity),
            ?xdcr_debug("Worker reported completion of seq ~p", [ReportSeq]),
            queue_fetch_loop(Source, Target, Cp, ChangesManager)
    end.

local_process_batch([], _Cp, _Src, _Tgt, #batch{docs = []}) ->
    {ok, 0};
local_process_batch([], Cp, #db{} = Source, #httpdb{} = Target,
                    #batch{docs = Docs, size = Size}) ->
    ?xdcr_debug("worker process flushing a batch docs of total size ~p bytes",
                [Size]),
    ok = flush_docs(Target, Docs),
    {ok, DataRepd1} = local_process_batch([], Cp, Source, Target, #batch{}),
    {ok, DataRepd1 + Size};

local_process_batch([DocInfo | Rest], Cp, #db{} = Source,
                    #httpdb{} = Target, Batch) ->
    {ok, {_, DocList, _}} = fetch_doc(
                                      Source, DocInfo, fun local_doc_handler/2,
                                      {Target, [], Cp}),
    {Batch2, DataFlushed} = lists:foldl(
                         fun(Doc, {Batch0, DataFlushed1}) ->
                                 maybe_flush_docs(Target, Batch0, Doc, DataFlushed1)
                         end,
                         {Batch, 0}, DocList),
    {ok, DataFlushed2} = local_process_batch(Rest, Cp, Source, Target, Batch2),
    %% return total data flushed
    {ok, DataFlushed + DataFlushed2}.


%% fetch doc using doc info
fetch_doc(Source, #doc_info{body_ptr = _BodyPtr} = DocInfo, DocHandler, Acc) ->
    couch_api_wrap:open_doc(Source, DocInfo, [deleted], DocHandler, Acc).

local_doc_handler({ok, Doc}, {Target, DocList, Cp}) ->
    {ok, {Target, [Doc | DocList], Cp}};
local_doc_handler(_, Acc) ->
    {ok, Acc}.

maybe_flush_docs(#httpdb{} = Target, Batch, Doc, DataFlushed) ->
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
            %% data flushed, return empty batch and size of data flushed
            {#batch{}, SizeAcc2 + DataFlushed};
        SizeAcc2 ->
            %% no data flushed in this turn, return the new batch
            {#batch{docs = [JsonDoc | DocAcc], size = SizeAcc2}, DataFlushed}
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

%% return list of Docsinfos of missing keys
-spec find_missing(list(), #httpdb{}) -> list().
find_missing(DocInfos, Target) ->
    {IdRevs, AllRevsCount} = lists:foldr(
                               fun(#doc_info{id = Id, rev = Rev}, {IdRevAcc, CountAcc}) ->
                                       {[{Id, Rev} | IdRevAcc], CountAcc + 1}
                               end,
                               {[], 0}, DocInfos),
    {ok, Missing} = couch_api_wrap:get_missing_revs(Target, IdRevs),

    %%build list of docinfo for all missing ids
    MissingDocInfoList = lists:filter(
                           fun(#doc_info{id = Id, rev = _Rev} = _DocInfo) ->
                                   case lists:keyfind(Id, 1, Missing) of
                                       %% not a missing key
                                       false ->
                                           false;
                                       %% a missing key
                                       _  -> true
                                   end
                           end,
                           DocInfos),

    ?xdcr_debug("after conflict resolution at target (~p), out of all ~p docs "
                "the number of docs we need to replicate is: ~p",
                [Target#httpdb.url, AllRevsCount, length(Missing)]),

    MissingDocInfoList.
