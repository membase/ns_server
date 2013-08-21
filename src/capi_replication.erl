%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(capi_replication).

-export([get_missing_revs/2, update_replicated_docs/3]).

-include("xdc_replicator.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

-define(SLOW_THRESHOLD_SECONDS, 180).

%% public functions
get_missing_revs(#db{name = DbName}, JsonDocIdRevs) ->
    {Bucket, VBucket} = capi_utils:split_dbname(DbName),
    TimeStart = now(),
    %% enumerate all keys and fetch meta data by getMeta for each of them to ep_engine
    Results =
        lists:foldr(
          fun ({Id, Rev}, Acc) ->
                  case is_missing_rev(Bucket, VBucket, Id, Rev) of
                      false ->
                          Acc;
                      true ->
                          [{Id, Rev} | Acc]
                  end;
              (_, _) ->
                  throw(unsupported)
          end, [], JsonDocIdRevs),

    NumCandidates = length(JsonDocIdRevs),
    RemoteWinners = length(Results),
    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    AvgLatency = TimeSpent div NumCandidates,
    ?xdcr_debug("[Bucket:~p, Vb:~p]: after conflict resolution for ~p docs, num of remote winners is ~p and "
                "number of local winners is ~p. (time spent in ms: ~p, avg latency in ms per doc: ~p)",
                [Bucket, VBucket, NumCandidates, RemoteWinners, (NumCandidates-RemoteWinners),
                 TimeSpent, AvgLatency]),

    %% dump error msg if timeout
    TimeSpentSecs = TimeSpent div 1000,
    case TimeSpentSecs > ?SLOW_THRESHOLD_SECONDS of
        true ->
            ?xdcr_error("[Bucket:~p, Vb:~p]: conflict resolution for ~p docs  takes too long to finish!"
                        "(total time spent: ~p secs)",
                        [Bucket, VBucket, NumCandidates, TimeSpentSecs]);
        _ ->
            ok
    end,

    {ok, Results}.

update_replicated_docs(#db{name = DbName}, Docs, Options) ->
    {Bucket, VBucket} = capi_utils:split_dbname(DbName),

    case proplists:get_value(all_or_nothing, Options, false) of
        true ->
            throw(unsupported);
        false ->
            ok
    end,

    TimeStart = now(),
    %% enumerate all docs and update them
    Errors =
        lists:foldr(
          fun (#doc{id = Id, rev = Rev} = Doc, ErrorsAcc) ->
                  case do_update_replicated_doc_loop(Bucket, VBucket, Doc) of
                      ok ->
                          ErrorsAcc;
                      {error, Error} ->
                          [{{Id, Rev}, Error} | ErrorsAcc]
                  end
          end,
          [], Docs),

    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    AvgLatency = TimeSpent div length(Docs),

    %% dump error msg if timeout
    TimeSpentSecs = TimeSpent div 1000,
    case TimeSpentSecs > ?SLOW_THRESHOLD_SECONDS of
        true ->
            ?xdcr_error("[Bucket:~p, Vb:~p]: update ~p docs takes too long to finish!"
                        "(total time spent: ~p secs)",
                        [Bucket, VBucket, length(Docs), TimeSpentSecs]);
        _ ->
            ok
    end,

    case Errors of
        [] ->
            ?xdcr_debug("[Bucket:~p, Vb:~p]: successfully update ~p replicated mutations "
                        "(time spent in ms: ~p, avg latency per doc in ms: ~p)",
                        [Bucket, VBucket, length(Docs), TimeSpent, AvgLatency]),

            ok;
        [FirstError | _] ->
            %% for some reason we can only return one error. Thus
            %% we're logging everything else here
            ?xdcr_error("[Bucket: ~p, Vb: ~p] Error: could not update docs. Time spent in ms: ~p, "
                        "# of docs trying to update: ~p, error msg: ~n~p",
                        [Bucket, VBucket, TimeSpent, length(Docs), Errors]),
            {ok, FirstError}
    end.

%% helper functions
is_missing_rev(Bucket, VBucket, Id, RemoteMeta) ->
    case get_meta(Bucket, VBucket, Id) of
        {memcached_error, key_enoent, _CAS} ->
            true;
        {memcached_error, not_my_vbucket, _} ->
            throw({bad_request, not_my_vbucket});
        {ok, LocalMeta, _CAS} ->
             %% we do not have any information about deletedness of
             %% the remote side thus we use only revisions to
             %% determine a winner
            case max(LocalMeta, RemoteMeta) of
                %% if equal, prefer LocalMeta since in this case, no need
                %% to replicate the remote item, hence put LocalMeta before
                %% RemoteMeta.
                LocalMeta ->
                    false;
                RemoteMeta ->
                    true
            end
    end.

do_update_replicated_doc_loop(Bucket, VBucket, Doc0) ->
    Doc = #doc{id = DocId, rev = DocRev,
        body = DocValue, deleted = DocDeleted} = couch_doc:with_json_body(Doc0),
    {DocSeqNo, DocRevId} = DocRev,
    RV =
        case get_meta(Bucket, VBucket, DocId) of
            {memcached_error, key_enoent, CAS} ->
                update_locally(Bucket, DocId, VBucket, DocValue, DocRev, DocDeleted, CAS);
            {memcached_error, not_my_vbucket, _} ->
                {error, {bad_request, not_my_vbucket}};
            {ok, {OurSeqNo, OurRevId}, LocalCAS} ->
                {RemoteMeta, LocalMeta} =
                    case DocDeleted of
                        false ->
                            %% for non-del mutation, compare full metadata
                            {{DocSeqNo, DocRevId}, {OurSeqNo, OurRevId}};
                        _ ->
                            %% for deletion, just compare seqno and CAS to match
                            %% the resolution algorithm in ep_engine:deleteWithMeta
                            <<DocCAS:64, _DocExp:32, _DocFlg:32>> = DocRevId,
                            <<OurCAS:64, _OurExp:32, _OurFlg:32>> = OurRevId,
                            {{DocSeqNo, DocCAS}, {OurSeqNo, OurCAS}}
                    end,
                case max(LocalMeta, RemoteMeta) of
                    %% if equal, prefer LocalMeta since in this case, no need
                    %% to replicate the remote item, hence put LocalMeta before
                    %% RemoteMeta.
                    LocalMeta ->
                        ok;
                    %% if remoteMeta wins, need to persist the remote item, using
                    %% the same CAS returned from the get_meta() above.
                    RemoteMeta ->
                        update_locally(Bucket, DocId, VBucket, DocValue, DocRev, DocDeleted, LocalCAS)
                end
        end,

    case RV of
        retry ->
            do_update_replicated_doc_loop(Bucket, VBucket, Doc);
        _Other ->
            RV
    end.

update_locally(Bucket, DocId, VBucket, Value, Rev, DocDeleted, LocalCAS) ->
    case ns_memcached:update_with_rev(Bucket, VBucket, DocId, Value, Rev, DocDeleted, LocalCAS) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_enoent, _} ->
            retry;
        {memcached_error, key_eexists, _} ->
            retry;
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            {error, {bad_request, einval}}
    end.


get_meta(Bucket, VBucket, DocId) ->
    case ns_memcached:get_meta(Bucket, DocId, VBucket) of
        {ok, Rev, CAS, _MetaFlags} ->
            {ok, Rev, CAS};
        Other ->
            Other
    end.
