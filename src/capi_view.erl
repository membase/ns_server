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
-include("couch_view_merger.hrl").
-include("ns_common.hrl").

-export([handle_view_req/3]).

design_doc_view(Req, #db{name=BucketName} = _Db, DName, ViewName, Keys) ->
    DDId = <<"_design/", DName/binary>>,
    {ok, BucketConfig} = ns_bucket:get_bucket(binary_to_list(BucketName)),
    Map = proplists:get_value(map, BucketConfig),
    true = is_list(Map),
    {_, NodeToVBuckets} =
        lists:foldl(fun ([Master | _], {Idx, Dict}) ->
                            {Idx+1, dict:append(Master, Idx, Dict)}
                    end, {0, dict:new()}, Map),
    Config = ns_config:get(),
    FullViewName = iolist_to_binary([DDId, $/, ViewName]),
    ViewSpecs = dict:fold(fun (Node, VBuckets, Acc) when Node =:= node() ->
                                  build_local_specs(BucketName, DDId, ViewName, VBuckets)
                                      ++ Acc;
                              (Node, VBuckets, Acc) ->
                                  [build_remote_specs(Node, BucketName, FullViewName, VBuckets, Config)
                                   | Acc]
                          end, [], NodeToVBuckets),
    MergeParams0 = #view_merge{
      views = ViewSpecs,
      keys = Keys
     },
    MergeParams = couch_httpd_view_merger:apply_http_config(Req, [], MergeParams0),
    couch_view_merger:query_view(Req, MergeParams).

vbucket_db_name(BucketName, VBucket) ->
    iolist_to_binary([BucketName, $/, integer_to_list(VBucket)]).

build_local_specs(BucketName, DDId, ViewName, VBuckets) ->
    lists:map(fun (VBucket) ->
                      #simple_view_spec{database = vbucket_db_name(BucketName, VBucket),
                                        ddoc_id = DDId,
                                        view_name = ViewName}
              end, VBuckets).

build_remote_specs(Node, BucketName, FullViewName, VBuckets, Config) ->
    MergeURL = iolist_to_binary(capi_utils:capi_url(Node, "/_view_merge", "127.0.0.1", Config)),
    Props = {[{<<"views">>,
               {[{vbucket_db_name(BucketName, VBId), FullViewName}
                 || VBId <- VBuckets]}}]},
    #merged_view_spec{url = MergeURL,
                      ejson_spec = Props}.

handle_view_req(Req, Db, DDoc) when Db#db.filepath =/= undefined ->
    couch_httpd_view:handle_view_req(Req, Db, DDoc);

handle_view_req(#httpd{method='GET',
        path_parts=[_, _, DName, _, ViewName]}=Req, Db, _DDoc) ->
    Keys = couch_httpd:qs_json_value(Req, "keys", nil),
    design_doc_view(Req, Db, DName, ViewName, Keys);

handle_view_req(#httpd{method='POST',
        path_parts=[_, _, DName, _, ViewName]}=Req, Db, _DDoc) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    {Fields} = couch_httpd:json_body_obj(Req),
    case couch_util:get_value(<<"keys">>, Fields, nil) of
        nil ->
            ?log_info("POST to view ~p/~p in database ~p with no keys member.",
                      [DName, ViewName, Db]),
            design_doc_view(Req, Db, DName, ViewName, nil);
        Keys when is_list(Keys) ->
            design_doc_view(Req, Db, DName, ViewName, Keys);
        _ ->
            throw({bad_request, "`keys` member must be a array."})
    end;

handle_view_req(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "GET,POST,HEAD").
