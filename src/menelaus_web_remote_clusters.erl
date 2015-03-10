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
%% @doc REST API for remote clusters management
-module(menelaus_web_remote_clusters).

-author('Couchbase <info@couchbase.com>').

-include("menelaus_web.hrl").
-include("ns_common.hrl").
-include("remote_clusters_info.hrl").

-export([get_remote_clusters/0,
         cas_remote_clusters/2,
         handle_remote_clusters/1,
         handle_remote_clusters_post/1,
         handle_remote_cluster_update/2,
         handle_remote_cluster_delete/2,
         build_remote_cluster_info/2]).

get_remote_clusters() ->
    case ns_config:search(remote_clusters) of
        {value, X} -> X;
        false -> []
    end.

cas_remote_clusters(Old, NewUnsorted) ->
    New = lists:sort(NewUnsorted),
    case ns_config:update_key(remote_clusters,
                              fun (V) ->
                                      case V of
                                          Old -> New;
                                          _ ->
                                              erlang:throw(mismatch)
                                      end
                              end, New) of
        ok -> ok;
        {throw, mismatch, _} -> mismatch
    end.

build_remote_cluster_info(KV, Upgrade) ->
    Name = misc:expect_prop_value(name, KV),
    Deleted = proplists:get_value(deleted, KV, false),
    MaybeCert = case proplists:get_value(cert, KV) of
                    undefined -> [];
                    Cert -> [{demandEncryption, true},
                             {certificate, Cert}]
                end,
    {[{name, list_to_binary(Name)},
      {hostname, list_to_binary(misc:expect_prop_value(hostname, KV))},
      {username, list_to_binary(misc:expect_prop_value(username, KV))},
      {uuid, misc:expect_prop_value(uuid, KV)},
      {deleted, Deleted}] ++
         case Upgrade of
             false ->
                 URI = menelaus_util:bin_concat_path(["pools", "default", "remoteClusters", Name]),
                 [{uri, URI},
                  {validateURI, iolist_to_binary([URI, <<"?just_validate=1">>])}];
             true ->
                 [{password, list_to_binary(misc:expect_prop_value(password, KV))}]
         end ++ MaybeCert}.

handle_remote_clusters(Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            RemoteClusters = get_remote_clusters(),
            JSON = lists:map(fun (KV) ->
                                     build_remote_cluster_info(KV, false)
                             end, RemoteClusters),
            menelaus_util:reply_json(Req, JSON);
        true ->
            goxdcr_rest:proxy(Req)
    end.

handle_remote_clusters_post(Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            Params = Req:parse_post(),
            QS = Req:parse_qs(),
            do_handle_remote_clusters_post(Req, Params, proplists:get_value("just_validate", QS), 10);
        true ->
            goxdcr_rest:proxy(Req)
    end.

do_handle_remote_clusters_post(_Req, _Params, _JustValidate, _TriesLeft = 0) ->
    erlang:error(cas_retries_exceeded);
do_handle_remote_clusters_post(Req, Params, JustValidate, TriesLeft) ->
    ExistingClusters = get_remote_clusters(),
    case validate_remote_cluster_params(Params, ExistingClusters) of
        {ok, KVList} ->
            case validate_remote_cluster(KVList, ExistingClusters) of
                {ok, FinalKVList} ->
                    case JustValidate of
                        undefined ->
                            NewClusters = add_new_cluster(FinalKVList, ExistingClusters),

                            case cas_remote_clusters(ExistingClusters, NewClusters) of
                                ok ->
                                    Name = misc:expect_prop_value(name, FinalKVList),
                                    Hostname = misc:expect_prop_value(hostname, FinalKVList),

                                    ale:info(?USER_LOGGER,
                                             "Created remote cluster reference \"~s\" via ~s.",
                                             [Name, Hostname]),

                                    ns_audit:xdcr_create_cluster_ref(Req, FinalKVList),

                                    menelaus_util:reply_json(Req,
                                                             build_remote_cluster_info(FinalKVList, false));
                                _ ->
                                    do_handle_remote_clusters_post(Req, Params,
                                                                   JustValidate, TriesLeft-1)
                            end;
                        _ ->
                            menelaus_util:reply_json(Req, [])
                    end;
                {errors, Status, Errors} ->
                    menelaus_util:reply_json(Req, {struct, Errors}, Status)
            end;
        {errors, Errors} ->
            menelaus_util:reply_json(Req, {struct, Errors}, 400)
    end.

-spec check_nonempty(string(), binary(), binary()) -> undefined | {binary(), binary()}.
check_nonempty(String, Name, HumanName) ->
    case String of
        undefined -> {Name, iolist_to_binary([HumanName, <<" is missing">>])};
        "" -> {Name, iolist_to_binary([HumanName, <<" cannot be empty">>])};
        _ -> undefined
    end.

validate_remote_cluster_params(Params, ExistingClusters) ->
    Name = proplists:get_value("name", Params),
    Hostname = proplists:get_value("hostname", Params),
    Username = proplists:get_value("username", Params),
    Password = proplists:get_value("password", Params),
    DemandEncryption = proplists:get_value("demandEncryption", Params, "0"),
    Cert = proplists:get_value("certificate", Params, ""),
    NameError = case check_nonempty(Name, <<"name">>, <<"cluster name">>) of
                    X when is_tuple(X) -> X;
                    _ ->
                        if
                            length(Name) > 255 ->
                                {<<"name">>, <<"cluster name cannot be longer than 255 bytes">>};
                            true ->
                                undefined
                        end
                end,
    HostnameError = case check_nonempty(Hostname, <<"hostname">>, <<"hostname (ip)">>) of
                        XH when is_tuple(XH) -> XH;
                        _ ->
                            case screen_hostname_valid(Hostname) of
                                true ->
                                    undefined;
                                _ ->
                                    {<<"hostname">>, <<"hostname (ip) contains invalid characters">>}
                            end
                    end,
    UsernameError = check_nonempty(Username, <<"username">>, <<"username">>),
    PasswordError = check_nonempty(Password, <<"password">>, <<"password">>),
    EncryptionAllowed = menelaus_web:is_xdcr_over_ssl_allowed(),
    EncryptionError = case {DemandEncryption, Cert} of
                          {"0", ""} ->
                              undefined;
                          {"0", _} ->
                              {<<"certificate">>, <<"certificate must not be given if demand encryption is off">>};
                          {_, _} when not EncryptionAllowed ->
                              {<<"demandEncryption">>, <<"encryption can only be used in enterprise edition "
                                                         "when the entire cluster is running at least 2.5 version "
                                                         "of Couchbase Server">>};
                          {_, ""} ->
                              {<<"certificate">>, <<"certificate must be given if demand encryption is on">>};
                          {_, _} ->
                              CertBin = list_to_binary(Cert),
                              OkCert = case (catch ns_server_cert:validate_cert(CertBin)) of
                                           {ok, [_]} -> true;
                                           {ok, [_|_]} -> <<"found multiple certificates instead">>;
                                           {error, non_cert_entries, _} ->
                                               <<"found non-certificate entries">>;
                                           _ ->
                                               <<"failed to parse given certificate">>
                                       end,
                              case OkCert of
                                  true ->
                                      undefined;
                                  _ ->
                                      Err = [<<"certificate must be a single, PEM-encoded x509 certificate and nothing more (">>,
                                             OkCert, $)],
                                      {<<"certificate">>, iolist_to_binary(Err)}
                              end
                      end,
    Errors0 = lists:filter(fun (undefined) -> false;
                               (_) -> true
                           end, [NameError, HostnameError, UsernameError, PasswordError, EncryptionError]),
    Errors = case lists:any(fun (KV) ->
                                    lists:keyfind(name, 1, KV) =:= {name, Name} andalso
                                        proplists:get_value(deleted, KV, false) =:= false
                            end, ExistingClusters) of
                 true ->
                     [{<<"name">>, <<"duplicate cluster names are not allowed">>}
                      | Errors0];
                 _ ->
                     Errors0
             end,
    case Errors of
        [] ->
            BaseKVList = [{name, Name},
                          {hostname, Hostname},
                          {username, Username},
                          {password, Password}],
            KVList = case DemandEncryption of
                         "0" ->
                             BaseKVList;
                         _ ->
                             [{cert, list_to_binary(Cert)} | BaseKVList]
                     end,
            {ok, KVList};
        _ ->
            {errors, Errors}
    end.

screen_hostname_valid([$- | _]) ->
    false;
screen_hostname_valid([]) ->
    false;
screen_hostname_valid(X) -> screen_hostname_valid_tail(X).

valid_hostname_char(C) ->
    ($0 =< C andalso C =< $9)
        orelse ($a =< C andalso C =< $z)
        orelse ($A =< C andalso C =< $Z)
        orelse C =:= $- orelse C =:= $.
        orelse C =:= $:. % : is not permitted by dns, but is valid as part of IPv6 address

screen_hostname_valid_tail([]) -> true;
screen_hostname_valid_tail([C | Rest]) ->
    case valid_hostname_char(C) of
        true ->
            screen_hostname_valid_tail(Rest);
        _ -> false
    end.

handle_remote_cluster_update(Id, Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            Params = Req:parse_post(),
            QS = Req:parse_qs(),
            do_handle_remote_cluster_update(Id, Req, Params, proplists:get_value("just_validate", QS), 10);
        true ->
            goxdcr_rest:proxy(Req)
    end.

do_handle_remote_cluster_update(_Id, _Req, _Params, _JustValidate, _TriesLeft = 0) ->
    erlang:error(cas_retries_exceeded);
do_handle_remote_cluster_update(Id, Req, Params, JustValidate, TriesLeft) ->
    ExistingClusters = get_remote_clusters(),
    {MaybeThisCluster, OtherClusters} = lists:partition(fun (KV) ->
                                                                lists:keyfind(name, 1, KV) =:= {name, Id} andalso
                                                                    proplists:get_value(deleted, KV, false) =:= false
                                                        end, ExistingClusters),
    case MaybeThisCluster of
        [] ->
            menelaus_util:reply_json(Req, <<"unkown remote cluster">>, 404);
        [ThisCluster] ->
            do_handle_remote_cluster_update_found_this(Id, ThisCluster,
                                                       Req, Params, JustValidate, OtherClusters, ExistingClusters, TriesLeft)
    end.

do_handle_remote_cluster_update_found_this(Id, OldCluster, Req, Params, JustValidate,
                                           OtherClusters, ExistingClusters, TriesLeft) ->
    case validate_remote_cluster_params(Params, OtherClusters) of
        {ok, KVList} ->
            case validate_remote_cluster(KVList, OtherClusters) of
                {ok, FinalKVList} ->
                    case JustValidate of
                        undefined ->
                            NewClusters = update_cluster(OldCluster, FinalKVList, OtherClusters),

                            case cas_remote_clusters(ExistingClusters, NewClusters) of
                                ok ->
                                    ns_audit:xdcr_update_cluster_ref(Req, FinalKVList),

                                    OldName = misc:expect_prop_value(name, OldCluster),
                                    OldHostname = misc:expect_prop_value(hostname, OldCluster),

                                    NewName = misc:expect_prop_value(name, FinalKVList),
                                    NewHostName = misc:expect_prop_value(hostname, FinalKVList),

                                    case OldName =:= NewName andalso OldHostname =:= NewHostName of
                                        true ->
                                            ok;
                                        false ->
                                            ale:info(?USER_LOGGER,
                                                     "Remote cluster reference \"~s\" updated.~s~s",
                                                     [OldName,
                                                      case OldName =:= NewName of
                                                          true ->
                                                              "";
                                                          false ->
                                                              io_lib:format(" New name is \"~s\".", [NewName])
                                                      end,
                                                      case OldHostname =:= NewHostName of
                                                          true ->
                                                              "";
                                                          false ->
                                                              io_lib:format(" New contact point is ~s.", [NewHostName])
                                                      end])
                                    end,

                                    menelaus_util:reply_json(
                                      Req, build_remote_cluster_info(FinalKVList, false));
                                _ ->
                                    do_handle_remote_cluster_update(Id, Req, Params,
                                                                    JustValidate, TriesLeft-1)
                            end;
                        _ ->
                            menelaus_util:reply_json(Req, [])
                    end;
                {errors, Status, Errors} ->
                    menelaus_util:reply_json(Req, {struct, Errors}, Status)
            end;
        {errors, Errors} ->
            menelaus_util:reply_json(Req, {struct, Errors}, 400)
    end.

check_remote_cluster_already_exists(RemoteUUID, Clusters) ->
    case lists:dropwhile(
           fun (Cluster) ->
                   UUID = proplists:get_value(uuid, Cluster),
                   true = (UUID =/= undefined),

                   Deleted = proplists:get_value(deleted, Cluster, false),

                   UUID =/= RemoteUUID orelse Deleted =:= true
           end, Clusters) of
        [] ->
            ok;
        [Cluster | _] ->
            Name = proplists:get_value(name, Cluster),
            true = Name =/= undefined,

            [{<<"_">>,
              iolist_to_binary(
                io_lib:format("Cluster reference to the same cluster already "
                              "exists under the name `~s`", [Name]))}]
    end.

%% actually go to remote cluster to verify it; returns updated cluster
%% proplist with uuid being added;
validate_remote_cluster(Cluster, OtherClusters) ->
    ?log_debug("Going to fetch remote cluster info with params:~n~p", [Cluster]),
    case remote_clusters_info:fetch_remote_cluster(Cluster) of
        {ok, #remote_cluster{uuid=RemoteUUID}} ->
            case check_remote_cluster_already_exists(RemoteUUID, OtherClusters) of
                ok ->
                    {ok, [{uuid, RemoteUUID} |
                          lists:keydelete(uuid, 1, Cluster)]};
                Errors ->
                    {errors, 400, Errors}
            end;
        {error, timeout} ->
            Msg = <<"Timeout exceeded when trying to reach remote cluster">>,
            Errors = [{<<"_">>, Msg}],
            {errors, 500, Errors};
        {error, rest_error, Msg, _} ->
            Errors = [{<<"_">>, Msg}],
            {errors, 400, Errors};
        {error, not_capable, Msg} ->
            Errors = [{<<"_">>, Msg}],
            {errors, 400, Errors};
        OtherError ->
            ?log_error("Got unexpected error while fetching remote cluster info: ~p", [OtherError]),
            Errors = [{<<"_">>, <<"Unexpected error occurred. See logs for details.">>}],
            {errors, 500, Errors}
    end.

add_new_cluster(NewCluster, Clusters) ->
    NewClusterUUID = proplists:get_value(uuid, NewCluster),
    true = (NewClusterUUID =/= undefined),

    %% there might be a deleted cluster with the same uuid; we must not leave
    %% a duplicate
    {Matched, Other} =
        lists:partition(
          fun (KV) ->
                  proplists:get_value(uuid, KV) =:= NewClusterUUID
          end, Clusters),

    case Matched of
        [] ->
            [NewCluster | Clusters];
        [MatchedCluster] ->
            true = proplists:get_value(deleted, MatchedCluster),
            [NewCluster | Other]
        %% our invariant is that there's at most one cluster (deleted or not)
        %% with the same UUID in the cluster list; hence other case should not
        %% happen
    end.

update_cluster(OldCluster, NewCluster, OtherClusters) ->
    OldClusterUUID = proplists:get_value(uuid, OldCluster),
    NewClusterUUID = proplists:get_value(uuid, NewCluster),

    true = (OldClusterUUID =/= undefined),
    true = (NewClusterUUID =/= undefined),

    case OldClusterUUID =:= NewClusterUUID of
        true ->
            [NewCluster | OtherClusters];
        false ->
            OldCluster1 = misc:update_proplist(OldCluster,
                                               [{deleted, true}]),
            %% there can still be deleted cluster with the same uuid
            add_new_cluster(NewCluster, [OldCluster1 | OtherClusters])
    end.

handle_remote_cluster_delete(Id, Req) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        false ->
            do_handle_remote_cluster_delete(Id, Req, 10);
        true ->
            goxdcr_rest:proxy(Req)
    end.

do_handle_remote_cluster_delete(_Id, _Req, _TriesLeft = 0) ->
    erlang:error(cas_retries_exceeded);
do_handle_remote_cluster_delete(Id, Req, TriesLeft) ->
    ExistingClusters = get_remote_clusters(),
    {MaybeThisCluster, OtherClusters} =
        lists:partition(fun (KV) ->
                                lists:keyfind(name, 1, KV) =:= {name, Id} andalso
                                    proplists:get_value(deleted, KV, false) =:= false
                        end, ExistingClusters),
    case MaybeThisCluster of
        [] ->
            menelaus_util:reply_json(Req, <<"unknown remote cluster">>, 404);
        [ThisCluster] ->
            DeletedCluster = misc:update_proplist(ThisCluster, [{deleted, true}]),
            NewClusters = [DeletedCluster | OtherClusters],

            case cas_remote_clusters(ExistingClusters, NewClusters) of
                ok ->
                    ns_audit:xdcr_delete_cluster_ref(Req, ThisCluster),

                    Name = misc:expect_prop_value(name, ThisCluster),
                    Hostname = misc:expect_prop_value(hostname, ThisCluster),

                    ale:info(?USER_LOGGER,
                             "Remote cluster reference \"~s\" known via ~s removed.",
                             [Name, Hostname]),

                    menelaus_util:reply_json(Req, ok);
                _ ->
                    do_handle_remote_cluster_delete(Id, Req, TriesLeft-1)
            end
    end.
