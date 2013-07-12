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
-module(capi_view).

-include("couch_db.hrl").
-include_lib("couch_index_merger/include/couch_index_merger.hrl").

%% Public API
-export([handle_view_req/3, all_docs_db_req/2]).

%% For capi_spatial
-export([build_local_simple_specs/4]).


handle_view_req(Req, Db, DDoc) when Db#db.filepath =/= undefined ->
    couch_httpd_view:handle_view_req(Req, Db, DDoc);

handle_view_req(#httpd{method='GET',
                       path_parts=[_, _, DName, _, ViewName]}=Req,
                Db, _DDoc) ->
    capi_indexer:do_handle_view_req(mapreduce_view, Req, Db#db.name, DName, ViewName);

handle_view_req(#httpd{method='POST',
                       path_parts=[_, _, DName, _, ViewName]}=Req,
                Db, _DDoc) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    capi_indexer:do_handle_view_req(mapreduce_view, Req, Db#db.name, DName, ViewName);

handle_view_req(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "GET,POST,HEAD").


all_docs_db_req(#httpd{method='GET'} = Req,
                #db{filepath = undefined} = Db) ->
    do_capi_all_docs_db_req(Req, Db);

all_docs_db_req(#httpd{method='POST'} = Req,
                #db{filepath = undefined} = Db) ->
    do_capi_all_docs_db_req(Req, Db);

all_docs_db_req(Req, Db) ->
    couch_httpd_db:db_req(Req, Db).

do_capi_all_docs_db_req(Req, #db{filepath = undefined,
                                 name = DbName}) ->
    capi_indexer:when_has_active_vbuckets(
      Req, DbName,
      fun () ->
            MergeParams = all_docs_merge_params(Req, DbName),
            couch_index_merger:query_index(couch_view_merger, MergeParams, Req)
      end).

%% we're handling only the special views (_all_docs) in the old way
all_docs_merge_params(Req, BucketName) ->
    NodeToVBuckets = vbucket_map_mirror:node_vbuckets_dict(
                       binary_to_list(BucketName)),
    ViewName = <<"_all_docs">>,
    ViewSpecs = dict:fold(
                  fun(Node, VBuckets, Acc) when Node =:= node() ->
                          build_local_simple_specs(BucketName, nil,
                                                   ViewName, VBuckets) ++ Acc;
                     (Node, VBuckets, Acc) ->
                          [build_remote_simple_specs(Node, BucketName,
                                                     ViewName, VBuckets) | Acc]
                  end, [], NodeToVBuckets),
    capi_indexer:finalize_view_merge_params(Req, ViewSpecs).


build_local_simple_specs(BucketName, DDocId, ViewName, VBuckets) ->
    DDocDbName = iolist_to_binary([BucketName, $/, "master"]),
    lists:map(
      fun(VBucket) ->
              #simple_index_spec{
                 database = capi_indexer:vbucket_db_name(BucketName, VBucket),
                 ddoc_database = DDocDbName,
                 ddoc_id = DDocId,
                 index_name = ViewName}
              end, VBuckets).

build_remote_simple_specs(Node, BucketName, FullViewName, VBuckets) ->
    MergeURL = iolist_to_binary([vbucket_map_mirror:node_to_inner_capi_base_url(Node), <<"/_view_merge">>]),
    Props = {[
              {<<"views">>,
               {[{capi_indexer:vbucket_db_name(BucketName, VBId), FullViewName} || VBId <- VBuckets]}}
             ]},
    #merged_index_spec{url = MergeURL, ejson_spec = Props}.
