%% @author Couchbase <info@couchbase.com>
%% @copyright 2011-2017 Couchbase, Inc.
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

-include("ns_common.hrl").
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

get(BucketBin, DocId, Options) ->
    Bucket = binary_to_list(BucketBin),
    {VBucket, _} = cb_util:vbucket_from_id(Bucket, DocId),
    get_inner(Bucket, DocId, VBucket, Options, 10).

get_inner(_Bucket, _DocId, _VBucket, _Options, _RetriesLeft = 0) ->
    erlang:error(cas_retries_exceeded);
get_inner(Bucket, DocId, VBucket, Options, RetriesLeft) ->
    XAttrPermissions = proplists:get_value(xattrs_perm, Options, []),
    {ok, Header, Entry, _} = ns_memcached:get(Bucket, DocId, VBucket),

    case Header#mc_header.status of
        ?SUCCESS ->
            CAS = Entry#mc_entry.cas,
            Value = Entry#mc_entry.data,
            ContentMeta = case is_valid_json(Value) of
                              true -> ?CONTENT_META_JSON;
                              false -> ?CONTENT_META_INVALID_JSON
                          end,
            try
                {ok, Rev, _MetaFlags} = get_meta(Bucket, DocId, VBucket, CAS),
                case cluster_compat_mode:is_cluster_vulcan() of
                    true ->
                        {ok, XAttrsJsonObj} = get_xattrs(Bucket, DocId,
                                                         VBucket, CAS,
                                                         XAttrPermissions),
                        {ok, #doc{id = DocId, body = Value, rev = Rev,
                                  content_meta = ContentMeta},
                         XAttrsJsonObj};
                    false ->
                        {ok, #doc{id = DocId, body = Value, rev = Rev,
                                  content_meta = ContentMeta}}
                end

            catch
                _:_ -> get_inner(Bucket, DocId, VBucket, Options, RetriesLeft-1)
            end;
        ?KEY_ENOENT ->
            {not_found, missing};
        ?NOT_MY_VBUCKET ->
            throw(not_my_vbucket);
        ?EINVAL ->
            {error, Entry#mc_entry.data}
    end.

get_meta(Bucket, DocId, VBucket, CAS) ->
    case ns_memcached:get_meta(Bucket, DocId, VBucket) of
        {ok, Rev, CAS, MetaFlags} -> {ok, Rev, MetaFlags};
        {ok, _, _, _} -> {error, bad_cas};
        _ -> {error, bad_resp}
    end.

get_xattrs(_Bucket, _DocId, _VBucket, _CAS, []) -> {ok, {[]}};
get_xattrs(Bucket, DocId, VBucket, CAS, Permissions) ->
    try
        Keys = try_get_xattr(Bucket, DocId, VBucket, CAS, <<"$XTOC">>),
        AllowedKeys = lists:filter(
                        fun (K) ->
                                check_xattr_read_permission(K, Permissions)
                        end, Keys),
        %% Subdoc_multi_lookup does not support retriving several xattrs
        %% at once
        Res = lists:map(
                fun (K) ->
                        {K, try_get_xattr(Bucket, DocId, VBucket, CAS, K)}
                end, AllowedKeys),
        {ok, {[{<<"xattrs">>, {Res}}]}}
    catch
        _:Reason -> {error, Reason}
    end.

try_get_xattr(Bucket, DocId, VBucket, CAS, Key) ->
    case ns_memcached:subdoc_multi_lookup(Bucket, DocId, VBucket,
                                          [Key], [xattr_path]) of
        {ok, CAS, [JSON]} -> ejson:decode(JSON);
        {ok, _, [_]} -> throw(bad_cas);
        Error ->
            ?log_error("Subdoc multi lookup error: arguments: ~p ~p ~p ~p ~p,"
                       " response: ~p",
                       [Bucket, DocId, VBucket, CAS, Key, Error]),
            throw(bad_subdoc_resp)
    end.

%% X-Keys starting with a leading dollar sign are considered virtual XATTRs
%% and can only be accessed if the client holds the XATTR_READ privilege.
check_xattr_read_permission(<<"$", _binary>>, Permissions) ->
    lists:member(user_read, Permissions);
%% X-Keys starting with a leading underscore are considered system XATTRs
%% and can only be read if the client holds the SYSTEM_XATTR read privilege.
check_xattr_read_permission(<<"_", _/binary>>, Permissions) ->
    lists:member(server_read, Permissions);
%% X-Keys not starting with a leading underscore (and not starting with a
%% reserved symbol) are user XATTRs and may be read by clients with the XATTR_READ
check_xattr_read_permission(_XKey, Permissions) ->
    lists:member(user_read, Permissions).

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
