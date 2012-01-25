%% @author Couchbase, Inc <info@couchbase.com>
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

-module(capi_utils).

-compile(export_all).

-include("couch_db.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

%% returns capi port for given node or undefined if node doesn't have CAPI
capi_port(Node, Config) ->
    case ns_config:search(Config, {node, Node, capi_port}) of
        false -> undefined;
        {value, X} -> X
    end.

%% returns capi port for given node or undefined if node doesn't have CAPI
capi_port(Node) ->
    capi_port(Node, ns_config:get()).

%% returns http url to capi on given node with given path
capi_url(Node, Path, LocalAddr, Config) ->
    CapiPort = capi_port(Node, Config),
    case CapiPort of
        undefined -> undefined;
        _ ->
            Host = case misc:node_name_host(Node) of
                       {_, "127.0.0.1"} -> LocalAddr;
                       {_Name, H} -> H
                   end,
            lists:append(["http://",
                          Host,
                          ":",
                          integer_to_list(CapiPort),
                          Path])
    end.

capi_url(Node, Path, LocalAddr) ->
    capi_url(Node, Path, LocalAddr, ns_config:get()).

capi_bucket_url(Node, BucketName, LocalAddr, Config) ->
    capi_url(Node, menelaus_util:concat_url_path([BucketName]), LocalAddr, Config).

capi_bucket_url(Node, BucketName, LocalAddr) ->
    capi_bucket_url(Node, BucketName, LocalAddr, ns_config:get()).

get_meta(Bucket, VBucket, DocId) ->
    case ns_memcached:get_meta(Bucket, DocId, VBucket) of
        {ok, _Header, #mc_entry{cas=CAS, flag=Flag} = _Entry, {revid, Rev}} ->
            case (Flag band ?GET_META_ITEM_DELETED_FLAG) of
                ?GET_META_ITEM_DELETED_FLAG ->
                    {ok, Rev, true, [{cas, CAS}, ep_engine]};
                _ ->
                    {ok, Rev, false, [{cas, CAS}, ep_engine]}
            end;
        {memcached_error, not_my_vbucket, _} ->
            {error, not_my_vbucket};
        {memcached_error, key_enoent, CAS} ->
            {error, enoent, CAS}
    end.

split_dbname(DbName) ->
    DbNameStr = binary_to_list(DbName),
    Tokens = string:tokens(DbNameStr, [$/]),
    build_info(Tokens, []).

build_info([VBucketStr], R) ->
    {lists:append(lists:reverse(R)), list_to_integer(VBucketStr)};
build_info([H|T], R)->
    build_info(T, [H|R]).
