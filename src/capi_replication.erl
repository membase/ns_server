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

    make_return_tuple({ok, Errors}).

%% helper functions
is_missing_rev(Bucket, VBucket, Id, RemoteMeta) ->
    case capi_utils:get_meta(Bucket, VBucket, Id) of
        {error, enoent, _CAS} ->
            true;
        {error, not_my_vbucket} ->
            throw({bad_request, not_my_vbucket});
        {ok, LocalMeta, _Deleted, _Props} ->
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
        case capi_utils:get_meta(Bucket, VBucket, DocId) of
            {error, enoent, CAS} ->
                case DocDeleted of
                    true ->
                        do_delete_with_meta(Bucket, DocId, VBucket, DocRev,
                                            CAS);
                    false ->
                        do_set_with_meta(Bucket, DocId, VBucket, DocValue,
                                         DocRev, CAS)
                end;
            {error, not_my_vbucket} ->
                {error, {bad_request, not_my_vbucket}};
            {ok, {OurSeqNo, OurRevId}, Deleted, Props} ->
                RemoteMeta = {DocSeqNo, not(DocDeleted), DocRevId},
                LocalMeta = {OurSeqNo, not(Deleted), OurRevId},

                case max(LocalMeta, RemoteMeta) of
                    %% if equal, prefer LocalMeta since in this case, no need
                    %% to replicate the remote item, hence put LocalMeta before
                    %% RemoteMeta.
                    LocalMeta ->
                        ok;
                    %% if remoteMeta wins, need to persist the remote item, using
                    %% the same CAS returned from the get_meta() above.
                    RemoteMeta ->
                        {cas, CAS} = lists:keyfind(cas, 1, Props),
                        case DocDeleted of
                            true ->
                                do_delete_with_meta(Bucket, DocId, VBucket,
                                                    DocRev, CAS);
                            false ->
                                do_set_with_meta(Bucket, DocId, VBucket,
                                                 DocValue, DocRev, CAS)
                        end
                end
        end,

    case RV of
        retry ->
            do_update_replicated_doc_loop(Bucket, VBucket, Doc);
        _Other ->
            RV
    end.

%% In case of one or more errors, just return the first one. Otherwise,
%% return ok. Also notice that in case of error, we return {ok, Error}. This is
%% per the Couch's update_docs() semantics.
make_return_tuple({ok, Errors}) ->
    case Errors of
        [] ->
            ok;
        [Error | _] ->
            {ok, Error}
    end.


%% ep_engine operation functions
do_set_with_meta(Bucket, DocId, VBucket, DocValue, DocRev, CAS) ->
    case ns_memcached:set_with_meta(Bucket, DocId,
                                    VBucket, DocValue,
                                    {revid, DocRev}, CAS) of
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

do_delete_with_meta(Bucket, DocId, VBucket, DocRev, CAS) ->
    case ns_memcached:delete_with_meta(Bucket, DocId, VBucket, {revid, DocRev},
                                       CAS) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_enoent, _} ->
            retry;
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            {error, {bad_request, einval}}
    end.

