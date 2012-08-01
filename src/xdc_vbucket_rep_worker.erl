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
                             erlang:put(last_stats_report, os:timestamp()),
                             queue_fetch_loop(Source, Target, Cp, Cp, ChangesManager)
                     end),
    ?xdcr_debug("create queue_fetch_loop process (pid: ~p) within replicator (pid: ~p) "
                "Source: ~p, Target: ~p, ChangesManager: ~p",
                [Pid, Cp, Source#db.name, Target#httpdb.url, ChangesManager]),

    {ok, Pid}.

queue_fetch_loop(Source, Target, Parent, Cp, ChangesManager) ->
    ?xdcr_debug("fetch changes from changes manager at ~p (target: ~p)",
               [ChangesManager, Target#httpdb.url]),
    ChangesManager ! {get_changes, self()},
    receive
        {closed, ChangesManager} ->
            ok;
        {changes, ChangesManager, Changes, ReportSeq} ->
            Target2 = open_db(Target),
            {IdRevs, Stats0} = find_missing(Changes, Target2),
            Source2 = open_db(Source),
            Stats = local_process_batch(
                      IdRevs, Cp, Source2, Target2, #batch{}, Stats0),
            close_db(Source2),
            close_db(Target2),
            ok = gen_server:call(Cp, {report_seq_done, ReportSeq, Stats}, infinity),
            erlang:put(last_stats_report, os:timestamp()),
            ?xdcr_debug("Worker reported completion of seq ~p", [ReportSeq]),
            queue_fetch_loop(Source, Target, Parent, Cp, ChangesManager)
    end.

local_process_batch([], _Cp, _Src, _Tgt, #batch{docs = []}, Stats) ->
    Stats;
local_process_batch([], Cp, #db{} = Source, #httpdb{} = Target,
                    #batch{docs = Docs, size = Size}, Stats) ->
    ?xdcr_debug("worker process flushing a batch docs of total size ~p bytes",
                [Size]),
    Stats2 = flush_docs(Target, Docs),
    Stats3 = xdc_rep_utils:sum_stats(Stats, Stats2),
    local_process_batch([], Cp, Source, Target, #batch{}, Stats3);
local_process_batch([IdRevs | Rest], Cp, #db{} = Source,
                    #httpdb{} = Target, Batch, Stats) ->
    {ok, {_, DocList, Stats2, _}} = fetch_doc(
                                      Source, IdRevs, fun local_doc_handler/2,
                                      {Target, [], Stats, Cp}),
    {Batch2, Stats3} = lists:foldl(
                         fun(Doc, {Batch0, Stats0}) ->
                                 {Batch1, S} = maybe_flush_docs(Target, Batch0, Doc),
                                 {Batch1, xdc_rep_utils:sum_stats(Stats0, S)}
                         end,
                         {Batch, Stats2}, DocList),
    local_process_batch(Rest, Cp, Source, Target, Batch2, Stats3).

fetch_doc(Source, {Id, _Rev}, DocHandler, Acc) ->
    couch_api_wrap:open_doc(
      Source, Id, [deleted], DocHandler, Acc).


local_doc_handler({ok, Doc}, {Target, DocList, Stats, Cp}) ->
    Stats2 = ?inc_stat(#rep_stats.docs_read, Stats, 1),
    {ok, {Target, [Doc | DocList], Stats2, Cp}};
local_doc_handler(_, Acc) ->
    {ok, Acc}.

maybe_flush_docs(#httpdb{} = Target, Batch, Doc) ->
    #batch{docs = DocAcc, size = SizeAcc} = Batch,
    JsonDoc = couch_doc:to_json_bin(Doc),
    case SizeAcc + iolist_size(JsonDoc) of
        SizeAcc2 when SizeAcc2 > ?DOC_BUFFER_BYTE_SIZE ->
            ?xdcr_debug("Worker flushing doc batch of size ~p bytes "
                        "(batch limit: ~p)", [SizeAcc2, ?DOC_BUFFER_BYTE_SIZE]),
            Stats = flush_docs(Target, [JsonDoc | DocAcc]),
            {#batch{}, Stats};
        SizeAcc2 ->
            {#batch{docs = [JsonDoc | DocAcc], size = SizeAcc2}, #rep_stats{}}
    end.

flush_docs(_Target, []) ->
    #rep_stats{};
flush_docs(Target, DocList) ->
    case couch_api_wrap:update_docs(Target, DocList, [delay_commit],
                                    replicated_changes) of
        ok ->
            #rep_stats{docs_written = length(DocList)};
        {ok, {Props}} ->
            DbUri = couch_api_wrap:db_uri(Target),
            ?xdcr_error("Replicator: couldn't write document `~s`, revision `~s`,"
                        " to target database `~s`. Error: `~s`, reason: `~200s`.",
                        [get_value(<<"id">>, Props, ""), get_value(<<"rev">>, Props, ""), DbUri,
                         get_value(<<"error">>, Props, ""), get_value(<<"reason">>, Props, "")]),
            #rep_stats{
                        docs_written = 0, doc_write_failures = length(DocList)
                      }
    end.

find_missing(DocInfos, Target) ->
    {IdRevs, AllRevsCount} = lists:foldr(
                               fun(#doc_info{id = Id, rev = Rev}, {IdRevAcc, CountAcc}) ->
                                       {[{Id, Rev} | IdRevAcc], CountAcc + 1}
                               end,
                               {[], 0}, DocInfos),
    {ok, Missing} = couch_api_wrap:get_missing_revs(Target, IdRevs),

    MissingRevsCount = length(Missing),
    Stats = #rep_stats{
      missing_checked = AllRevsCount,
      missing_found = MissingRevsCount
     },

    ?xdcr_debug("after conflict resolution at target (~p), out of all ~p docs "
                "the number of docs we need to replicate is: ~p",
                [Target#httpdb.url, AllRevsCount, MissingRevsCount]),
    {Missing, Stats}.

open_db(#db{name = Name, user_ctx = UserCtx, options = Options}) ->
    {ok, Db} = couch_db:open(Name, [{user_ctx, UserCtx} | Options]),
    Db;
open_db(HttpDb) ->
    HttpDb.

close_db(#db{} = Db) ->
    couch_db:close(Db);
close_db(_HttpDb) ->
    ok.
