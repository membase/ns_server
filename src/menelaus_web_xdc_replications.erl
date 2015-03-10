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
-module(menelaus_web_xdc_replications).

-author('Couchbase <info@couchbase.com>').

-include("menelaus_web.hrl").
-include("ns_common.hrl").
-include("couch_db.hrl").
-include("remote_clusters_info.hrl").

-export([handle_create_replication/1, handle_cancel_replication/2,
         handle_replication_settings/2, handle_replication_settings_post/2,
         handle_global_replication_settings/1,
         handle_global_replication_settings_post/1,
         build_replication_settings/1,
         build_global_replication_settings/0]).

-type replication_type() :: 'one-time' | continuous.

handle_create_replication(Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            do_handle_create_replication(Req);
        true ->
            goxdcr_rest:proxy(Req)
    end.

do_handle_create_replication(Req) ->
    Params = Req:parse_post(),
    Config = ns_config:get(),
    Buckets = ns_bucket:get_buckets(Config),
    ParseRV = parse_validate_new_replication_params(Params, Buckets),
    case ParseRV of
        {error, Errors} ->
            menelaus_util:reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400);
        {error, Status, Errors} ->
            menelaus_util:reply_json(Req, {struct, [{errors, {struct, Errors}}]}, Status);
        {ok, ReplicationDoc, ParsedParams} ->
            case proplists:get_value("just_validate", Req:parse_qs()) =:= "1" of
                true ->
                    ok;
                false ->
                    ok = xdc_rdoc_api:update_doc(ReplicationDoc),

                    ns_audit:xdcr_create_replication(Req, ReplicationDoc#doc.id, ParsedParams),

                    ale:info(?USER_LOGGER,
                             "Replication from bucket \"~s\" to "
                             "bucket \"~s\" on cluster \"~s\" created.",
                             [misc:expect_prop_value(from_bucket, ParsedParams),
                              misc:expect_prop_value(to_bucket, ParsedParams),
                              misc:expect_prop_value(to_cluster, ParsedParams)])
            end,

            CapiURL = capi_utils:capi_url_bin(node(), <<"/_replicator">>,
                                              menelaus_util:local_addr(Req)),
            menelaus_util:reply_json(Req,
                                     {struct, [{database, CapiURL},
                                               {id, ReplicationDoc#doc.id}]})
    end.

handle_cancel_replication(XID, Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            do_handle_cancel_replication(XID, Req);
        true ->
            goxdcr_rest:proxy(Req, "/controller/cancelXDCR/" ++ XID)
    end.

do_handle_cancel_replication(XID, Req) ->
    case xdc_rdoc_api:delete_replicator_doc(XID) of
        ok ->
            ns_audit:xdcr_cancel_replication(Req, XID),
            menelaus_util:reply_json(Req, [], 200);
        not_found ->
            menelaus_util:reply_json(Req, [], 404)
    end.

handle_replication_settings(XID, Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            do_handle_replication_settings(XID, Req);
        true ->
            goxdcr_rest:proxy(Req)
    end.

do_handle_replication_settings(XID, Req) ->
    with_replicator_doc(
      Req, XID,
      fun (RepDoc) ->
              handle_replication_settings_body(RepDoc, Req)
      end).

build_replication_settings(RepDoc) ->
    SettingsRaw = xdc_settings:extract_per_replication_settings(RepDoc),
    [{key_to_request_key(K), format_setting_value(K, V)} || {K, V} <- SettingsRaw].

handle_replication_settings_body(RepDoc, Req) ->
    menelaus_util:reply_json(Req, {build_replication_settings(RepDoc)}, 200).

format_setting_value(socket_options, V) -> {V};
format_setting_value(_K, V) -> V.

handle_replication_settings_post(XID, Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            do_handle_replication_settings_post(XID, Req);
        true ->
            goxdcr_rest:proxy(Req)
    end.

do_handle_replication_settings_post(XID, Req) ->
    with_replicator_doc(
      Req, XID,
      fun (RepDoc) ->
              Params = Req:parse_post(),
              case update_rdoc_replication_settings(RepDoc, Params) of
                  {ok, RepDoc1} ->
                      case proplists:get_value("just_validate", Req:parse_qs()) =:= "1" of
                          true ->
                              menelaus_util:reply_json(Req, [], 200);
                          false ->
                              #doc{body={OldProps}} = RepDoc,
                              #doc{body={NewProps}} = RepDoc1,

                              case lists:keysort(1, OldProps) =:= lists:keysort(1, NewProps) of
                                  true ->
                                      ok;
                                  false ->
                                      ok = xdc_rdoc_api:update_doc(RepDoc1),
                                      ns_audit:xdcr_update_replication(Req, RepDoc1#doc.id, NewProps)
                              end,
                              handle_replication_settings_body(RepDoc1, Req)
                      end;
                  {error, Errors} ->
                      menelaus_util:reply_json(Req, {struct, Errors}, 400)
              end
      end).

handle_global_replication_settings(Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            do_handle_global_replication_settings(Req);
        true ->
            goxdcr_rest:proxy(Req)
    end.

build_global_replication_settings() ->
    SettingsRaw = xdc_settings:get_all_global_settings(),
    [{key_to_request_key(K), format_setting_value(K, V)} || {K, V} <- SettingsRaw].

do_handle_global_replication_settings(Req) ->
    menelaus_util:reply_json(Req, {build_global_replication_settings()}, 200).

handle_global_replication_settings_post(Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            do_handle_global_replication_settings_post(Req);
        true ->
            goxdcr_rest:proxy(Req)
    end.

do_handle_global_replication_settings_post(Req) ->
    Params = Req:parse_post(),
    Specs = settings_specs(),

    {Settings, Errors} =
        lists:foldl(
          fun ({Key, ReqKey, Type}, {AccSettings, AccErrors} = Acc) ->
                  case proplists:get_value(ReqKey, Params) of
                      undefined ->
                          Acc;
                      Str ->
                          case parse_validate_by_type(Type, Str) of
                              {ok, V} ->
                                  {[{Key, V} | AccSettings], AccErrors};
                              Error ->
                                  {AccSettings, [{ReqKey, Error} | AccErrors]}
                          end
                  end
          end, {[], []}, Specs),

    case Errors of
        [] ->
            case proplists:get_value("just_validate", Req:parse_qs()) =:= "1" of
                true ->
                    menelaus_util:reply_json(Req, [], 200);
                false ->
                    xdc_settings:update_global_settings(Settings),
                    ns_audit:xdcr_update_global_settings(Req, Settings),
                    handle_global_replication_settings(Req)
            end;
        _ ->
            menelaus_util:reply_json(Req, {struct, Errors}, 400)
    end.

%% internal functions
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
    {ok, Type :: binary(), FromBucket :: string(), ToBucket :: string(),
     ReplicationType :: replication_type(), ToCluster :: string()} |
    {error, [{FieldName::binary(), FieldMsg::binary()}]}.
screen_extract_new_replication_params(Params) ->
    Fields = [case proplists:get_value("type", Params) of
                  undefined ->
                      {ok, <<"xdc-xmem">>};
                  "capi" ->
                      {ok, <<"xdc">>};
                  "xmem" ->
                      {ok, <<"xdc-xmem">>};
                  _ ->
                      {error, <<"type">>, <<"type is invalid">>}
              end,
              get_parameter("fromBucket", Params, <<"source bucket">>),
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
        {ok, Type, FromBucket, ToBucket, ReplicationType, ToCluster} ->
            case validate_new_replication_params_check_from_bucket(
                   Type, FromBucket, ToCluster, ToBucket, ReplicationType, Buckets) of
                {ok, ReplicationDoc} ->
                    case update_rdoc_replication_settings(ReplicationDoc, Params) of
                        {ok, ReplicationDoc1} ->
                            ParsedParams = [{from_bucket, FromBucket},
                                            {to_bucket, ToBucket},
                                            {replication_type, ReplicationType},
                                            {to_cluster, ToCluster}],
                            {ok, ReplicationDoc1, ParsedParams};
                        Error ->
                            Error
                    end;
                Other ->
                    Other
            end;
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

check_no_duplicated_replication(ClusterUUID, FromBucket, ToBucket) ->
    ReplicationId = replication_id(ClusterUUID, FromBucket, ToBucket),
    case ns_couchdb_api:get_doc(xdcr, ReplicationId) of
        {ok, #doc{deleted = false}} ->
            [{<<"_">>,
              <<"Replication to the same remote cluster and bucket already exists">>}];
        {ok, #doc{deleted = true}} ->
            ok;
        {not_found, _} ->
            ok
    end.

check_map_size(BucketConfig, Map) ->
    NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),
    true = (NumVBuckets =/= undefined),
    case dict:size(Map) of
        NumVBuckets ->
            ok;
        _ ->
            [{<<"toBucket">>,
              <<"Replication to the bucket with different number of vbuckets is disallowed">>}]
    end.

check_xmem_allowed(<<"xdc">>, _) ->
    ok;
check_xmem_allowed(<<"xdc-xmem">>, RemoteVersion) when RemoteVersion < [2, 2] ->
    [{<<"type">>,
      <<"Version 2 replication is disallowed. Remote cluster has nodes with versions less than 2.2.">>}];
check_xmem_allowed(<<"xdc-xmem">>, _) ->
    case cluster_compat_mode:is_cluster_25() of
        true ->
            ok;
        false ->
            [{<<"type">>,
              <<"Version 2 replication is disallowed. Cluster has nodes with versions less than 2.5.">>}]
    end.

validate_new_replication_params_check_from_bucket(Type, FromBucket, ToCluster, ToBucket,
                                                  ReplicationType, Buckets) ->
    MaybeBucketError = check_from_bucket(FromBucket, Buckets),
    case MaybeBucketError of
        {ok, BucketConfig} ->
            case remote_clusters_info:get_remote_bucket(ToCluster, ToBucket, true_using_new_connection) of
                {ok, #remote_bucket{uuid=BucketUUID,
                                    cluster_uuid=ClusterUUID,
                                    raw_vbucket_map=Map,
                                    cluster_version=RemoteVersion}} ->
                    case check_xmem_allowed(Type, RemoteVersion) of
                        ok ->
                            case check_bucket_uuid(BucketConfig, BucketUUID) of
                                ok ->
                                    case check_no_duplicated_replication(ClusterUUID,
                                                                         FromBucket, ToBucket) of
                                        ok ->
                                            case check_map_size(BucketConfig, Map) of
                                                ok ->
                                                    {ok, build_replication_doc(Type, FromBucket,
                                                                               ClusterUUID,
                                                                               ToBucket,
                                                                               ReplicationType)};
                                                Errors ->
                                                    {error, Errors}
                                            end;
                                        Errors ->
                                            {error, Errors}
                                    end;
                                Errors ->
                                    {error, Errors}
                            end;
                        Errors ->
                            {error, Errors}
                    end;
                {error, ErrorType, Msg} when ErrorType =:= not_present;
                                             ErrorType =:= not_capable ->
                    {error, [{<<"toBucket">>, Msg}]};
                {error, cluster_not_found, Msg} ->
                    {error, [{<<"toCluster">>, Msg}]};
                {error, all_nodes_failed, Msg} ->
                    {error, [{<<"_">>, Msg}]};
                {error, timeout} ->
                    Msg = <<"Timeout exceeded when trying to reach remote cluster">>,
                    {error, [{<<"_">>, Msg}]};
                {error, rest_error, Msg, _} when is_binary(Msg) ->
                    {error, [{<<"_">>, Msg}]};
                OtherError ->
                    ?log_error("got unclassified error while trying to validate remote bucket details: ~p", [OtherError]),
                    Errors = [{<<"_">>, <<"Unexpected error occurred. See logs for details.">>}],
                    {error, 500, Errors}
            end;
        Errors ->
            {error, Errors}
    end.

build_replication_doc(Type, FromBucket, ClusterUUID, ToBucket, ReplicationType) ->
    Reference = remote_clusters_info:remote_bucket_reference(ClusterUUID, ToBucket),

    Body =
        {[{type, Type},
          {source, list_to_binary(FromBucket)},
          {target, Reference},
          {continuous, case ReplicationType of
                           continuous -> true;
                           _ -> false
                       end}]},
    #doc{id=replication_id(ClusterUUID, FromBucket, ToBucket),
         body=Body}.

replication_id(ClusterUUID, FromBucket, ToBucket) ->
    iolist_to_binary([ClusterUUID, $/, FromBucket, $/, ToBucket]).

with_replicator_doc(Req, XID, Body) ->
    case xdc_rdoc_api:get_full_replicator_doc(XID) of
        not_found ->
            menelaus_util:reply_not_found(Req);
        {ok, Doc} ->
            Body(Doc)
    end.

per_replication_settings_specs() ->
    [{couch_util:to_binary(Key), key_to_request_key(Key), Type} ||
        {Key, Type} <- xdc_settings:per_replication_settings_specs()].

settings_specs() ->
    [{Key, key_to_request_key(Key), Type} ||
        {Key, _, Type, _} <- xdc_settings:settings_specs()].

parse_validate_by_type({int, Min, Max}, Str) ->
    case menelaus_util:parse_validate_number(Str, Min, Max) of
        {ok, Parsed} ->
            {ok, Parsed};
        _Error ->
            Msg = io_lib:format("The value must be an integer between ~p and ~p",
                                [Min, Max]),
            iolist_to_binary(Msg)
    end;
parse_validate_by_type(bool, Str) ->
    case Str of
        "true" ->
            {ok, true};
        "false" ->
            {ok, false};
        _ ->
            <<"The value must be a boolean">>
    end;
parse_validate_by_type(term, Str) ->
    case catch(couch_util:parse_term(Str)) of
        {ok, Term} ->
            {ok, Term};
        _ ->
            <<"The value must be an erlang term">>
    end.

key_to_request_key(Key) ->
    KeyList = couch_util:to_list(Key),
    [First | Rest] = string:tokens(KeyList, "_"),
    RestCapitalized = [[string:to_upper(C) | TokenRest] || [C | TokenRest] <- Rest],
    lists:concat([First | RestCapitalized]).

update_rdoc_replication_settings(#doc{body={Props}} = RepDoc, Params) ->
    Specs = per_replication_settings_specs(),

    {Settings, Remove, Errors} =
        lists:foldl(
          fun ({Key, ReqKey, Type},
               {AccSettings, AccRemove, AccErrors} = Acc) ->
                  case proplists:get_value(ReqKey, Params) of
                      undefined ->
                          Acc;
                      "" ->
                          {AccSettings, [Key | AccRemove], AccErrors};
                      Str ->
                          case parse_validate_by_type(Type, Str) of
                              {ok, V} ->
                                  {[{Key, V} | AccSettings],
                                   AccRemove, AccErrors};
                              Error ->
                                  {AccSettings, AccRemove,
                                   [{ReqKey, Error} | AccErrors]}
                          end
                  end
          end, {[], [], []}, Specs),

    case Errors of
        [] ->
            Props1 = [{K, V} || {K, V} <- Props,
                                not(lists:member(K, Remove))],
            Props2 = misc:update_proplist(Props1, Settings),
            RepDoc1 = RepDoc#doc{body={Props2}},
            {ok, RepDoc1};
        _ ->
            {error, Errors}
    end.
