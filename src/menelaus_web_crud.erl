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

parse_bool(undefined, Default) -> Default;
parse_bool("true", _) -> true;
parse_bool("false", _) -> false;
parse_bool(_, _) -> throw(bad_request).

parse_int(undefined, Default) -> Default;
parse_int(List, _) ->
    try list_to_integer(List)
    catch error:badarg ->
            throw(bad_request)
    end.

parse_key(undefined) -> undefined;
parse_key(Key) ->
    try ejson:decode(Key) of
        Binary when is_binary(Binary) ->
            Binary;
        _ ->
            throw(bad_request)
    catch
        throw:{invalid_json, _} ->
            throw(bad_request)
    end.

parse_params(Params) ->
    Limit = parse_int(proplists:get_value("limit", Params), 1000),
    Skip = parse_int(proplists:get_value("skip", Params), 0),

    {Skip, Limit,
     [{include_docs, parse_bool(proplists:get_value("include_docs", Params), false)},
      {inclusive_end, parse_bool(proplists:get_value("inclusive_end", Params), true)},
      {limit, Skip + Limit},
      {start_key, parse_key(proplists:get_value("startkey", Params))},
      {end_key, parse_key(proplists:get_value("endkey", Params))}]}.

handle_list(BucketId, Req) ->
    try parse_params(Req:parse_qs()) of
        Params ->
            do_handle_list(Req, BucketId, Params, 20)
    catch
        throw:bad_request ->
            menelaus_util:reply_json(Req,
                                     {struct, [{error, <<"bad_request">>},
                                               {reason, <<"bad request">>}]}, 400)
    end.

do_handle_list(Req, _Bucket, _Params, 0) ->
    menelaus_util:reply_json(
      Req,
      {struct, [{error, <<"max_retry">>},
                {reason, <<"could not get consistent vbucket map">>}]}, 503);
do_handle_list(Req, Bucket, {Skip, Limit, Params}, N) ->
    NodeVBuckets = dict:to_list(vbucket_map_mirror:node_vbuckets_dict(Bucket)),
    Results = ns_memcached:get_keys(Bucket, NodeVBuckets, Params),

    try lists:foldl(
          fun ({_Node, R}, Acc) ->
                  case R of
                      {ok, Values} ->
                          heap_insert(Acc, Values);
                      Error ->
                          throw({error, Error})
                  end
          end, couch_skew:new(), Results) of

        Heap ->
            Heap1 = handle_skip(Heap, Skip),
            menelaus_util:reply_json(Req,
                                     {struct, [{rows, handle_limit(Heap1, Limit)}]})
    catch
        throw:{error, {memcached_error, not_my_vbucket}} ->
            timer:sleep(1000),
            do_handle_list(Req, Bucket, {Skip, Limit, Params}, N - 1);
        throw:{error, {memcached_error, Type}} ->
            menelaus_util:reply_json(Req,
                                     {struct, [{error, memcached_error},
                                               {reason, Type}]}, 500);
        throw:{error, Error} ->
            menelaus_util:reply_json(Req,
                                     {struct, [{error, couch_util:to_binary(Error)},
                                               {reason, <<"unknown error">>}]}, 500)
    end.

heap_less([{A, _} | _], [{B, _} | _]) ->
    A < B.

heap_insert(Heap, Item) ->
    case Item of
        [] ->
            Heap;
        _ ->
            couch_skew:in(Item, fun heap_less/2, Heap)
    end.

handle_skip(Heap, 0) ->
    Heap;
handle_skip(Heap, Skip) ->
    case couch_skew:size(Heap) =:= 0 of
        true ->
            Heap;
        false ->
            {[_ | Rest], Heap1} = couch_skew:out(fun heap_less/2, Heap),
            handle_skip(heap_insert(Heap1, Rest), Skip - 1)
    end.

handle_limit(Heap, Limit) ->
    do_handle_limit(Heap, Limit, []).

do_handle_limit(_, 0, R) ->
    lists:reverse(R);
do_handle_limit(Heap, Limit, R) ->
    case couch_skew:size(Heap) =:= 0 of
        true ->
            lists:reverse(R);
        false ->
            {[Min | Rest], Heap1} = couch_skew:out(fun heap_less/2, Heap),
            do_handle_limit(heap_insert(Heap1, Rest), Limit - 1,
                            [encode_doc(Min) | R])
    end.

encode_doc({Key, undefined}) ->
    {struct, [{id, Key}, {key, Key}]};
encode_doc({Key, Value}) ->
    Doc = case Value of
              {binary, V} ->
                  couch_doc:from_binary(Key, V, false);
              {json, V} ->
                  couch_doc:from_binary(Key, V, true)
          end,
    {struct, [{id, Key},
              {key, Key},
              {doc, capi_utils:couch_doc_to_mochi_json(Doc)}]}.

do_get(BucketId, DocId) ->
    BinaryBucketId = list_to_binary(BucketId),
    BinaryDocId = list_to_binary(DocId),
    attempt(BinaryBucketId,
            BinaryDocId,
            capi_crud, get, [BinaryBucketId, BinaryDocId, [ejson_body]]).

handle_get(BucketId, DocId, Req) ->
    case do_get(BucketId, DocId) of
        {not_found, missing} ->
            menelaus_util:reply(Req, 404);
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
