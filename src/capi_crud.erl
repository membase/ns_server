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

-module(capi_crud).

-include("couch_db.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

-export([open_doc/3, update_doc/3]).

-spec open_doc(#db{}, binary(), list()) -> any().
open_doc(#db{name = Name, user_ctx = UserCtx}, DocId, Options) ->
    get(Name, DocId, UserCtx, Options).

update_doc(#db{name = Name, user_ctx = UserCtx},
           #doc{id = DocId, rev = Rev, deleted = true},
           _Options) ->
    delete(Name, DocId, Rev, UserCtx);

update_doc(#db{name = Name, user_ctx = UserCtx},
           #doc{id = DocId, rev = {0, _}, json = Body, binary = Binary},
           _Options) ->
    add(Name, DocId, Body, Binary, UserCtx);

update_doc(#db{name = Name, user_ctx = UserCtx},
           #doc{id = DocId, rev = Rev,
                json = Body, binary = Binary}, _Options) ->
    set(Name, DocId, Rev, Body, Binary, UserCtx).

-spec cas() -> <<_:64>>.
cas() ->
    crypto:rand_bytes(8).

-spec encode_revid(<<_:64>>, binary(), integer()) -> <<_:128>>.
encode_revid(CAS, Value, Flags) ->
    <<CAS:8/binary, (size(Value)):32/big, Flags:32/big>>.

-spec decode_revid(<<_:128>>) -> {<<_:64>>, integer(), integer()}.
decode_revid(<<CAS:8/binary, Length:32/big, Flags:32/big>>) ->
    {CAS, Length, Flags}.

-spec next_rev(Revision, binary()) -> {Revision, Flags}
  when Revision :: {integer(), <<_:128>>},
       Flags :: integer().
next_rev({SeqNo, RevId} = _Rev, Value) ->
    {_CAS, _Length, Flags} = decode_revid(RevId),
    NewRevId = encode_revid(cas(), Value, Flags),
    {{SeqNo + 1, NewRevId}, Flags}.

next_rev(Rev) ->
    next_rev(Rev, <<>>).

add(BucketBin, DocId, Body, Binary, UserCtx) ->
    Bucket = binary_to_list(BucketBin),
    Value = capi_utils:doc_to_mc_value(Body, Binary),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),

    {Rev, Flags} =
        case get_meta(Bucket, VBucket, DocId, UserCtx) of
            {error, enoent} ->
                RevId = encode_revid(cas(), Value, 0),
                {{1, RevId}, 0};
            {ok, _Rev, false, _Props} ->
                throw(conflict);
            {ok, OldRev, true, _Props} ->
                next_rev(OldRev, Value)
        end,

    Meta = {revid, Rev},

    case ns_memcached:add_with_meta(Bucket, DocId,
                                    VBucket, Value, Meta, Flags, 0) of
        {ok, _, _} ->
            ok;
        {memcached_error, not_my_vbucket, _} ->
            throw(not_my_vbucket);
        {memcached_error, key_eexists, _} ->
            throw(conflict)
    end.

set(BucketBin, DocId, PrevRev, Body, Binary, UserCtx) ->
    Bucket = binary_to_list(BucketBin),
    Value = capi_utils:doc_to_mc_value(Body, Binary),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),

    {Deleted, CAS}
        = case get_meta(Bucket, VBucket, DocId, UserCtx) of
              {error, enoent} ->
                  {true, undefined};
              {ok, PrevRev, Deleted1, Props} ->
                  CAS1 = proplists:get_value(cas, Props),
                  {Deleted1, CAS1};
              {ok, _Rev, _Deleted, _Props} ->
                  throw(conflict)
          end,

    {Rev, Flags} = next_rev(PrevRev, Value),
    Meta = {revid, Rev},

    R =
        case CAS =/= undefined andalso not(Deleted) of
            true ->
                ns_memcached:set_with_meta(Bucket, DocId,
                                           VBucket, Value, Meta, CAS, Flags, 0);
            false ->
                ns_memcached:add_with_meta(Bucket, DocId,
                                           VBucket, Value, Meta, Flags, 0)
        end,
    case R of
        {ok, _, _} ->
            ok;
        {memcached_error, not_my_vbucket, _} ->
            throw(not_my_vbucket);
        {memcached_error, key_eexists, _} ->
            throw(conflict)
    end.

delete(BucketBin, DocId, PrevRev, UserCtx) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),

    case get_meta(Bucket, VBucket, DocId, UserCtx) of
        {error, enoent} ->
            throw({not_found, missing});
        {ok, _Rev, true, _Props} ->
            throw({not_found, deleted});
        {ok, PrevRev, false, Props} ->
            %% this should not fail because we cannot have non-deleted key
            %% only in couchdb
            {cas, CAS} = lists:keyfind(cas, 1, Props),
            {Rev, _Flags} = next_rev(PrevRev),
            Meta = {revid, Rev},
            case ns_memcached:delete_with_meta(Bucket, DocId,
                                               VBucket, Meta, CAS) of
                {ok, _, _} ->
                    ok;
                {memcached_error, not_my_vbucket, _} ->
                    throw(not_my_vbucket);
                {memcached_error, key_enoent, _} ->
                    throw(conflict)
            end;
        {ok, _Rev, false, _Props} ->
            throw(conflict)
    end.

get(BucketBin, DocId, UserCtx, Options) ->
    Bucket = binary_to_list(BucketBin),
    ReturnDeleted = proplists:get_value(deleted, Options, false),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),
    get_loop(Bucket, DocId, UserCtx, ReturnDeleted, VBucket).

get_loop(Bucket, DocId, UserCtx, ReturnDeleted, VBucket) ->
    case get_meta(Bucket, VBucket, DocId, UserCtx) of
        {error, enoent} ->
            {not_found, missing};
        {ok, Rev, true, _Props} ->
            case ReturnDeleted of
                true ->
                    {ok, mk_deleted_doc(DocId, Rev)};
                false ->
                    {not_found, deleted}
            end;
        {ok, Rev, false, Props} ->
            {cas, CAS} = lists:keyfind(cas, 1, Props),
            {ok, Header, Entry, _} = ns_memcached:get(Bucket, DocId, VBucket),

            case {Header#mc_header.status, Entry#mc_entry.cas} of
                {?SUCCESS, CAS} ->
                    Value = Entry#mc_entry.data,
                    {ok, mk_doc(DocId, Rev, Value)};
                {?SUCCESS, _CAS} ->
                    get_loop(Bucket, DocId, UserCtx, ReturnDeleted, VBucket);
                {?KEY_ENOENT, _} ->
                    get_loop(Bucket, DocId, UserCtx, ReturnDeleted, VBucket);
                {?NOT_MY_VBUCKET, _} ->
                    throw(not_my_vbucket)
            end
    end.

get_meta(Bucket, VBucket, DocId, UserCtx) ->
    case capi_utils:get_meta(Bucket, VBucket, DocId, UserCtx) of
        {error, not_my_vbucket} ->
            throw(not_my_vbucket);
        Other ->
            Other
    end.

mk_deleted_doc(DocId, Rev) ->
    #doc{id = DocId, rev = Rev, deleted = true}.

mk_doc(DocId, Rev, RawValue) ->
    DocTemplate = #doc{id = DocId, rev = Rev},

    try
        Json = json_decode(RawValue),
        DocTemplate#doc{json=Json}
    catch
        {invalid_json, _} ->
            DocTemplate#doc{binary=RawValue}
    end.

%% decode a json and ensure that the result is an object; otherwise throw
%% invalid_json exception
json_decode(RawValue) ->
    case jsonish(RawValue) of
        true ->
            case ?JSON_DECODE(RawValue) of
                {_} = Json ->
                    Json;
                _ ->
                    throw({invalid_json, not_an_object})
            end;
        false ->
            throw({invalid_json, not_jsonish})
    end.

jsonish(<<"{", _/binary>>) ->
    true;
jsonish(<<" ", _/binary>>) ->
    true;
jsonish(<<"\r", _/binary>>) ->
    true;
jsonish(<<"\n", _/binary>>) ->
    true;
jsonish(_) -> false.
