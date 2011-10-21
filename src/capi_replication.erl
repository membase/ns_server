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

-include("couch_db.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

get_missing_revs(#db{name = BucketBin}, JsonDocIdRevs) ->
    Bucket = binary_to_list(BucketBin),

    Results =
        lists:foldr(
          fun ({Id, [Rev]}, Acc) ->
                  {VBucket, _Node} = cb_util:vbucket_from_id(Bucket, Id),

                  case ns_memcached:get_meta(Bucket, Id, VBucket) of
                      {memcached_error, key_enoent, _} ->
                          [{Id, [Rev], []} | Acc];
                      {memcached_error, not_my_vbucket, _} ->
                          throw({bad_request, not_my_vbucket});
                      {ok, _, _, {revid, OurRev}} ->
                          case winner(Rev, OurRev) of
                              ours ->
                                  Acc;
                              theirs ->
                                  [{Id, [Rev], []} | Acc]
                          end
                  end;
              (_, _) ->
                  throw(unsupported)
          end, [], JsonDocIdRevs),
    {ok, Results}.

update_replicated_docs(#db{name = BucketBin}, Docs, Options) ->
    Bucket = binary_to_list(BucketBin),

    case proplists:get_value(all_or_nothing, Options, false) of
        true ->
            throw(unsupported);
        false ->
            ok
    end,

    Errors =
        lists:foldr(
          fun (#doc{id = Id, revs = {Pos, [RevId | _]}} = Doc, ErrorsAcc) ->
                  case update_replicated_doc(Bucket, Doc) of
                      ok ->
                          ErrorsAcc;
                      {error, Error} ->
                          Rev = {Pos, RevId},
                          [{{Id, Rev}, Error} | ErrorsAcc]
                  end
          end,
          [], Docs),

    {ok, Errors}.


winner({_SeqNo1, _RevId1} = Theirs,
       {_SeqNo2, _RevId2} = Ours) ->
    winner_helper(Theirs, Ours);
winner({_SeqNo1, _NotDeleted1, _RevId1} = Theirs,
       {_SeqNo2, _NotDeleted2, _RevId3} = Ours) ->
    winner_helper(Theirs, Ours).

winner_helper(Theirs, Ours) ->
    %% Ours can be equal to Theirs; in this case we prefer our revision to
    %% avoid excessive work
    case max(Theirs, Ours) of
        Ours ->
            ours;
        Theirs ->
            theirs
    end.

update_replicated_doc(Bucket,
                      #doc{id = Id, revs = {Pos, [RevId | _]},
                           body = Body, deleted = Deleted} = _Doc) ->
    {VBucket, _Node} = cb_util:vbucket_from_id(Bucket, Id),
    Json = ?JSON_ENCODE(Body),
    Rev = {Pos, RevId},
    update_replicated_doc_loop(Bucket, VBucket, Id, Rev, Json, Deleted).

update_replicated_doc_loop(Bucket, VBucket, DocId,
                           {DocSeqNo, DocRevId} = DocRev, DocJson, DocDeleted) ->
    RV =
        case ns_memcached:get_meta(Bucket, DocId, VBucket) of
            {memcached_error, key_enoent, _} ->
                case DocDeleted of
                    true ->
                        ok;
                    false ->
                        do_add_with_meta(Bucket, DocId, VBucket, DocJson, DocRev)
                end;
            {memcached_error, not_my_vbucket, _} ->
                {error, {bad_request, not_my_vbucket}};
            {ok, _, #mc_entry{cas = CAS}, {revid, {OurSeqNo, OurRevId}}} ->
                DocRevExt = {DocSeqNo, not(DocDeleted), DocRevId},
                OurRevExt = {OurSeqNo, true, OurRevId},
                case winner(DocRevExt, OurRevExt) of
                    ours ->
                        ok;
                    theirs ->
                        case DocDeleted of
                            true ->
                                do_delete(Bucket, DocId, VBucket, CAS);
                            false ->
                                do_set_with_meta(Bucket, DocId, VBucket,
                                                 DocJson, DocRev, CAS)
                        end
                end
        end,

    case RV of
        retry ->
            update_replicated_doc_loop(Bucket, VBucket, DocId,
                                       DocRev, DocJson, DocDeleted);
        _Other ->
            RV
    end.

do_add_with_meta(Bucket, DocId, VBucket, DocJson, DocRev) ->
    case ns_memcached:add_with_meta(Bucket, DocId, VBucket,
                                    DocJson, {revid, DocRev}) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_eexists, _} ->
            retry;
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            %% this is most likely an invalid revision
            {error, {bad_request, einval}}
    end.

do_set_with_meta(Bucket, DocId, VBucket, DocJson, DocRev, CAS) ->
    case ns_memcached:set_with_meta(Bucket, DocId,
                                    VBucket, DocJson,
                                    {revid, DocRev}, CAS) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_eexists, _} ->
            retry;
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            {error, {bad_request, einval}}
    end.

do_delete(Bucket, DocId, VBucket, CAS) ->
    {ok, Header, _Entry, _NCB} =
        ns_memcached:delete(Bucket, DocId, VBucket, CAS),
    Status = Header#mc_header.status,
    case Status of
        ?SUCCESS ->
            ok;
        ?KEY_ENOENT ->
            retry;
        ?NOT_MY_VBUCKET ->
            {error, {bad_request, not_my_vbucket}};
        ?EINVAL ->
            {error, {bad_request, einval}}
    end.
