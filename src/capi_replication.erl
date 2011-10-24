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

-export([get_missing_revs/2, update_replicated_docs/3, update_replicated_doc/3]).

-include("couch_db.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

get_missing_revs(#db{name = BucketBin, user_ctx = UserCtx}, JsonDocIdRevs) ->
    Bucket = binary_to_list(BucketBin),

    Results =
        lists:foldr(
          fun ({Id, [Rev]}, Acc) ->
                  {VBucket, _Node} = cb_util:vbucket_from_id(Bucket, Id),

                  case capi_utils:get_meta(Bucket, VBucket, Id, UserCtx) of
                      {error, enoent} ->
                          [{Id, [Rev], []} | Acc];
                      {error, not_my_vbucket} ->
                          throw({bad_request, not_my_vbucket});
                      {ok, OurRev, _Deleted, _Props} ->
                          %% we do not have any information about deletedness of
                          %% the remote side thus we use only revisions to
                          %% determine a winner
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

update_replicated_docs(#db{name = BucketBin, user_ctx = UserCtx},
                       Docs, Options) ->
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
                  case do_update_replicated_doc(Bucket, UserCtx, Doc) of
                      ok ->
                          ErrorsAcc;
                      {error, Error} ->
                          Rev = {Pos, RevId},
                          [{{Id, Rev}, Error} | ErrorsAcc]
                  end
          end,
          [], Docs),

    {ok, Errors}.

update_replicated_doc(#db{name = BucketBin, user_ctx = UserCtx},
                      #doc{revs = {Pos, [RevId | _]}} = Doc, _Options) ->
    Bucket = binary_to_list(BucketBin),

    case do_update_replicated_doc(Bucket, UserCtx, Doc) of
        ok ->
            {ok, {Pos, RevId}};
        {error, Error} ->
            throw(Error)
    end.

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

do_update_replicated_doc(Bucket, UserCtx,
                         #doc{id = Id, revs = {Pos, [RevId | _]},
                              body = Body0, atts = Atts,
                              deleted = Deleted} = _Doc) ->
    Body = filter_out_mccouch_fields(Body0),
    {VBucket, _Node} = cb_util:vbucket_from_id(Bucket, Id),
    Value = capi_utils:doc_to_mc_value(Body, Atts),
    Rev = {Pos, RevId},
    do_update_replicated_doc_loop(Bucket, UserCtx, VBucket,
                                  Id, Rev, Value, Deleted).

do_update_replicated_doc_loop(Bucket, UserCtx, VBucket, DocId,
                              {DocSeqNo, DocRevId} = DocRev,
                              DocValue, DocDeleted) ->
    RV =
        case capi_utils:get_meta(Bucket, VBucket, DocId, UserCtx) of
            {error, enoent} ->
                case DocDeleted of
                    true ->
                        %% TODO: we must preserve source revision here
                        ok;
                    false ->
                        do_add_with_meta(Bucket, DocId,
                                         VBucket, DocValue, DocRev)
                end;
            {error, not_my_vbucket} ->
                {error, {bad_request, not_my_vbucket}};
            {ok, {OurSeqNo, OurRevId}, Deleted, Props} ->
                DocRevExt = {DocSeqNo, not(DocDeleted), DocRevId},
                OurRevExt = {OurSeqNo, not(Deleted), OurRevId},

                case winner(DocRevExt, OurRevExt) of
                    ours ->
                        ok;
                    theirs ->
                        case DocDeleted of
                            true ->
                                case Deleted of
                                    true ->
                                        %% TODO: we must preserve winning
                                        %% revision here
                                        ok;
                                    false ->
                                        {cas, CAS} = lists:keyfind(cas, 1, Props),
                                        do_delete(Bucket, DocId, VBucket, CAS)
                                end;
                            false ->
                                {cas, CAS} = lists:keyfind(cas, 1, Props),
                                do_set_with_meta(Bucket, DocId, VBucket,
                                                 DocValue, DocRev, CAS)
                        end
                end
        end,

    case RV of
        retry ->
            do_update_replicated_doc_loop(Bucket, UserCtx, VBucket, DocId,
                                          DocRev, DocValue, DocDeleted);
        _Other ->
            RV
    end.

do_add_with_meta(Bucket, DocId, VBucket, DocValue, DocRev) ->
    case ns_memcached:add_with_meta(Bucket, DocId, VBucket,
                                    DocValue, {revid, DocRev}) of
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

do_set_with_meta(Bucket, DocId, VBucket, DocValue, DocRev, CAS) ->
    case ns_memcached:set_with_meta(Bucket, DocId,
                                    VBucket, DocValue,
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

filter_out_mccouch_fields({Props}) ->
    FilteredProps = lists:filter(
                      fun ({<<$$, _/binary>>, _Value}) ->
                              false;
                          ({_, _}) ->
                              true
                      end, Props),
    {FilteredProps}.
