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
-export([start_link/1]).

-include("xdc_replicator.hrl").
-include("xdcr_dcp_streamer.hrl").

%% imported functions
-import(couch_util, [get_value/3]).

start_link(#rep_worker_option{cp = Cp, target = Target,
                              worker_id  = WorkerID,
                              changes_manager = ChangesManager,
                              opt_rep_threshold = OptRepThreshold,
                              xmem_location = XMemLoc,
                              batch_size = BatchSize,
                              batch_items = BatchItems} = _WorkerOption) ->
    Pid = spawn_link(fun() ->
                             erlang:monitor(process, ChangesManager),
                             queue_fetch_loop(WorkerID, Target, Cp,
                                              ChangesManager, OptRepThreshold,
                                              BatchSize, BatchItems, XMemLoc)
                     end),


    {ok, Pid}.

-spec queue_fetch_loop(integer(), #httpdb{}, pid(), pid(),
                       integer(), integer(), integer(), any()) -> ok.
queue_fetch_loop(WorkerID, Target, Cp, ChangesManager,
                 OptRepThreshold, BatchSize, BatchItems, XMemLoc) ->
    ChangesManager ! {get_changes, self()},
    receive
        {'DOWN', _, _, _, _} ->
            ok = gen_server:call(Cp, {worker_done, self()}, infinity);
        {changes, ChangesManager, Changes, ReportSeq, SnapshotStart, SnapshotEnd} ->
            NumChecked = length(Changes),
            ?x_trace(gotChanges, [{reportSeq, ReportSeq},
                                  {snapshotStart, SnapshotStart},
                                  {snapshotEnd, SnapshotEnd},
                                  {count, NumChecked}]),
            %% get docinfo of missing ids
            {MissingDocInfoList, MetaLatency, NumDocsOptRepd} =
                find_missing(Changes, Target, OptRepThreshold, XMemLoc),
            NumWritten = length(MissingDocInfoList),
            ?x_trace(foundMissing, [{count, NumWritten}]),
            Start = now(),
            {ok, DataRepd} = local_process_batch(
                               MissingDocInfoList, Cp, Target,
                               #batch{}, BatchSize, BatchItems, XMemLoc, 0),

            %% the latency returned should be coupled with batch size, for example,
            %% if we send N docs in a batch, the latency returned to stats should be the latency
            %% for all N docs.
            DocLatency = timer:now_diff(now(), Start) div 1000,

            %% report seq done and stats to vb replicator
            ok = gen_server:call(Cp, {report_seq_done,
                                      #worker_stat{
                                         worker_id = WorkerID,
                                         seq = ReportSeq,
                                         snapshot_start_seq = SnapshotStart,
                                         snapshot_end_seq = SnapshotEnd,
                                         worker_meta_latency_aggr = MetaLatency*NumChecked,
                                         worker_docs_latency_aggr = DocLatency*NumWritten,
                                         worker_data_replicated = DataRepd,
                                         worker_item_opt_repd = NumDocsOptRepd,
                                         worker_item_checked = NumChecked,
                                         worker_item_replicated = NumWritten}}, infinity),

            ?x_trace(reportedSeqDone, [{reportSeq, ReportSeq},
                                       {snapshotStart, SnapshotStart},
                                       {snapshotEnd, SnapshotEnd},
                                       {changesCount, NumChecked},
                                       {missingCount, NumWritten}]),

            queue_fetch_loop(WorkerID, Target, Cp, ChangesManager,
                             OptRepThreshold, BatchSize, BatchItems, XMemLoc)
    end.


local_process_batch([], _Cp, _Tgt, #batch{docs = []}, _BatchSize, _BatchItems, _XMemLoc, Acc) ->
    {ok, Acc};
local_process_batch([], Cp, #httpdb{} = Target,
                    #batch{docs = Docs, size = Size}, BatchSize, BatchItems, XMemLoc, Acc) ->
    ok = flush_docs_helper(Target, Docs, XMemLoc),
    local_process_batch([], Cp, Target, #batch{}, BatchSize, BatchItems, XMemLoc, Acc + Size);

local_process_batch([Mutation | Rest], Cp,
                    #httpdb{} = Target, Batch, BatchSize, BatchItems, XMemLoc, Acc) ->
    #dcp_mutation{id = Key,
                  rev = Rev,
                  body = Body,
                  deleted = Deleted} = Mutation,
    {Batch2, DataFlushed} =
        case XMemLoc of
            nil ->
                Doc0 = couch_doc:from_binary(Key, Body, true),
                Doc = Doc0#doc{rev = Rev,
                               deleted = Deleted},
                maybe_flush_docs_capi(Target, Batch, Doc, BatchSize, BatchItems);
            _ ->
                maybe_flush_docs_xmem(XMemLoc, Batch, Mutation, BatchSize, BatchItems)
        end,
    local_process_batch(Rest, Cp, Target, Batch2, BatchSize, BatchItems, XMemLoc, Acc + DataFlushed).


-spec flush_docs_helper(any(), list(), term()) -> ok.
flush_docs_helper(Target, DocsList, nil) ->
    BeforeTS = case ?x_trace_enabled() of
                   true ->
                       os:timestamp();
                   _ ->
                       undefined
               end,
    {RepMode,RV} = {"capi", flush_docs_capi(Target, DocsList)},

    case RV of
        ok ->
            case BeforeTS of
                undefined ->
                    ok;
                _ ->
                    ?x_trace(flushed, [{beforeTS, xdcr_trace_log_formatter:format_ts(BeforeTS)}])
            end,
            ok;
        {failed_write, Error} ->
            ?xdcr_error("replication mode: ~p, unable to replicate ~p docs to target ~p",
                        [RepMode, length(DocsList), misc:sanitize_url(Target#httpdb.url)]),
            exit({failed_write, Error})
    end;

flush_docs_helper(Target, DocsList, XMemLoc) ->
    BeforeTS = case ?x_trace_enabled() of
                   true ->
                       os:timestamp();
                   _ ->
                       undefined
               end,
    {RepMode,RV} = {"xmem", flush_docs_xmem(XMemLoc, DocsList)},

    case RV of
        ok ->
            case BeforeTS of
                undefined ->
                    ok;
                _ ->
                    ?x_trace(flushed, [{startTS, xdcr_trace_log_formatter:format_ts(BeforeTS)}])
            end,
            ok;
        {failed_write, Error} ->
            ?xdcr_error("replication mode: ~p, unable to replicate ~p docs to target ~p",
                        [RepMode, length(DocsList), misc:sanitize_url(Target#httpdb.url)]),
            exit({failed_write, Error})
    end.

%% return list of Docsinfos of missing keys
-spec find_missing(list(), #httpdb{}, integer(), term()) -> {list(), integer(), integer()}.
find_missing(DocInfos, Target, OptRepThreshold, XMemLoc) ->
    Start = now(),

    %% depending on doc body size, we separate all keys into two groups:
    %% keys with doc body size greater than the threshold, and keys with doc body
    %% smaller than or equal to threshold.
    {BigDocIdRevs, SmallDocIdRevs, _DelCount, _BigDocCount,
     _SmallDocCount, _AllRevsCount} = lists:foldr(
                                      fun(#dcp_mutation{id = Id, rev = Rev, deleted = Deleted, body = Body},
                                          {BigIdRevAcc, SmallIdRevAcc, DelAcc, BigAcc, SmallAcc, CountAcc}) ->
                                              DocSize = erlang:size(Body),
                                              %% deleted doc is always treated as small doc, regardless of doc size
                                              {BigIdRevAcc1, SmallIdRevAcc1, DelAcc1, BigAcc1, SmallAcc1} =
                                                  case Deleted of
                                                      true ->
                                                          {BigIdRevAcc, [{Id, Rev} | SmallIdRevAcc], DelAcc + 1,
                                                           BigAcc, SmallAcc + 1};
                                                      _ ->
                                                          %% for all other mutations, check its doc size
                                                          case DocSize > OptRepThreshold of
                                                              true ->
                                                                  {[{Id, Rev} | BigIdRevAcc], SmallIdRevAcc, DelAcc,
                                                                   BigAcc + 1, SmallAcc};
                                                              _  ->
                                                                  {BigIdRevAcc, [{Id, Rev} | SmallIdRevAcc], DelAcc,
                                                                   BigAcc, SmallAcc + 1}
                                                          end
                                                  end,
                                              {BigIdRevAcc1, SmallIdRevAcc1, DelAcc1, BigAcc1, SmallAcc1, CountAcc + 1}
                                      end,
                                      {[], [], 0, 0, 0, 0}, DocInfos),

    %% metadata operation for big docs only
    Missing =
        case length(BigDocIdRevs) of
            V when V > 0 ->
                MissingBigIdRevs = find_missing_helper(Target, BigDocIdRevs, XMemLoc),
                LenMissing = length(MissingBigIdRevs),
                ?x_trace(didFindMissing, [{count, V}, {missingCount, LenMissing}]),
                lists:flatten([SmallDocIdRevs | MissingBigIdRevs]);
            _ ->
                SmallDocIdRevs
        end,

    %% latency in millisecond
    Latency = round(timer:now_diff(now(), Start) div 1000),

    %% build list of docinfo for all missing keys
    MissingDocInfoList = lists:filter(
                           fun(#dcp_mutation{id = Id,
                                             local_seq = KeySeq,
                                             rev = {RevA, _}}) ->
                                   case lists:keyfind(Id, 1, Missing) of
                                       %% not a missing key
                                       false ->
                                           ?x_trace(notMissing,
                                                    [{key, Id},
                                                     {seq, KeySeq},
                                                     {revnum, RevA}]),
                                           false;
                                       %% a missing key
                                       _  -> true
                                   end
                           end,
                           DocInfos),

    ?x_trace(missing,
             [{startTS, xdcr_trace_log_formatter:format_ts(Start)},
              {k, {json,
                   [[Id, KeySeq, RevA]
                    || #dcp_mutation{id = Id,
                                     local_seq = KeySeq,
                                     rev = {RevA, _}} <- MissingDocInfoList]}}]),

    {MissingDocInfoList, Latency, length(SmallDocIdRevs)}.

-spec find_missing_helper(#httpdb{}, list(), term()) -> list().
find_missing_helper(Target, BigDocIdRevs, XMemLoc) ->
    MissingIdRevs = case XMemLoc of
                        nil ->
                            {ok, IdRevs} = couch_api_wrap:get_missing_revs(Target, BigDocIdRevs),
                            IdRevs;
                        _ ->
                            {ok, IdRevs} = xdc_vbucket_rep_xmem:find_missing(XMemLoc, BigDocIdRevs),
                            IdRevs
                    end,
    MissingIdRevs.

%% ================================================= %%
%% ========= FLUSHING DOCS USING CAPI ============== %%
%% ================================================= %%
-spec maybe_flush_docs_capi(#httpdb{}, #batch{}, #doc{},
                            integer(), integer()) -> {#batch{}, integer()}.
maybe_flush_docs_capi(#httpdb{} = Target, Batch, Doc, BatchSize, BatchItems) ->
    #batch{docs = DocAcc, size = SizeAcc, items = ItemsAcc} = Batch,
    JsonDoc = couch_doc:to_json_base64(Doc),

    SizeAcc2 = SizeAcc + iolist_size(JsonDoc),
    ItemsAcc2 = ItemsAcc + 1,
    case ItemsAcc2 >= BatchItems orelse SizeAcc2 > BatchSize of
        true ->
            flush_docs_capi(Target, [JsonDoc | DocAcc]),
            ?x_trace(flushed, []),
            %% data flushed, return empty batch and size of data flushed
            {#batch{}, SizeAcc2};
        false ->            %% no data flushed in this turn, return the new batch
            {#batch{docs = [JsonDoc | DocAcc], size = SizeAcc2, items = ItemsAcc2}, 0}
    end.

-spec flush_docs_capi(#httpdb{}, list()) -> ok | {failed_write, term()}.
flush_docs_capi(_Target, []) ->
    ok;
flush_docs_capi(Target, DocsList) ->
    RV = couch_api_wrap:update_docs(Target, DocsList, [delay_commit],
                                    replicated_changes),
    ?x_trace(capiUpdateDocs, [{ids, {json, [(couch_doc:from_json_obj(ejson:decode(D)))#doc.id || D <- DocsList]}}
                              | case RV of
                                    ok -> [{success, true}];
                                    _ -> [{success, false}]
                                end]),
    case RV of
        ok ->
            ok;
        {ok, {Props}} ->
            DbUri = couch_api_wrap:db_uri(Target),
            ?xdcr_error("Replicator: couldn't write document `~s`, revision `~s`,"
                        " to target database `~s`. Error: `~s`, reason: `~200s`.",
                        [get_value(<<"id">>, Props, ""), get_value(<<"rev">>, Props, ""), DbUri,
                         get_value(<<"error">>, Props, ""), get_value(<<"reason">>, Props, "")]),
            {failed_write, Props}
    end.


%% ================================================= %%
%% ========= FLUSHING DOCS USING XMEM ============== %%
%% ================================================= %%
-spec flush_docs_xmem(term(), [#dcp_mutation{}]) -> ok | {failed_write, term()}.
flush_docs_xmem(_XMemLoc, []) ->
    ok;
flush_docs_xmem(XMemLoc, MutationsList) ->
    RV = xdc_vbucket_rep_xmem:flush_docs(XMemLoc, MutationsList),

    case RV of
        {ok, NumDocRepd, NumDocRejected} ->
            ?x_trace(flushCounts, [{numSend, NumDocRepd},
                                   {numRejected, NumDocRejected}]),
            ok;
        {error, Msg} ->
            {failed_write, Msg}
    end.

-spec maybe_flush_docs_xmem(any(), #batch{}, #dcp_mutation{},
                            integer(), integer()) -> {#batch{}, integer()}.
maybe_flush_docs_xmem(XMemLoc, Batch, Mutation, BatchSize, BatchItems) ->
    #batch{docs = DocAcc, size = SizeAcc, items = ItemsAcc} = Batch,

    DocSize = case Mutation#dcp_mutation.deleted of
                  true ->
                      0;
                  _ ->
                      iolist_size(Mutation#dcp_mutation.body)
              end,

    SizeAcc2 = SizeAcc + DocSize,
    ItemsAcc2 = ItemsAcc + 1,

    %% if reach the limit in terms of docs, flush them
    case ItemsAcc2 >= BatchItems orelse SizeAcc2 >= BatchSize of
        true ->
            DocsList = [Mutation | DocAcc],
            ok = flush_docs_xmem(XMemLoc, DocsList),
            ?x_trace(flushed, []),
            %% data flushed, return empty batch and size of # of docs flushed
            {#batch{}, SizeAcc2};
        _ ->            %% no data flushed in this turn, return the new batch
            {#batch{docs = [Mutation | DocAcc], size = SizeAcc2, items = ItemsAcc2}, 0}
    end.
