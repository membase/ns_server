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

%% public functions
get_missing_revs(#db{name = DbName}, JsonDocIdRevs) ->
    {Bucket, VBucket} = capi_utils:split_dbname(DbName),
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
    ?xdcr_debug("after conflict resolution for ~p docs, num of remote winners is ~p and "
                "number of local winners is ~p.",
                [NumCandidates, RemoteWinners, (NumCandidates-RemoteWinners)]),
    {ok, Results}.

update_replicated_docs(#db{name = DbName}, Docs, Options) ->
    {Bucket, VBucket} = capi_utils:split_dbname(DbName),

    case proplists:get_value(all_or_nothing, Options, false) of
        true ->
            throw(unsupported);
        false ->
            ok
    end,

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

    case Errors of
        [] ->
            ok;
        [FirstError | _] ->
            %% for some reason we can only return one error. Thus
            %% we're logging everything else here
            ?xdcr_error("could not update docs:~n~p", [Errors]),
            {ok, FirstError}
    end.

%% helper functions
is_missing_rev(Bucket, VBucket, Id, RemoteMeta) ->
    case get_meta(Bucket, VBucket, Id) of
        {memcached_error, key_enoent, _CAS} ->
            true;
        {memcached_error, not_my_vbucket, _} ->
            throw({bad_request, not_my_vbucket});
        {ok, LocalMeta, _Deleted, _CAS} ->
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

do_update_replicated_doc_loop(Bucket, VBucket,
                              #doc{id = DocId, rev = DocRev,
                                   body = DocValue, deleted = DocDeleted} = Doc) ->
    {DocSeqNo, DocRevId} = DocRev,
    RV =
        case get_meta(Bucket, VBucket, DocId) of
            {memcached_error, key_enoent, CAS} ->
                update_locally(Bucket, DocId, VBucket, DocValue, DocRev, DocDeleted, CAS);
            {memcached_error, not_my_vbucket, _} ->
                {error, {bad_request, not_my_vbucket}};
            {ok, {OurSeqNo, OurRevId}, _Deleted, LocalCAS} ->
                RemoteFullMeta = {DocSeqNo, DocRevId},
                LocalFullMeta = {OurSeqNo, OurRevId},
                case max(LocalFullMeta, RemoteFullMeta) of
                    %% if equal, prefer LocalMeta since in this case, no need
                    %% to replicate the remote item, hence put LocalMeta before
                    %% RemoteMeta.
                    LocalFullMeta ->
                        ok;
                    %% if remoteMeta wins, need to persist the remote item, using
                    %% the same CAS returned from the get_meta() above.
                    RemoteFullMeta ->
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

-include("mc_entry.hrl").
-include("mc_constants.hrl").

get_meta(Bucket, VBucket, DocId) ->
    case ns_memcached:get_meta(Bucket, DocId, VBucket) of
        {ok, _Header, #mc_entry{cas=CAS, flag=Flag} = _Entry, {revid, Rev}} ->
            Deleted = ((Flag band ?GET_META_ITEM_DELETED_FLAG) =/= 0),
            {ok, Rev, Deleted, CAS};
        Other ->
            Other
    end.
