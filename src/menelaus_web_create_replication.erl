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
-include("remote_clusters_info.hrl").

-export([handle_create_replication/1]).

-type replication_type() :: 'one-time' | continuous.

handle_create_replication(Req) ->
    Params = Req:parse_post(),
    Config = ns_config:get(),
    Buckets = ns_bucket:get_buckets(Config),
    ParseRV = parse_validate_new_replication_params(Params, Buckets),
    case ParseRV of
        {error, Errors} ->
            menelaus_util:reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400);
        {error, Status, Errors} ->
            menelaus_util:reply_json(Req, {struct, [{errors, {struct, Errors}}]}, Status);
        {ok, ReplicationDoc} ->
            case proplists:get_value("just_validate", Req:parse_qs()) =:= "1" of
                true ->
                    ok;
                false ->
                    ok = xdc_rdoc_replication_srv:update_doc(ReplicationDoc)
            end,

            CapiURL = capi_utils:capi_url(node(), "/_replicator",
                                          menelaus_util:local_addr(Req)),
            menelaus_util:reply_json(Req,
                                     {struct, [{database, list_to_binary(CapiURL)},
                                               {id, ReplicationDoc#doc.id}]})
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

parse_validate_new_replication_params(Params, Buckets) ->
    case screen_extract_new_replication_params(Params) of
        {ok, FromBucket, ToBucket, ReplicationType, ToCluster} ->
            validate_new_replication_params_check_from_bucket(FromBucket, ToCluster,
                                                              ToBucket, ReplicationType,
                                                              Buckets);
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
                    {ok, BucketConfig};
                X ->
                    [{<<"fromBucket">>,
                      list_to_binary("cannot replicate from this bucket type: " ++ atom_to_list(X))}]
            end
    end.

check_bucket_uuid(BucketConfig, RemoteUUID) ->
    BucketUUID = proplists:get_value(uuid, BucketConfig),
    true = (BucketUUID =/= undefined),

    case BucketUUID =:= RemoteUUID of
        true ->
            [{<<"toBucket">>,
              <<"Replication to the same bucket on the same cluster is disallowed">>}];
        false ->
            ok
    end.

validate_new_replication_params_check_from_bucket(FromBucket, ToCluster, ToBucket,
                                                  ReplicationType, Buckets) ->
    MaybeBucketError = check_from_bucket(FromBucket, Buckets),
    case MaybeBucketError of
        {ok, BucketConfig} ->
            case remote_clusters_info:get_remote_bucket(ToCluster, ToBucket, true) of
                {ok, #remote_bucket{uuid=BucketUUID,
                                    cluster_uuid=ClusterUUID}} ->
                    case check_bucket_uuid(BucketConfig, BucketUUID) of
                        ok ->
                            {ok, build_replication_doc(FromBucket,
                                                       ClusterUUID,
                                                       ToBucket, ReplicationType)};
                        Errors ->
                            {error, Errors}
                    end;
                {error, Type, Msg} when Type =:= not_present;
                                        Type =:= not_capable ->
                    {error, [{<<"toBucket">>, Msg}]};
                {error, cluster_not_found, Msg} ->
                    {error, [{<<"toCluster">>, Msg}]};
                {error, all_nodes_failed, Msg} ->
                    {error, [{<<"_">>, Msg}]};
                {error, timeout} ->
                    Msg = <<"Timeout exceeded when trying to reach remote cluster">>,
                    {error, [{<<"_">>, Msg}]};
                _ ->
                    Errors = [{<<"_">>, <<"Unexpected error occurred. See logs for details.">>}],
                    {error, 500, Errors}
            end;
        Errors ->
            {error, Errors}
    end.

build_replication_doc(FromBucket, ClusterUUID, ToBucket, ReplicationType) ->
    Reference = remote_clusters_info:remote_bucket_reference(ClusterUUID, ToBucket),

    Body =
        {[{type, <<"xdc">>},
          {source, list_to_binary(FromBucket)},
          {target, Reference},
          {targetUUID, ClusterUUID},
          {continuous, case ReplicationType of
                           continuous -> true;
                           _ -> false
                       end}]},
    #doc{id=replication_id(ClusterUUID, FromBucket, ToBucket),
         body=Body}.

replication_id(ClusterUUID, FromBucket, ToBucket) ->
    iolist_to_binary([ClusterUUID, $/, FromBucket, $/, ToBucket]).
