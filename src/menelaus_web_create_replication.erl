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
%% @doc REST API for creating/verifying replication
-module(menelaus_web_create_replication).

-author('Couchbase <info@couchbase.com>').

-include("menelaus_web.hrl").
-include("ns_common.hrl").
-include("couch_db.hrl").

-export([handle_create_replication/1]).

-type replication_type() :: 'one-time' | continuous.

handle_create_replication(Req) ->
    Params = Req:parse_post(),
    Config = ns_config:get(),
    Buckets = ns_bucket:get_buckets(Config),
    RemoteClusters = menelaus_web_remote_clusters:get_remote_clusters(Config),
    ParseRV = parse_validate_new_replication_params(Params, Buckets, RemoteClusters, fun json_get/5),
    case ParseRV of
        {error, Errors} ->
            menelaus_util:reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400);
        {ok, ReplicationFields} ->
            menelaus_util:reply_json(Req, {struct, [{database, list_to_binary(capi_utils:capi_url(node(), "/_replicator", "127.0.0.1"))},
                                                    {document, {struct, ReplicationFields}}]},
                                     200)
    end.

get_parameter(Name, Params, HumanName) ->
    RawValue = proplists:get_value(Name, Params),
    Ok = case RawValue of
             undefined -> false;
             "" -> false;
             _ -> true
         end,
    case Ok of
        true ->
            {ok, RawValue};
        _ ->
            {error, list_to_binary(Name), iolist_to_binary([HumanName, <<" cannot be empty">>])}
    end.

-spec screen_extract_new_replication_params([{string(), string()}]) ->
    {ok, FromBucket :: string(), ToBucket :: string(), ReplicationType :: replication_type(), ToCluster :: string()} |
    {error, [{FieldName::binary(), FieldMsg::binary()}]}.
screen_extract_new_replication_params(Params) ->
    Fields = [get_parameter("fromBucket", Params, <<"source bucket">>),
              get_parameter("toBucket", Params, <<"target bucket">>),
              case get_parameter("replicationType", Params, <<"replication type">>) of
                  {ok, "one-time"} -> {ok, 'one-time'};
                  {ok, "continuous"} -> {ok, continuous};
                  {ok, _} -> {error, <<"replicationType">>, <<"replicationType is invalid">>};
                  V -> V
              end,
              get_parameter("toCluster", Params, <<"target cluster">>)],
    Errors = [{Name, Msg} || {error, Name, Msg} <- Fields],
    case Errors of
        [] ->
            list_to_tuple([ok | [V || {ok, V} <- Fields]]);
        _ ->
            {error, Errors}
    end.

parse_validate_new_replication_params(Params, Buckets, RemoteClusters, JsonGet) ->
    case screen_extract_new_replication_params(Params) of
        {ok, FromBucket, ToBucket, ReplicationType, ToCluster} ->
            validate_new_replication_params_check_from_bucket(FromBucket, ToBucket, ReplicationType,
                                                              ToCluster, Buckets, RemoteClusters, JsonGet);
        Crap ->
            Crap
    end.

check_from_bucket(FromBucket, Buckets) ->
    case lists:keyfind(FromBucket, 1, Buckets) of
        false ->
            [{<<"fromBucket">>, <<"unknown source bucket">>}];
        {_, BucketConfig} ->
            case proplists:get_value(type, BucketConfig) of
                membase ->
                    [];
                X ->
                    [{<<"fromBucket">>, list_to_binary("cannot replicate from this bucket type: " ++ atom_to_list(X))}]
            end
    end.

check_find_to_cluster(ToCluster, RemoteClusters) ->
    MaybeThisCluster = lists:filter(fun (KV) ->
                                            lists:keyfind(name, 1, KV) =:= {name, ToCluster}
                                    end, RemoteClusters),
    case MaybeThisCluster of
        [] ->
            {undefined, [{<<"toCluster">>, <<"could not find remote cluster with given name">>}]};
        [ThisCluster] ->
            {ThisCluster, []}
    end.

validate_new_replication_params_check_from_bucket(FromBucket, ToBucket, ReplicationType, ToCluster, Buckets, RemoteClusters, JsonGet) ->
    MaybeBucketError = check_from_bucket(FromBucket, Buckets),
    {ToClusterKV, MaybeToClusterError} = check_find_to_cluster(ToCluster, RemoteClusters),
    case MaybeBucketError ++ MaybeToClusterError of
        [] ->
            validate_new_replication_params_with_cluster(FromBucket, ToBucket, ReplicationType, ToClusterKV, JsonGet);
        Errors ->
            {error, Errors}
    end.

-spec throw_simple_json_get_error(binary(), iolist()) -> no_return().
throw_simple_json_get_error(Field, Msg) ->
    erlang:throw({json_get_error, {error, [{Field, iolist_to_binary(Msg)}]}}).

-spec throw_simple_json_get_error(string()) -> no_return().
throw_simple_json_get_error(Msg) ->
    throw_simple_json_get_error(<<"_">>, Msg).

json_get(Host, Port, Path, Username, Password) ->
    case menelaus_rest:json_request_hilevel(get, {Host, Port, Path}, {Username, Password}) of
        {ok, RV} ->
            RV;
        X ->
            ?log_debug("json_get(~p, ~p, ~p, ~p, ~p) failed:~n~p", [Host, Port, Path, Username, Password, X]),
            case X of
                {client_error, _} ->
                    throw_simple_json_get_error(<<"remote cluster unexpectedly returned 400 status code">>);
                {error, rest_error, B, _Nested} ->
                    throw_simple_json_get_error([<<"remote cluster access failed: ">>, B])
            end
    end.

validate_new_replication_params_with_cluster(FromBucket, ToBucket, ReplicationType, ToClusterKV, JsonGet) ->
    try do_validate_new_replication_params_with_cluster(FromBucket, ToBucket, ReplicationType, ToClusterKV, JsonGet)
    catch throw:{json_get_error, X} ->
            X
    end.


do_validate_new_replication_params_with_cluster(FromBucket, ToBucket, ReplicationType, ToClusterKV, JsonGet0) ->
    UserName = proplists:get_value(username, ToClusterKV),
    true = (UserName =/= undefined),
    Password = proplists:get_value(password, ToClusterKV),
    true = (Password =/= undefined),
    Hostname0 = proplists:get_value(hostname, ToClusterKV),
    true = (Hostname0 =/= undefined),
    {Host, Port} = case re:run(Hostname0, <<"(.*):(.*)">>, [anchored, {capture, all_but_first, list}]) of
                       nomatch ->
                           {Hostname0, "8091"};
                       {match, [_Host, _Port] = HPair} ->
                           list_to_tuple(HPair)
                   end,
    JsonGet = fun (Path) ->
                      JsonGet0(Host, Port, Path, UserName, Password)
              end,
    ?log_debug("Will use the following json_get params: ~p, ~p, ~p, ~p", [Host, Port, UserName, Password]),
    {struct, Pools} = JsonGet("/pools"),
    DefaultPoolPath = case proplists:get_value(<<"pools">>, Pools) of
                          [] ->
                              throw_simple_json_get_error(<<"pools request returned empty pools list">>);
                          [{struct, KV} | _] ->
                              case proplists:get_value(<<"uri">>, KV) of
                                  undefined -> undefined;
                                  URI -> binary_to_list(URI)
                              end;
                          _ -> undefined
                      end,
    case DefaultPoolPath of
        undefined ->
            throw_simple_json_get_error(<<"pools request returned invalid object">>);
        _ -> ok
    end,
    {struct, PoolDetails} = JsonGet(DefaultPoolPath),
    ?log_debug("Got pool details~n~p~n", [PoolDetails]),
    BucketsURL = case proplists:get_value(<<"buckets">>, PoolDetails) of
                     undefined ->
                         throw_simple_json_get_error(<<"pool details request returned json without buckets field">>);
                     {struct, BucketsField} ->
                         case proplists:get_value(<<"uri">>, BucketsField) of
                             undefined ->
                                 throw_simple_json_get_error(<<"pool details request returned json with invalid buckets field">>);
                             XBuckets ->
                                 binary_to_list(XBuckets)
                         end
                 end,
    BinToBucket = list_to_binary(ToBucket),
    BucketsList = JsonGet(BucketsURL),

    BucketPath = case [KV || {struct, KV} <- BucketsList,
                             lists:keyfind(<<"name">>, 1, KV) =:= {<<"name">>, BinToBucket}] of
                     [TargetBucket | _] ->
                         case proplists:get_value(<<"uri">>, TargetBucket) of
                             undefined ->
                                 throw_simple_json_get_error(<<"buckets list request returned invalid json">>);
                             X ->
                                 binary_to_list(X)
                         end;
                     _ ->
                         throw_simple_json_get_error(<<"toBucket">>,
                                                     <<"target cluster doesn't have given bucket or authentication failed">>)
                 end,

    {struct, BucketDetails} = JsonGet(BucketPath),
    MaybeErrors0 =
        [case proplists:get_value(<<"bucketType">>, BucketDetails) of
             <<"membase">> -> undefined;
             XBucketType -> "target bucket has unsupported bucket type: " ++ binary_to_list(XBucketType)
         end,
         case proplists:get_value(<<"vBucketServerMap">>, BucketDetails) of
             {struct, [_|_]} ->
                 undefined;
             _ ->
                 "target bucket is missing vbucket map"
         end,
         case proplists:get_value(<<"nodes">>, BucketDetails) of
             Nodes when is_list(Nodes) ->
                 case [N || {struct, N} <- Nodes,
                            case proplists:get_value(<<"couchApiBase">>, N) of
                                undefined -> true;
                                _ -> false
                            end] of
                     [] ->
                         undefined;
                     _ ->
                         "not all nodes in target bucket have couch api url"
                 end;
             _ ->
                 "target bucket is missing nodes list"
         end],
    MaybeErrors = lists:filter(fun (undefined) -> false;
                                   (_) -> true
                               end, MaybeErrors0),
    case MaybeErrors of
        [] ->
            {ok, [{type, <<"xdc">>},
                  {source, list_to_binary(FromBucket)},
                  {targetBucket, BinToBucket},
                  {target, iolist_to_binary([<<"http://">>,
                                             mochiweb_util:quote_plus(UserName),
                                             <<":">>,
                                             mochiweb_util:quote_plus(Password),
                                             <<"@">>,
                                             Host,
                                             <<":">>,
                                             Port,
                                             BucketPath])},
                  {continuous, case ReplicationType of
                                   continuous -> true;
                                   _ -> false
                               end}]};
        _ ->
            throw_simple_json_get_error(string:join(MaybeErrors, " and "))
    end.
