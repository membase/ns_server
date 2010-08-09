%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% @doc Web server for menelaus.

-module(menelaus_web_buckets).

-author('NorthScale <info@northscale.com>').

-include("menelaus_web.hrl").

-export([all_accessible_bucket_names/2,
         checking_bucket_access/4,
         handle_bucket_list/2,
         handle_bucket_info/5,
         build_bucket_info/5,
         build_bucket_info/4,
         handle_sasl_buckets_streaming/2,
         handle_bucket_info_streaming/5,
         handle_bucket_info_streaming/6,
         handle_bucket_delete/3,
         handle_bucket_update/3,
         handle_bucket_create/2,
         handle_bucket_flush/3,
         redirect_to_bucket/3]).

-import(menelaus_util,
        [server_header/0,
         reply_json/2,
         concat_url_path/1,
         reply_json/3]).

all_accessible_bucket_names(_PoolId, Req) ->
    BucketsAll = ns_bucket:get_bucket_names(),
    menelaus_auth:filter_accessible_buckets(BucketsAll, Req).

checking_bucket_access(_PoolId, Id, Req, Body) ->
    E404 = make_ref(),
    try
        case menelaus_auth:is_bucket_accessible({Id, fakebucket}, Req) of
            true -> apply(Body, [fakepool, fakebucket]);
            _ -> menelaus_auth:require_auth(Req)
        end
    catch
        exit:E404 ->
            Req:respond({404, server_header(), "Requested resource not found.\r\n"})
    end.

handle_bucket_list(Id, Req) ->
    BucketNames = lists:sort(fun (A,B) -> A =< B end,
                             all_accessible_bucket_names(fakepool, Req)),
    LocalAddr = menelaus_util:local_addr(Req),
    BucketsInfo = [build_bucket_info(Id, Name, fakepool, LocalAddr)
                   || Name <- BucketNames],
    reply_json(Req, BucketsInfo).

handle_bucket_info(PoolId, Id, Req, Pool, _Bucket) ->
    case ns_bucket:get_bucket(Id) of
        not_present -> Req:respond({404, server_header(), "The bucket was not found.\r\n"});
        _ -> reply_json(Req, build_bucket_info(PoolId, Id, Pool, menelaus_util:local_addr(Req)))
    end.

build_bucket_info(PoolId, Id, Pool, LocalAddr) ->
    build_bucket_info(PoolId, Id, Pool, normal, LocalAddr).

build_bucket_info(PoolId, Id, Pool, InfoLevel, LocalAddr) ->
    StatsUri = list_to_binary(concat_url_path(["pools", PoolId, "buckets", Id, "stats"])),
    Nodes = menelaus_web:build_nodes_info(Pool, false, InfoLevel, LocalAddr),
    {ok, BucketConfig} = ns_bucket:get_bucket(Id),
    Suffix = case InfoLevel of
                 stable -> [];
                 normal ->
                     [{replicaNumber, ns_bucket:num_replicas(BucketConfig)},
                      {quota, {struct, [{ram, ns_bucket:ram_quota(BucketConfig)},
                                        {hdd, ns_bucket:hdd_quota(BucketConfig)}]}},
                      {basicStats, {struct, menelaus_stats:basic_stats(PoolId, Id)}}]
             end,
    {struct, [{name, list_to_binary(Id)},
              {bucketType, ns_bucket:bucket_type(BucketConfig)},
              {authType, misc:expect_prop_value(auth_type, BucketConfig)},
              {saslPassword, list_to_binary(proplists:get_value(sasl_password, BucketConfig, ""))},
              {proxyPort, proplists:get_value(moxi_port, BucketConfig, 0)},
              {uri, list_to_binary(concat_url_path(["pools", PoolId, "buckets", Id]))},
              {streamingUri, list_to_binary(concat_url_path(["pools", PoolId, "bucketsStreaming", Id]))},
              %% TODO: this should be under a controllers/ kind of namespacing
              {flushCacheUri, list_to_binary(concat_url_path(["pools", PoolId,
                                                              "buckets", Id, "controller", "doFlush"]))},
              {nodes, Nodes},
              {stats, {struct, [{uri, StatsUri}]}},
              {vBucketServerMap, ns_bucket:json_map(Id, LocalAddr)}
              | Suffix]}.

handle_sasl_buckets_streaming(_PoolId, Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    F = fun (_) ->
                SASLBuckets = lists:filter(fun ({_, BucketInfo}) ->
                                                   ns_bucket:auth_type(BucketInfo) =:= sasl
                                           end, ns_bucket:get_buckets()),
                List = lists:map(fun ({Name, BucketInfo}) ->
                                         {struct, MapProps} = ns_bucket:json_map(Name, LocalAddr),
                                         BinName = list_to_binary(Name),
                                         Props = [{user, BinName},
                                                  {password, list_to_binary(ns_bucket:sasl_password(BucketInfo))}
                                                  | MapProps],
                                         {struct, [{name, BinName},
                                                   {vBucketServerMap, {struct, Props}}]}
                                 end, SASLBuckets),
                {struct, [{buckets, List}]}
        end,
    menelaus_web:handle_streaming(F, Req, undefined).

handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket) ->
    handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket, stable).

handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket, ForceInfoLevel) ->
    LocalAddr = menelaus_util:local_addr(Req),
    F = fun(InfoLevel) ->
                case ForceInfoLevel of
                    undefined -> build_bucket_info(PoolId, Id, Pool, InfoLevel, LocalAddr);
                    _         -> build_bucket_info(PoolId, Id, Pool, ForceInfoLevel, LocalAddr)
                end
        end,
    menelaus_web:handle_streaming(F, Req, undefined).

handle_bucket_delete(_PoolId, BucketId, Req) ->
    case ns_bucket:delete_bucket(BucketId) of
        ok ->
            ?MENELAUS_WEB_LOG(?BUCKET_DELETED, "Deleted bucket \"~s\"~n", [BucketId]),
            Req:respond({200, server_header(), []});
        {exit, {not_found, _}, _} ->
            Req:respond({404, server_header(), "The bucket to be deleted was not found.\r\n"})
    end.

redirect_to_bucket(Req, PoolId, BucketId) ->
    Req:respond({302, [{"Location", concat_url_path(["pools", PoolId, "buckets", BucketId])}
                       | server_header()],
                 ""}).

parse_ram_quota(RAMQuotaMB) ->
    (catch list_to_integer(RAMQuotaMB) * 1048576).

parse_hdd_quota(undefined) ->
    undefined;
parse_hdd_quota(HDDQuotaGB) ->
    (catch list_to_integer(HDDQuotaGB) * 1048576 * 1024).

parse_num_replicas(undefined) ->
    undefined;
parse_num_replicas(NumReplicas) ->
    (catch list_to_integer(NumReplicas)).

parse_proxy_port(ProxyPort) ->
    (catch list_to_integer(ProxyPort)).

validate_bucket_params(Type, RAMQuota, HDDQuota, NumReplicas, AuthType, SASLPassword, ProxyPort) ->
    %% TODO fix for handling memcache type bucket
    RAMIsNumber = is_integer(RAMQuota),
    HDDIsNumber = is_integer(HDDQuota),
    ProxyPortIsNumber = is_integer(ProxyPort),
    ReplicasIsInt = is_integer(NumReplicas),
    TypeIsValid = is_valid_bucket_type(Type),

    Errors = [{bucketType, case TypeIsValid of
                               true -> ok;
                               _ ->
                                   <<"Invalid bucket type specified.">>
                           end},
              {ramQuotaMB, case RAMIsNumber of
                               true -> ok;
                               _ ->
                                   <<"RAM quota must be a number.">>
                           end},
              {hddQuotaGB, case HDDIsNumber of
                               true ->
                                   case RAMIsNumber of
                                       true ->
                                           case RAMQuota > HDDQuota of
                                               true ->
                                                   <<"Disk quota is smaller than RAM.">>;
                                               _ -> ok
                                           end;
                                       _ -> ok
                                   end;
                               _ ->
                                   <<"Disk quota needs to be a number">>
                           end},
              {authType, case AuthType of
                             undefined -> <<"Authenication type is invalid">>;
                             _ -> ok
                         end},
              {proxyPort, case ProxyPortIsNumber of
                              true -> ok;
                              %% need more validation here
                              _ -> case authType of
                                       none -> <<"Proxy port needs to be a number">>;
                                       _ -> ok
                                   end
                          end},
              {replicaNumber, case ReplicasIsInt of
                                  true -> ok;
                                  _ -> <<"Replica number must be an integer.">>
                              end}],
    case lists:filter(fun ({_, ok}) -> false;
                          (_) -> true
                      end, Errors) of
        [] ->
            {SASLPassword2, ProxyPort2} = case AuthType of
                                              sasl ->
                                                  {SASLPassword, 0};
                                              none ->
                                                  {"", ProxyPort}
                                          end,
            {ok, [{auth_type, AuthType},
                  {sasl_password, SASLPassword2},
                  {moxi_port, ProxyPort2},
                  {ram_quota, RAMQuota},
                  {hdd_quota, HDDQuota},
                  {num_replicas, NumReplicas}]};
        Errors2 -> {errors, Errors2}
    end.


handle_bucket_update(PoolId, BucketId, Req) ->
    case ns_bucket:get_bucket(BucketId) of
        {ok, BucketConfig} ->
            handle_bucket_update(PoolId, BucketId, Req, BucketConfig);
        _ ->
            reply_json(Req, {struct, [{'_', [<<"Bucket not found">>]}]}, 400)
    end.

handle_bucket_update(_PoolId, BucketId, Req, BucketConfig) ->
    Params = Req:parse_post(),
    RAMQuota = parse_ram_quota(proplists:get_value("ramQuotaMB", Params)),
    HDDQuota = parse_hdd_quota(proplists:get_value("hddQuotaGB", Params)),
    NumReplicas = parse_num_replicas(proplists:get_value("replicaNumber", Params)),
    AuthType = case proplists:get_value("authType", Params) of
                   "none" -> none;
                   "sasl" -> sasl;
                   _ -> undefined
               end,
    SASLPassword = proplists:get_value("saslPassword", Params, ""),
    ProxyPort = parse_proxy_port(proplists:get_value("proxyPort", Params, "0")),

    BucketType = ns_bucket:bucket_type(BucketConfig),

    case validate_bucket_params(atom_to_list(BucketType),
                                RAMQuota, HDDQuota, NumReplicas,
                                AuthType, SASLPassword, ProxyPort) of
        {ok, UpdatedProps} ->
            case ns_bucket:update_bucket_props(BucketType, BucketId, UpdatedProps) of
                ok ->
                    Req:respond({200, server_header(), []});
                {exit, {not_found, _}, _} ->
                    reply_json(Req, {struct, [{'_', [<<"Bucket not found">>]}]}, 400)
            end;
        {errors, Errors} ->
            reply_json(Req, {struct, Errors}, 400)
    end.

handle_bucket_create(PoolId, Req) ->
    case ns_node_disco:nodes_wanted() =:= ns_node_disco:nodes_actual_proper() of
        true ->
            Params = Req:parse_post(),
            %% TODO: validation
            Name = misc:expect_prop_value("name", Params),
            Type = misc:expect_prop_value("bucketType", Params),
            RAMQuota = parse_ram_quota(proplists:get_value("ramQuotaMB", Params, undefined)),
            HDDQuota = parse_hdd_quota(proplists:get_value("hddQuotaGB", Params, undefined)),
            NumReplicas = parse_num_replicas(proplists:get_value("replicaNumber", Params, undefined)),
            AuthType = case proplists:get_value("authType", Params) of
                           "none" -> none;
                           "sasl" -> sasl;
                           _ -> undefined
                       end,
            SASLPassword = proplists:get_value("saslPassword", Params),
            ProxyPort = parse_proxy_port(proplists:get_value("proxyPort", Params)),
            BucketType = case Type of
                             "membase" ->
                                 membase;
                             _ ->
                                 memcache
                         end,
            ErrorsOrProps0 = validate_bucket_params(Type, RAMQuota, HDDQuota, NumReplicas, AuthType, SASLPassword, ProxyPort),
            ErrorsOrProps = case ns_bucket:is_valid_bucket_name(Name) of
                                false ->
                                    Errors0 = case ErrorsOrProps0 of
                                                  {errors, Errors0V} -> Errors0V;
                                                  _ -> []
                                              end,
                                    {errors, [{name, <<"Given bucket name is invalid. Consult the documentation.">>}
                                              | Errors0]};
                                _ -> ErrorsOrProps0
                            end,
            case ErrorsOrProps of
                {ok, Props} ->
                    case ns_orchestrator:create_bucket(BucketType, Name, Props) of
                        ok ->
                            ?MENELAUS_WEB_LOG(?BUCKET_CREATED, "Created bucket \"~s\" of type: ~s~n", [Name, BucketType]),
                            redirect_to_bucket(Req, PoolId, Name);
                        {exit, {already_exists, _}, _} ->
                            reply_json(Req, {struct, [{name, <<"Bucket with given name already exists">>}]}, 400)
                    end;
                {errors, Errors} ->
                    reply_json(Req, {struct, Errors}, 400)
            end;
        false ->
            reply_json(Req, [list_to_binary("One or more server nodes appear to be down. " ++
                                                "Please first restore or remove those servers nodes " ++
                                                "so that the entire cluster is healthy.")], 400)
    end.


handle_bucket_flush(PoolId, Id, Req) ->
    ns_log:log(?MODULE, 0005, "Flushing pool ~p bucket ~p from node ~p",
               [PoolId, Id, erlang:node()]),
    Req:respond({400, server_header(), "Flushing is not currently implemented."}).

%% check bucket type
%% In the future, this can check by comparing to something actually asserted
%% or somehow sent up by the engine
is_valid_bucket_type([]) -> false;
is_valid_bucket_type(Type) ->
    case Type of
        "memcache" ->
            true;
        "membase" ->
            true;
        _ -> false
    end.
