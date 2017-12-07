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

-export([get/3, set/3, set/4, delete/2]).

-export([is_valid_json/1]).

%% TODO: handle tmp failures here. E.g. during warmup
handle_mutation_rv(#mc_header{status = ?SUCCESS} = _Header, _Entry) ->
    ok;
handle_mutation_rv(#mc_header{status = ?EINVAL} = _Header, Entry) ->
    {error, Entry#mc_entry.data};
handle_mutation_rv(#mc_header{status = ?NOT_MY_VBUCKET} = _Header, _Entry) ->
    throw(not_my_vbucket).

%% Retaining the old API for backward compatibility.
set(BucketBin, DocId, Value) ->
    set(BucketBin, DocId, Value, 0).

set(BucketBin, DocId, Value, Flags) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),
    {ok, Header, Entry, _} = ns_memcached:set(Bucket, DocId, VBucket, Value, Flags),
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
            throw(not_my_vbucket);
        ?EINVAL ->
            {error, Entry#mc_entry.data}
    end.

continue_get(Bucket, DocId, VBucket, Entry, RetriesLeft) ->
    case ns_memcached:get_meta(Bucket, DocId, VBucket) of
        {ok, Rev, NowCAS, MetaFlags} ->
            case NowCAS =:= Entry#mc_entry.cas of
                true ->
                    %% GET above could only 'see' live item
                    0 = (MetaFlags band ?GET_META_ITEM_DELETED_FLAG),
                    Value = Entry#mc_entry.data,
                    ContentMeta = case is_valid_json(Value) of
                                      true -> ?CONTENT_META_JSON;
                                      false -> ?CONTENT_META_INVALID_JSON
                                  end,
                    {ok, #doc{id = DocId, body = Value, rev = Rev,
                              content_meta = ContentMeta}};
                false ->
                    get_inner(Bucket, DocId, VBucket, RetriesLeft-1)
            end;
        _ ->
            get_inner(Bucket, DocId, VBucket, RetriesLeft-1)
    end.


-spec is_valid_json(Data :: binary()) -> boolean().
is_valid_json(<<>>) ->
    false;
is_valid_json(Data) ->
    %% Docs should accept any JSON value, not just objs and arrays
    %% (this would be anything that is acceptable as a value in an array)
    case ejson:validate([<<"[">>, Data, <<"]">>]) of
        ok -> true;
        _ -> false
    end.
