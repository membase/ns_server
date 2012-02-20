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
-include("couch_index_merger.hrl").
-include("couch_view_merger.hrl").
-include("ns_common.hrl").

-export([handle_view_req/3]).
-export([all_docs_db_req/2, view_merge_params/4]).
                                                % For capi_spatial
-export([build_local_simple_specs/4, run_on_subset/2,
         node_vbuckets_dict/1, vbucket_db_name/2]).

-import(couch_util, [
                     get_value/2,
                     get_value/3
                    ]).

-define(RETRY_INTERVAL, 5 * 1000).
-define(RETRY_ATTEMPTS, 20).

design_doc_view(Req, #db{name=BucketName} = Db, DesignName, ViewName, VBuckets) ->
    DDocId = <<"_design/", DesignName/binary>>,
    Specs = build_local_simple_specs(BucketName, DDocId, ViewName, VBuckets),
    MergeParams = view_merge_params(Req, Db, DDocId, ViewName, Specs),
    couch_index_merger:query_index(couch_view_merger, MergeParams, Req).

design_doc_view(Req, Db, DesignName, ViewName) ->
    DDocId = <<"_design/", DesignName/binary>>,
    design_doc_view_loop(Req, Db, DDocId, ViewName, ?RETRY_ATTEMPTS).

design_doc_view_loop(_Req, _Db, _DDocId, _ViewName, 0) ->
    throw({error, inconsistent_state});
design_doc_view_loop(Req, Db, DDocId, ViewName, Attempt) ->
    MergeParams = view_merge_params(Req, Db, DDocId, ViewName),
    try
        couch_index_merger:query_index(couch_view_merger, MergeParams, Req)
    catch
        throw:{error, set_view_outdated} ->
            ?views_debug("Got `set_view_outdated` error. Retrying."),
            timer:sleep(?RETRY_INTERVAL),
            design_doc_view_loop(Req, Db, DDocId, ViewName, Attempt - 1)
    end.

%% @doc Returns a vBucket if it is run on a subset (single vBucket) only, else
%% it returns an atom called "full_set"
-spec run_on_subset(#httpd{}, binary()) ->  non_neg_integer()|full_set.
run_on_subset(#httpd{path_parts=[_, _, DName, _, _]}=Req, Name) ->
    case DName of
        <<"dev_", _/binary>> ->
            case get_value("full_set", (Req#httpd.mochi_req):parse_qs()) =/= "true"
                andalso capi_frontend:run_on_subset(Name) of
                true -> capi_frontend:first_vbucket(Name);
                false -> full_set
            end;
        _ ->
            full_set
    end.

handle_view_req(Req, Db, DDoc) when Db#db.filepath =/= undefined ->
    couch_httpd_view:handle_view_req(Req, Db, DDoc);

handle_view_req(#httpd{method='GET',
                       path_parts=[_, _, DName, _, ViewName]}=Req,
                Db, _DDoc) ->
    do_handle_view_req(Req, Db, DName, ViewName);

handle_view_req(#httpd{method='POST',
                       path_parts=[_, _, DName, _, ViewName]}=Req,
                Db, _DDoc) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    do_handle_view_req(Req, Db, DName, ViewName);

handle_view_req(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "GET,POST,HEAD").

do_handle_view_req(Req, #db{name=DbName} = Db, DDocName, ViewName) ->
    case run_on_subset(Req, DbName) of
        full_set ->
            design_doc_view(Req, Db, DDocName, ViewName);
        VBucket ->
            design_doc_view(Req, Db, DDocName, ViewName, [VBucket])
    end.

all_docs_db_req(#httpd{method='GET'} = Req,
                #db{filepath = undefined} = Db) ->
    case {couch_httpd:qs_json_value(Req, "startkey", nil),
          couch_httpd:qs_json_value(Req, "endkey", nil)} of
        {<<"_design/">>, <<"_design0">>} ->
            capi_frontend:with_subdb(Db, <<"master">>,
                                     fun (RealDb) ->
                                             couch_httpd_db:db_req(Req, RealDb)
                                     end);
        _ ->
            do_capi_all_docs_db_req(Req, Db)
    end;

all_docs_db_req(#httpd{method='POST'} = Req,
                #db{filepath = undefined} = Db) ->
    do_capi_all_docs_db_req(Req, Db);

all_docs_db_req(Req, Db) ->
    couch_httpd_db:db_req(Req, Db).

do_capi_all_docs_db_req(Req, #db{filepath = undefined} = Db) ->
    MergeParams = view_merge_params(Req, Db, nil, <<"_all_docs">>),
    couch_index_merger:query_index(couch_view_merger, MergeParams, Req).

node_vbuckets_dict(BucketName) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(BucketName),
    Map = get_value(map, BucketConfig, []),
    {_, NodeToVBuckets0} =
        lists:foldl(fun ([undefined | _], {Idx, Dict}) ->
                            {Idx + 1, Dict};
                        ([Master | _], {Idx, Dict}) ->
                            {Idx + 1,
                             dict:update(Master,
                                         fun (Vbs) ->
                                                 [Idx | Vbs]
                                         end, [Idx], Dict)}
                    end, {0, dict:new()}, Map),
    dict:map(fun (_Key, Vbs) ->
                     lists:reverse(Vbs)
             end, NodeToVBuckets0).

%% we're handling only the special views in the old way
view_merge_params(Req, #db{name = BucketName} = Db,
                  DDocId, ViewName) when DDocId =:= nil ->
    NodeToVBuckets = node_vbuckets_dict(?b2l(BucketName)),
    Config = ns_config:get(),
    ViewSpecs = dict:fold(
                  fun(Node, VBuckets, Acc) when Node =:= node() ->
                          build_local_simple_specs(BucketName, DDocId,
                                                   ViewName, VBuckets) ++ Acc;
                     (Node, VBuckets, Acc) ->
                          [build_remote_simple_specs(Node, BucketName,
                                                     ViewName, VBuckets, Config) | Acc]
                  end, [], NodeToVBuckets),
    view_merge_params(Req, Db, DDocId, ViewName, ViewSpecs);

view_merge_params(Req, #db{name = BucketName} = Db, DDocId, ViewName) ->
    NodeToVBuckets = node_vbuckets_dict(?b2l(BucketName)),
    Config = ns_config:get(),
    ViewSpecs = dict:fold(
                  fun(Node, VBuckets, Acc) when Node =:= node() ->
                          build_local_specs(Req, BucketName,
                                            DDocId, ViewName, VBuckets) ++ Acc;
                     (Node, VBuckets, Acc) ->
                          [build_remote_specs(Req, Node, BucketName,
                                              DDocId, ViewName, VBuckets, Config) | Acc]
                  end, [], NodeToVBuckets),
    view_merge_params(Req, Db, DDocId, ViewName, ViewSpecs).

view_merge_params(Req, _Db, _DDocId, _ViewName, ViewSpecs) ->
    case Req#httpd.method of
        'GET' ->
            Body = [],
            Keys = validate_keys_param(couch_httpd:qs_json_value(Req, "keys", nil));
        'POST' ->
            {Body} = couch_httpd:json_body_obj(Req),
            Keys = validate_keys_param(get_value(<<"keys">>, Body, nil))
    end,
    MergeParams0 = #index_merge{
      indexes = ViewSpecs,
      extra = #view_merge{
        keys = Keys
       },
      ddoc_revision = auto
     },
    couch_httpd_view_merger:apply_http_config(Req, Body, MergeParams0).


validate_keys_param(nil) ->
    nil;
validate_keys_param(Keys) when is_list(Keys) ->
    Keys;
validate_keys_param(_) ->
    throw({bad_request, "`keys` parameter is not an array."}).


vbucket_db_name(BucketName, VBucket) when is_binary(VBucket) ->
    iolist_to_binary([BucketName, $/, VBucket]);
vbucket_db_name(BucketName, VBucket) ->
    iolist_to_binary([BucketName, $/, integer_to_list(VBucket)]).

use_set_views(Req) ->
    get_value("superstar", (Req#httpd.mochi_req):parse_qs(), "true") =:= "true".

build_local_specs(Req, BucketName, DDocId, ViewName, VBuckets) ->
    case use_set_views(Req) of
        true ->
            build_local_set_specs(BucketName, DDocId, ViewName, VBuckets);
        false ->
            build_local_simple_specs(BucketName, DDocId, ViewName, VBuckets)
    end.

build_remote_specs(Req, Node, BucketName, DDocId, ViewName, VBuckets, Config) ->
    case use_set_views(Req) of
        true ->
            FullViewName = iolist_to_binary([DDocId, $/, ViewName]),
            build_remote_set_specs(Node, BucketName,
                                   FullViewName, VBuckets, Config);
        false ->
            FullViewName = iolist_to_binary([BucketName, "%2F", "master", $/,
                                             DDocId, $/, ViewName]),
            build_remote_simple_specs(Node, BucketName,
                                      FullViewName, VBuckets, Config)
    end.

build_local_set_specs(BucketName, DDocId, ViewName, VBuckets) ->
    [#set_view_spec{
        name = BucketName,
        ddoc_id = DDocId,
        view_name = ViewName,
        partitions = VBuckets
       }].

build_remote_set_specs(Node, BucketName, FullViewName, VBuckets, Config) ->
    MergeURL = iolist_to_binary(capi_utils:capi_url(Node, "/_view_merge",
                                                    "127.0.0.1", Config)),

    Sets = {[
             {BucketName, {[{<<"view">>, FullViewName},
                            {<<"partitions">>, VBuckets}]}}
            ]},

    Props = {[
              {<<"views">>,
               {[{<<"sets">>, Sets}]}}
             ]},
    #merged_index_spec{url = MergeURL, ejson_spec = Props}.

build_local_simple_specs(BucketName, DDocId, ViewName, VBuckets) ->
    DDocDbName = iolist_to_binary([BucketName, $/, "master"]),
    lists:map(fun(VBucket) ->
                      #simple_index_spec{
                   database = vbucket_db_name(BucketName, VBucket),
                   ddoc_database = DDocDbName,
                   ddoc_id = DDocId,
                   index_name = ViewName
                  }
              end, [<<"master">> | VBuckets]).

build_remote_simple_specs(Node, BucketName, FullViewName, VBuckets, Config) ->
    MergeURL = iolist_to_binary(capi_utils:capi_url(Node, "/_view_merge", "127.0.0.1", Config)),
    Props = {[
              {<<"views">>,
               {[{vbucket_db_name(BucketName, VBId), FullViewName} || VBId <- VBuckets]}}
             ]},
    #merged_index_spec{url = MergeURL, ejson_spec = Props}.
