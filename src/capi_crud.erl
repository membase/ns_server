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
-include("ns_common.hrl").

-export([open_doc/3, update_doc/3]).

-spec open_doc(#db{}, binary(), list()) -> any().
open_doc(#db{name = Name}, DocId, Options) ->
    get(Name, DocId, Options).

update_doc(#db{name = Name}, #doc{id = DocId, deleted = true}, _Options) ->
    delete(Name, DocId);

update_doc(#db{name = Name}, #doc{id = DocId, body = Body}, _Options) when is_binary(Body) ->
    set(Name, DocId, Body);

update_doc(#db{name = Name}, #doc{id = DocId}=Doc, _Options) ->
    {Body, _Meta} = couch_doc:to_raw_json_binary_views(Doc),
    set(Name, DocId, Body).

%% TODO: handle tmp failures here. E.g. during warmup
handle_mutation_rv(#mc_header{status = ?SUCCESS} = _Header, _Entry) ->
    ok;
handle_mutation_rv(#mc_header{status = ?NOT_MY_VBUCKET} = _Header, _Entry) ->
    throw(not_my_vbucket).

set(BucketBin, DocId, Value) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),
    {ok, Header, Entry, _} = ns_memcached:set(Bucket, DocId, VBucket, Value),
    handle_mutation_rv(Header, Entry).

delete(BucketBin, DocId) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),
    {ok, Header, Entry, _} = ns_memcached:delete(Bucket, DocId, VBucket),
    handle_mutation_rv(Header, Entry).

get(BucketBin, DocId, _Options) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),
    get_inner(Bucket, DocId, VBucket, 10).

get_inner(_Bucket, _DocId, _VBucket, _RetriesLeft = 0) ->
    erlang:error(cas_retries_exceeded);
get_inner(Bucket, DocId, VBucket, RetriesLeft) ->
    {ok, Header, Entry, _} = ns_memcached:get(Bucket, DocId, VBucket),

    case Header#mc_header.status of
        ?SUCCESS ->
            continue_get(Bucket, DocId, VBucket, Entry, RetriesLeft);
        ?KEY_ENOENT ->
            {not_found, missing};
        ?NOT_MY_VBUCKET ->
            throw(not_my_vbucket)
    end.

continue_get(Bucket, DocId, VBucket, Entry, RetriesLeft) ->
    case ns_memcached:get_meta(Bucket, DocId, VBucket) of
        {ok, Rev, NowCAS, MetaFlags} ->
            case NowCAS =:= Entry#mc_entry.cas of
                true ->
                    %% GET above could only 'see' live item
                    0 = (MetaFlags band ?GET_META_ITEM_DELETED_FLAG),
                    Doc0 = couch_doc:from_binary(DocId, Entry#mc_entry.data, true),
                    {ok, Doc0#doc{rev = Rev}};
                false ->
                    get_inner(Bucket, DocId, VBucket, RetriesLeft-1)
            end;
        _ ->
            get_inner(Bucket, DocId, VBucket, RetriesLeft-1)
    end.
