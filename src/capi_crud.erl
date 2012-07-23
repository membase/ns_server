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
open_doc(#db{name = Name}, DocId, Options) ->
    get(Name, DocId, Options).

update_doc(#db{name = Name}, #doc{id = DocId, deleted = true}, _Options) ->
    delete(Name, DocId);

update_doc(#db{name = Name}, #doc{id = DocId, body = Body}, _Options) ->
    set(Name, DocId, Body).

set(BucketBin, DocId, Value) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),
    case ns_memcached:set(Bucket, DocId, VBucket, Value) of
        {ok, _, _, _} ->
            ok;
        {memcached_error, not_my_vbucket, _} ->
            throw(not_my_vbucket);
        {memcached_error, key_eexists, _} ->
            throw(conflict)
    end.

delete(BucketBin, DocId) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),
    case ns_memcached:delete(Bucket, DocId, VBucket) of
        {ok, _, _, _} ->
            ok;
        {memcached_error, not_my_vbucket, _} ->
            throw(not_my_vbucket);
        {memcached_error, key_eexists, _} ->
            throw(conflict)
    end.

get(BucketBin, DocId, _Options) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),
    {ok, Header, Entry, _} = ns_memcached:get(Bucket, DocId, VBucket),

    case {Header#mc_header.status, Entry#mc_entry.cas} of
        {?SUCCESS, _CAS} ->
            Doc = mk_doc(DocId,
                         0,
                         0,
                         Entry#mc_entry.data,
                         true),
            {ok, Doc};
        {?KEY_ENOENT, _} ->
            {not_found, missing};
        {?NOT_MY_VBUCKET, _} ->
            throw(not_my_vbucket)
    end.

%% copied from mc_couch_kv

-spec mk_doc(Key :: binary(),
             Flags :: non_neg_integer(),
             Expiration :: non_neg_integer(),
             Value :: binary(),
             WantJson :: boolean()) -> #doc{}.
mk_doc(Key, Flags, Expiration, Value, WantJson) ->
    Doc = couch_doc:from_binary(Key, Value, WantJson),
    Doc#doc{rev = {1, <<0:64, Expiration:32, Flags:32>>}}.
