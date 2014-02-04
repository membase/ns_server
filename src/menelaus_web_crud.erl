%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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
-module(menelaus_web_crud).

-include("ns_common.hrl").
-include("couch_db.hrl").

-export([handle_list/2,
         handle_get/3,
         handle_post/3,
         handle_delete/3]).


handle_list(BucketId, Req) ->
    {_, QueryString, _} = mochiweb_util:urlsplit_path(Req:get(raw_path)),
    BasePath = "/" ++ BucketId ++ "/_all_docs",
    Path = case QueryString of
               "" ->
                   BasePath;
               _ ->
                   BasePath ++ "?" ++ QueryString
           end,

    DefaultSpec = "{couch_httpd_db, handle_request}",
    DefaultFun = couch_httpd:make_arity_1_fun(
                   couch_config:get("httpd", "default_handler", DefaultSpec)
                  ),

    UrlHandlersList = lists:map(
                        fun({UrlKey, SpecStr}) ->
                                {?l2b(UrlKey), couch_httpd:make_arity_1_fun(SpecStr)}
                        end, couch_config:get("httpd_global_handlers")),

    DbUrlHandlersList = lists:map(
                          fun({UrlKey, SpecStr}) ->
                                  {?l2b(UrlKey), couch_httpd:make_arity_2_fun(SpecStr)}
                          end, couch_config:get("httpd_db_handlers")),

    DesignUrlHandlersList = lists:map(
                              fun({UrlKey, SpecStr}) ->
                                      {?l2b(UrlKey), couch_httpd:make_arity_3_fun(SpecStr)}
                              end, couch_config:get("httpd_design_handlers")),

    UrlHandlers = dict:from_list(UrlHandlersList),
    DbUrlHandlers = dict:from_list(DbUrlHandlersList),
    DesignUrlHandlers = dict:from_list(DesignUrlHandlersList),

    DbFrontendModule = list_to_atom(couch_config:get("httpd", "db_frontend", "couch_db_frontend")),

    NewMochiReq = mochiweb_request:new(Req:get(socket),
                                       Req:get(method),
                                       Path,
                                       Req:get(version),
                                       Req:get(headers)),

    couch_httpd:handle_request(NewMochiReq, DbFrontendModule,
                               DefaultFun, UrlHandlers,
                               DbUrlHandlers, DesignUrlHandlers).

do_get(BucketId, DocId) ->
    BinaryBucketId = list_to_binary(BucketId),
    BinaryDocId = list_to_binary(DocId),
    attempt(BinaryBucketId,
            BinaryDocId,
            capi_crud, get, [BinaryBucketId, BinaryDocId, [ejson_body]]).

handle_get(BucketId, DocId, Req) ->
    case do_get(BucketId, DocId) of
        {not_found, missing} ->
            Req:respond({404, menelaus_util:server_header(), ""});
        {ok, EJSON} ->
            menelaus_util:reply_json(Req, capi_utils:couch_doc_to_mochi_json(EJSON))
    end.

do_mutate(BucketId, DocId, BodyOrUndefined) ->
    BinaryBucketId = list_to_binary(BucketId),
    BinaryDocId = list_to_binary(DocId),
    case BodyOrUndefined of
        undefined ->
            attempt(BinaryBucketId,
                    BinaryDocId,
                    capi_crud, delete, [BinaryBucketId, BinaryDocId]);
        _ ->
            attempt(BinaryBucketId,
                    BinaryDocId,
                    capi_crud, set, [BinaryBucketId, BinaryDocId, BodyOrUndefined])
    end.

handle_post(BucketId, DocId, Req) ->
    ok = do_mutate(BucketId, DocId, Req:recv_body()),
    menelaus_util:reply_json(Req, []).

handle_delete(BucketId, DocId, Req) ->
    ok = do_mutate(BucketId, DocId, undefined),
    menelaus_util:reply_json(Req, []).


%% Attempt to forward the request to the correct server, first try normal
%% map, then vbucket map, then try all nodes
-spec attempt(binary(), binary(), atom(), atom(), list()) -> any().
attempt(DbName, DocId, Mod, Fun, Args) ->
    attempt(DbName, DocId, Mod, Fun, Args, plain_map).

-spec attempt(binary(), binary(), atom(),
              atom(), list(), list() | plain_map | fast_forward) -> any().
attempt(_DbName, _DocId, _Mod, _Fun, _Args, []) ->
    throw(max_vbucket_retry);

attempt(DbName, DocId, Mod, Fun, Args, [Node | Rest]) ->
    case rpc:call(Node, Mod, Fun, Args) of
        not_my_vbucket ->
            attempt(DbName, DocId, Mod, Fun, Args, Rest);
        Else ->
            Else
    end;

attempt(DbName, DocId, Mod, Fun, Args, plain_map) ->
    {_, Node} = cb_util:vbucket_from_id(?b2l(DbName), DocId),
    case rpc:call(Node, Mod, Fun, Args) of
        not_my_vbucket ->
            attempt(DbName, DocId, Mod, Fun, Args, fast_forward);
        Else ->
            Else
    end;

attempt(DbName, DocId, Mod, Fun, Args, fast_forward) ->
    R =
        case cb_util:vbucket_from_id_fastforward(?b2l(DbName), DocId) of
            ffmap_not_found ->
                next_attempt;
            {_, Node} ->
                case rpc:call(Node, Mod, Fun, Args) of
                    not_my_vbucket ->
                        next_attempt;
                    Else ->
                        {ok, Else}
                end
        end,

    case R of
        next_attempt ->
            Nodes = ns_cluster_membership:active_nodes(),
            attempt(DbName, DocId, Mod, Fun, Args, Nodes);
        {ok, R1} ->
            R1
    end.
