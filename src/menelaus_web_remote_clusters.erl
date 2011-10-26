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

-export([get_remote_clusters/0,
         get_remote_clusters/1,
         handle_remote_clusters/1,
         handle_remote_clusters_post/1,
         handle_remote_cluster_update/2,
         handle_remote_cluster_delete/2]).

get_remote_clusters(Config) ->
    case ns_config:search(Config, remote_clusters) of
        {value, X} -> X;
        false -> []
    end.

get_remote_clusters() ->
    get_remote_clusters(ns_config:get()).

cas_remote_clusters(Old, NewUnsorted) ->
    New = lists:sort(NewUnsorted),
    case ns_config:update_key(remote_clusters,
                              fun (V) ->
                                      case V of
                                          Old -> New;
                                          _ ->
                                              erlang:throw(mismatch)
                                      end
                              end) of
        ok -> ok;
        {throw, mismatch, _} -> mismatch
    end.

build_remote_cluster_info(KV) ->
    Name = misc:expect_prop_value(name, KV),
    URI = list_to_binary(menelaus_util:concat_url_path(["pools", "default", "remoteClusters", Name])),
    {struct, [{name, list_to_binary(Name)},
              {uri, URI},
              {validateURI, iolist_to_binary([URI, <<"?just_validate=1">>])},
              {hostname, list_to_binary(misc:expect_prop_value(hostname, KV))},
              {username, list_to_binary(misc:expect_prop_value(username, KV))}]}.

handle_remote_clusters(Req) ->
    RemoteClusters = get_remote_clusters(),
    JSON = lists:map(fun build_remote_cluster_info/1, RemoteClusters),
    menelaus_util:reply_json(Req, JSON).

handle_remote_clusters_post(Req) ->
    Params = Req:parse_post(),
    QS = Req:parse_qs(),
    do_handle_remote_clusters_post(Req, Params, proplists:get_value("just_validate", QS), 10).

do_handle_remote_clusters_post(_Req, _Params, _JustValidate, _TriesLeft = 0) ->
    erlang:error(cas_retries_exceeded);
do_handle_remote_clusters_post(Req, Params, JustValidate, TriesLeft) ->
    ExistingClusters = get_remote_clusters(),
    case validate_remote_cluster_params(Params, ExistingClusters) of
        {ok, KVList} ->
            case JustValidate of
                undefined ->
                    NewClusters = [KVList | ExistingClusters],
                    case cas_remote_clusters(ExistingClusters, NewClusters) of
                        ok -> menelaus_util:reply_json(Req, build_remote_cluster_info(KVList));
                        _ -> do_handle_remote_clusters_post(Req, Params, JustValidate, TriesLeft-1)
                    end;
                _ ->
                    menelaus_util:reply_json(Req, [])
            end;
        {errors, Errors} ->
            menelaus_util:reply_json(Req, Errors, 400)
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
    Errors0 = lists:filter(fun (undefined) -> false;
                              (_) -> true
                          end, [NameError, HostnameError, UsernameError, PasswordError]),
    Errors = case lists:any(fun (KV) ->
                                    lists:keyfind(name, 1, KV) =:= {name, Name}
                            end, ExistingClusters) of
                 true ->
                     [{<<"name">>, <<"duplicate cluster names are not allowed">>}
                      | Errors0];
                 _ ->
                     Errors0
             end,
    case Errors of
        [] ->
            {ok, [{name, Name},
                  {hostname, Hostname},
                  {username, Username},
                  {password, Password}]};
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
    Params = Req:parse_post(),
    QS = Req:parse_qs(),
    do_handle_remote_cluster_update(Id, Req, Params, proplists:get_value("just_validate", QS), 10).

do_handle_remote_cluster_update(_Id, _Req, _Params, _JustValidate, _TriesLeft = 0) ->
    erlang:error(cas_retries_exceeded);
do_handle_remote_cluster_update(Id, Req, Params, JustValidate, TriesLeft) ->
    ExistingClusters = get_remote_clusters(),
    {MaybeThisCluster, OtherClusters} = lists:partition(fun (KV) ->
                                                                lists:keyfind(name, 1, KV) =:= {name, Id}
                                                        end, ExistingClusters),
    case MaybeThisCluster of
        [] ->
            menelaus_util:reply_json(Req, <<"unkown remote cluster">>, 404);
        _ ->
            do_handle_remote_cluster_update_found_this(Id, Req, Params, JustValidate, OtherClusters, ExistingClusters, TriesLeft)
    end.

do_handle_remote_cluster_update_found_this(Id, Req, Params, JustValidate, OtherClusters, ExistingClusters, TriesLeft) ->
    case validate_remote_cluster_params(Params, OtherClusters) of
        {ok, KVList} ->
            case JustValidate of
                undefined ->
                    NewClusters = [KVList | OtherClusters],
                    case cas_remote_clusters(ExistingClusters, NewClusters) of
                        ok -> menelaus_util:reply_json(Req, build_remote_cluster_info(KVList));
                        _ -> do_handle_remote_cluster_update(Id, Req, Params, JustValidate, TriesLeft-1)
                    end;
                _ ->
                    menelaus_util:reply_json(Req, [])
            end;
        {errors, Errors} ->
            menelaus_util:reply_json(Req, Errors, 400)
    end.

handle_remote_cluster_delete(Id, Req) ->
    do_handle_remote_cluster_delete(Id, Req, 10).

do_handle_remote_cluster_delete(_Id, _Req, _TriesLeft = 0) ->
    erlang:error(cas_retries_exceeded);
do_handle_remote_cluster_delete(Id, Req, TriesLeft) ->
    ExistingClusters = get_remote_clusters(),
    {MaybeThisCluster, OtherClusters} = lists:partition(fun (KV) ->
                                                                lists:keyfind(name, 1, KV) =:= {name, Id}
                                                        end, ExistingClusters),
    case MaybeThisCluster of
        [] ->
            menelaus_util:reply_json(Req, <<"unknown remote cluster">>, 404);
        _ ->
            case cas_remote_clusters(ExistingClusters, OtherClusters) of
                ok -> menelaus_util:reply_json(Req, ok);
                _ -> do_handle_remote_cluster_delete(Id, Req, TriesLeft-1)
            end
    end.
