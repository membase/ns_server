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
-include_lib("couch_index_merger/include/couch_view_merger.hrl").
-include("ns_common.hrl").
-include("ns_stats.hrl").                       % used for run_on_subset_according_to_stats/1

-export([handle_view_req/3]).
-export([all_docs_db_req/2, view_merge_params/4, run_on_subset_according_to_stats/1]).
%% For capi_spatial
-export([build_local_simple_specs/4, run_on_subset/2,
         vbucket_db_name/2, when_has_active_vbuckets/3]).

-import(couch_util, [
                     get_value/2,
                     get_value/3
                    ]).

-define(RETRY_INTERVAL, 5 * 1000).
-define(RETRY_ATTEMPTS, 20).

subset_design_doc_view(Req, #db{name=BucketName}, DesignName, ViewName,
                       [VBucket]) ->
    DDocId = <<"_design/", DesignName/binary>>,
    [Spec] = build_local_set_specs(BucketName, DDocId, ViewName, [VBucket]),
    Specs = [Spec#set_view_spec{category = dev}],
    MergeParams = finalize_view_merge_params(Req, Specs),
    set_active_partition(DDocId, BucketName, VBucket),
    couch_index_merger:query_index(couch_view_merger, MergeParams, Req).


full_design_doc_view(Req, Db, DesignName, ViewName, VBucketsDict) ->
    DDocId = <<"_design/", DesignName/binary>>,
    design_doc_view_loop(Req, Db, DDocId, ViewName, VBucketsDict, ?RETRY_ATTEMPTS).

design_doc_view_loop(_Req, _Db, _DDocId, _ViewName, _, 0) ->
    throw({error, inconsistent_state});
design_doc_view_loop(Req, Db, DDocId, ViewName, VBucketsDict, Attempt) ->
    MergeParams = view_merge_params(Req, Db, DDocId, ViewName, VBucketsDict),
    try
        couch_index_merger:query_index(couch_view_merger, MergeParams, Req)
    catch
        throw:{error, set_view_outdated} ->
            ?views_debug("Got `set_view_outdated` error. Retrying."),
            timer:sleep(?RETRY_INTERVAL),
            NewVBucketsDict = vbucket_map_mirror:node_vbuckets_dict(?b2l(Db#db.name)),
            design_doc_view_loop(Req, Db, DDocId, ViewName, NewVBucketsDict, Attempt - 1)
    end.

%% @doc Returns a vBucket if it is run on a subset (single vBucket) only, else
%% it returns an atom called "full_set"
-spec run_on_subset(#httpd{}, binary()) ->  non_neg_integer()|full_set.
run_on_subset(#httpd{path_parts=[_, _, DName, _, _]}=Req, Name) ->
    case DName of
        <<"dev_", _/binary>> ->
            case get_value("full_set", (Req#httpd.mochi_req):parse_qs()) =/= "true"
                andalso run_on_subset_according_to_stats(Name) of
                true -> capi_frontend:first_vbucket(Name);
                false -> full_set;
                {error, no_stats} -> capi_frontend:first_vbucket(Name)
            end;
        _ ->
            full_set
    end.

-define(DEV_MULTIPLE, 20).

%% Decide whether to run a query on a subset of documents or a full cluster
%% depending on the number of items in the cluster
-spec run_on_subset_according_to_stats(binary()) -> true | false | {error, no_stats}.
run_on_subset_according_to_stats(Bucket) ->
    case catch stats_reader:latest(minute, node(), ?b2l(Bucket), 1) of
        {ok, [Stats|_]} ->
            {ok, Config} = ns_bucket:get_bucket(?b2l(Bucket)),
            NumVBuckets = proplists:get_value(num_vbuckets, Config, []),
            {ok, N} = orddict:find(curr_items_tot, Stats#stat_entry.values),
            N > NumVBuckets * ?DEV_MULTIPLE;
        _Error ->
            {error, no_stats}
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
    VBucketsDict = vbucket_map_mirror:node_vbuckets_dict(binary_to_list(DbName)),
    case dict:find(node(), VBucketsDict) of
        error ->
            send_no_active_vbuckets(Req, DbName);
        _ ->
            case run_on_subset(Req, DbName) of
                full_set ->
                    full_design_doc_view(Req, Db, DDocName, ViewName, VBucketsDict);
                VBucket ->
                    subset_design_doc_view(Req, Db, DDocName, ViewName, [VBucket])
            end
    end.

when_has_active_vbuckets(Req, Bucket, Fn) ->
    case capi_frontend:has_active_vbuckets(Bucket) of
        true ->
            Fn();
        false ->
            send_no_active_vbuckets(Req, Bucket)
    end.

find_node_with_vbuckets(BucketBin) ->
    Bucket = erlang:binary_to_list(BucketBin),
    VBucketsDict = vbucket_map_mirror:node_vbuckets_dict(Bucket),
    Nodes = dict:fetch_keys(VBucketsDict),
    Len = erlang:length(Nodes),
    case Len of
        0 ->
            undefined;
        _ ->
            random:seed(erlang:now()),
            lists:nth(random:uniform(Len), Nodes)
    end.

send_no_active_vbuckets(CouchReq, Bucket0) ->
    Req = CouchReq#httpd.mochi_req,
    Bucket = iolist_to_binary(Bucket0),
    LocalAddr = menelaus_util:local_addr(Req),
    Headers0 = [{"Content-Type", "application/json"} |
                menelaus_util:server_header()],
    RedirectNode = find_node_with_vbuckets(Bucket),
    Headers = case RedirectNode of
                  undefined -> Headers0;
                  _ ->
                      Path = erlang:iolist_to_binary(Req:get(raw_path)),
                      [{"Location", capi_utils:capi_url_bin(RedirectNode, Path, LocalAddr)}
                       | Headers0]
              end,
    Tuple = {302,
             Headers,
             <<"{\"error\":\"no_active_vbuckets\",\"reason\":\"Cannot execute view query since the node has no active vbuckets\"}">>},
    {ok, Req:respond(Tuple)}.

all_docs_db_req(#httpd{method='GET'} = Req,
                #db{filepath = undefined} = Db) ->
    do_capi_all_docs_db_req(Req, Db);

all_docs_db_req(#httpd{method='POST'} = Req,
                #db{filepath = undefined} = Db) ->
    do_capi_all_docs_db_req(Req, Db);

all_docs_db_req(Req, Db) ->
    couch_httpd_db:db_req(Req, Db).

do_capi_all_docs_db_req(Req, #db{filepath = undefined,
                                 name = DbName} = Db) ->
    when_has_active_vbuckets(
      Req, DbName,
      fun () ->
            MergeParams = view_merge_params(Req, Db, nil, <<"_all_docs">>),
            couch_index_merger:query_index(couch_view_merger, MergeParams, Req)
      end).

view_merge_params(Req, #db{name=BucketName} = Db, DDocId, ViewName) ->
    Dict = vbucket_map_mirror:node_vbuckets_dict(binary_to_list(BucketName)),
    view_merge_params(Req, Db, DDocId, ViewName, Dict).

%% we're handling only the special views (_all_docs) in the old way
view_merge_params(Req, #db{name = BucketName},
                  DDocId, ViewName, NodeToVBuckets) when DDocId =:= nil ->
    ViewSpecs = dict:fold(
                  fun(Node, VBuckets, Acc) when Node =:= node() ->
                          build_local_simple_specs(BucketName, DDocId,
                                                   ViewName, VBuckets) ++ Acc;
                     (Node, VBuckets, Acc) ->
                          [build_remote_simple_specs(Node, BucketName,
                                                     ViewName, VBuckets) | Acc]
                  end, [], NodeToVBuckets),
    finalize_view_merge_params(Req, ViewSpecs);

view_merge_params(Req, #db{name = BucketName}, DDocId, ViewName, NodeToVBuckets) ->
    ViewSpecs = dict:fold(
                  fun(Node, VBuckets, Acc) when Node =:= node() ->
                          build_local_set_specs(BucketName,
                                                DDocId, ViewName, VBuckets) ++ Acc;
                     (Node, VBuckets, Acc) ->
                          [build_remote_set_specs(Node, BucketName,
                                                  DDocId, ViewName, VBuckets) | Acc]
                  end, [], NodeToVBuckets),
    finalize_view_merge_params(Req, ViewSpecs).

finalize_view_merge_params(Req, ViewSpecs) ->
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

build_local_set_specs(BucketName, DDocId, ViewName, VBuckets) ->
    [#set_view_spec{
        name = BucketName,
        ddoc_id = DDocId,
        view_name = ViewName,
        partitions = VBuckets
       }].

build_remote_set_specs(Node, BucketName, DDocId, ViewName, VBuckets) ->
    DDocName = case DDocId of
                   <<"_design/", Rest/binary>> ->
                       Rest;
                   _ ->
                       DDocId
               end,
    FullViewName = iolist_to_binary(["_design/", couch_httpd:quote(DDocName),
                                     $/, couch_httpd:quote(ViewName)]),
    MergeURL = iolist_to_binary([vbucket_map_mirror:node_to_inner_capi_base_url(Node),
                                 <<"/_view_merge">>]),

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
    lists:map(
      fun(VBucket) ->
              #simple_index_spec{database = vbucket_db_name(BucketName, VBucket),
                                 ddoc_database = DDocDbName,
                                 ddoc_id = DDocId,
                                 index_name = ViewName}
              end, VBuckets).

build_remote_simple_specs(Node, BucketName, FullViewName, VBuckets) ->
    MergeURL = iolist_to_binary([vbucket_map_mirror:node_to_inner_capi_base_url(Node), <<"/_view_merge">>]),
    Props = {[
              {<<"views">>,
               {[{vbucket_db_name(BucketName, VBId), FullViewName} || VBId <- VBuckets]}}
             ]},
    #merged_index_spec{url = MergeURL, ejson_spec = Props}.


-spec set_active_partition(binary(), binary(), non_neg_integer()) -> ok.
set_active_partition(DDocId, BucketName, VBucket) ->
    try
        couch_set_view_dev:set_active_partition(
            mapreduce_view, BucketName, DDocId, VBucket)
    catch
        throw:{error, view_undefined} ->
            couch_set_view_dev:define_group(
                mapreduce_view, BucketName, DDocId, VBucket)
    end.
