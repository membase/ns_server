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

-include("ns_common.hrl").
-include("couch_db.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").
-include("ns_config.hrl").

%% returns capi port for given node or undefined if node doesn't have CAPI
compute_capi_port(Node) ->
    ns_config:eval(
      fun (#config{dynamic=[PList]}) ->
              case lists:keyfind({node, Node, capi_port}, 1, PList) of
                  {_, V} ->
                      case V of
                          [{'_vclock', _} | V2] -> V2;
                          _ -> V
                      end;
                  false ->
                      undefined
              end
      end).

get_capi_port(Node, Config) ->
    case ns_config:search(Config, {node, Node, capi_port}) of
        false -> undefined;
        {value, X} -> X
    end.

%% returns http url to capi on given node with given path
-spec capi_url_bin(node(), iolist() | binary(), iolist() | binary()) -> undefined | binary().
capi_url_bin(Node, Path, LocalAddr) ->
    case vbucket_map_mirror:node_to_capi_base_url(Node, LocalAddr) of
        undefined -> undefined;
        X ->
            iolist_to_binary([X, Path])
    end.

capi_bucket_url_bin(Node, BucketName, LocalAddr) ->
    capi_url_bin(Node, menelaus_util:concat_url_path([BucketName]), LocalAddr).

split_dbname(DbName) ->
    DbNameStr = binary_to_list(DbName),
    Tokens = string:tokens(DbNameStr, [$/]),
    build_info(Tokens, []).

build_info([VBucketStr], R) ->
    {lists:append(lists:reverse(R)), list_to_integer(VBucketStr)};
build_info([H|T], R)->
    build_info(T, [H|R]).


-spec build_dbname(BucketName :: ext_bucket_name(), VBucket :: ext_vbucket_id()) -> binary().
build_dbname(BucketName, VBucket) ->
    SubName = case is_binary(VBucket) of
                  true -> VBucket;
                  _ -> integer_to_list(VBucket)
              end,
    iolist_to_binary([BucketName, $/, SubName]).


-spec must_open_vbucket(BucketName :: ext_bucket_name(),
                        VBucket :: ext_vbucket_id()) -> #db{}.
must_open_vbucket(BucketName, VBucket) ->
    DBName = build_dbname(BucketName, VBucket),
    case couch_db:open_int(DBName, []) of
        {ok, RealDb} ->
            RealDb;
        Error ->
            exit({open_db_failed, Error})
    end.

%% copied from mc_couch_vbucket

-spec get_vbucket_state_doc(ext_bucket_name(), vbucket_id()) -> binary() | not_found.
get_vbucket_state_doc(BucketName, VBucket) when is_integer(VBucket) ->
    try must_open_vbucket(BucketName, VBucket) of
        DB ->
            try
                case couch_db:open_doc_int(DB, <<"_local/vbstate">>, [json_bin_body]) of
                    {ok, Doc} ->
                        Doc#doc.body;
                    {not_found, missing} ->
                        not_found
                end
            after
                couch_db:close(DB)
            end
    catch exit:{open_db_failed, {not_found, no_db_file}} ->
            not_found
    end.

couch_json_to_mochi_json({List}) ->
    {struct, couch_json_to_mochi_json(List)};
couch_json_to_mochi_json({K, V}) ->
    {K, couch_json_to_mochi_json(V)};
couch_json_to_mochi_json(List) when is_list(List) ->
    lists:map(fun couch_json_to_mochi_json/1, List);
couch_json_to_mochi_json(Else) -> Else.

couch_doc_to_mochi_json(Doc) ->
    couch_json_to_mochi_json(couch_doc:to_json_obj(Doc, [])).

extract_doc_id(Doc) ->
    Doc#doc.id.
