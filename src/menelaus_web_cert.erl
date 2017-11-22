%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
%% @doc REST api's for handling ssl certificates

-module(menelaus_web_cert).

-include("ns_common.hrl").

-export([handle_cluster_certificate/1,
         handle_regenerate_certificate/1,
         handle_upload_cluster_ca/1,
         handle_reload_node_certificate/1,
         handle_get_node_certificate/2,
         handle_client_cert_auth_settings/1,
         handle_client_cert_auth_settings_post/1]).

handle_cluster_certificate(Req) ->
    menelaus_util:assert_is_enterprise(),

    case proplists:get_value("extended", Req:parse_qs()) of
        "true" ->
            handle_cluster_certificate_extended(Req);
        _ ->
            handle_cluster_certificate_simple(Req)
    end.

handle_cluster_certificate_simple(Req) ->
    Cert = case ns_server_cert:cluster_ca() of
               {GeneratedCert, _} ->
                   GeneratedCert;
               {UploadedCAProps, _, _} ->
                   proplists:get_value(pem, UploadedCAProps)
           end,
    menelaus_util:reply_ok(Req, "text/plain", Cert).

format_time(UTCSeconds) ->
    LocalTime = calendar:universal_time_to_local_time(
                  calendar:gregorian_seconds_to_datetime(UTCSeconds)),
    menelaus_util:format_server_time(LocalTime, 0).

warning_props({expires_soon, UTCSeconds}) ->
    [{message, ns_error_messages:node_certificate_warning(expires_soon)},
     {expires, format_time(UTCSeconds)}];
warning_props(Warning) ->
    [{message, ns_error_messages:node_certificate_warning(Warning)}].

translate_warning({Node, Warning}) ->
    [{node, Node} | warning_props(Warning)];
translate_warning(Warning) ->
    warning_props(Warning).

jsonify_cert_props(Props) ->
    lists:map(fun ({expires, UTCSeconds}) ->
                      {expires, format_time(UTCSeconds)};
                  ({K, V}) when is_list(V) ->
                      {K, list_to_binary(V)};
                  (Pair) ->
                      Pair
              end, Props).

handle_cluster_certificate_extended(Req) ->
    {Cert, WarningsJson} =
        case ns_server_cert:cluster_ca() of
            {GeneratedCert, _} ->
                {[{type, generated},
                  {pem, GeneratedCert}], [{translate_warning(self_signed)}]};
            {UploadedCAProps, _, _} ->
                Warnings = ns_server_cert:get_warnings(UploadedCAProps),
                {[{type, uploaded} | UploadedCAProps],
                 [{translate_warning(Pair)} || Pair <- Warnings]}
        end,
    menelaus_util:reply_json(Req, {[{cert, {jsonify_cert_props(Cert)}},
                                    {warnings, WarningsJson}]}).

handle_regenerate_certificate(Req) ->
    menelaus_util:assert_is_enterprise(),

    ns_server_cert:generate_and_set_cert_and_pkey(),
    ns_ssl_services_setup:sync_local_cert_and_pkey_change(),
    ?log_info("Completed certificate regeneration"),
    ns_audit:regenerate_certificate(Req),
    handle_cluster_certificate_simple(Req).

reply_error(Req, Error) ->
    menelaus_util:reply_json(
      Req, {[{error, ns_error_messages:cert_validation_error_message(Error)}]}, 400).

handle_upload_cluster_ca(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_45(),

    case Req:recv_body() of
        undefined ->
            reply_error(Req, empty_cert);
        PemEncodedCA ->
            case ns_server_cert:set_cluster_ca(PemEncodedCA) of
                {ok, Props} ->
                    ns_audit:upload_cluster_ca(Req,
                                               proplists:get_value(subject, Props),
                                               proplists:get_value(expires, Props)),
                    handle_cluster_certificate_extended(Req);
                {error, Error} ->
                    reply_error(Req, Error)
            end
    end.

handle_reload_node_certificate(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_45(),

    case ns_server_cert:apply_certificate_chain_from_inbox() of
        {ok, Props} ->
            ns_audit:reload_node_certificate(Req,
                                             proplists:get_value(subject, Props),
                                             proplists:get_value(expires, Props)),
            menelaus_util:reply(Req, 200);
        {error, Error} ->
            ?log_error("Error reloading node certificate: ~p", [Error]),
            menelaus_util:reply_json(
              Req, ns_error_messages:reload_node_certificate_error(Error), 400)
    end.

handle_get_node_certificate(NodeId, Req) ->
    menelaus_util:assert_is_enterprise(),

    case menelaus_web_node:find_node_hostname(NodeId, Req) of
        {ok, Node} ->
            case ns_server_cert:get_node_cert_info(Node) of
                [] ->
                    menelaus_util:reply_text(Req, <<"Certificate is not set up on this node">>, 404);
                Props ->
                    menelaus_util:reply_json(Req, {jsonify_cert_props(Props)})
            end;
        false ->
            menelaus_util:reply_text(
              Req,
              <<"Node is not found, make sure the ip address/hostname matches the ip address/hostname used by Couchbase">>,
              404)
    end.

allowed_values(Key) ->
    Values = [{"state", ["enable", "disable", "mandatory"]},
             {"path", ["subject.cn", "san.uri", "san.dnsname", "san.email"]},
             {"prefix", any},
             {"delimiter", any}],
    proplists:get_value(Key, Values, none).

handle_client_cert_auth_settings(Req) ->
    Val = ns_ssl_services_setup:client_cert_auth(),
    menelaus_util:reply_json(Req, {[{K, list_to_binary(V)} || {K,V} <- Val]}).

validate_client_cert_auth_settings({Key, Val}, Params, OldVal, Acc) ->
    case Key == "state" andalso Val =/= "disable" of
        true ->
            case {proplists:get_value("path", Params), proplists:get_value(path, OldVal)} of
                {undefined, undefined} ->
                    [{error, {400, io_lib:format("'path' must be defined when 'state' is "
                                                 "being set to '~s'", [Val])}}] ++ Acc;
                _ ->
                    Acc
            end;
        false ->
            Acc
    end.

handle_client_cert_auth_settings_post(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_50(),
    Params = Req:parse_post(),
    OldVal = ns_ssl_services_setup:client_cert_auth(),
    AccumulateChanges =
        fun({Key, Val} = Pair, Acc) ->
                case allowed_values(Key) of
                    none ->
                        [{error, {400, io_lib:format("Invalid key: '~s'", [Key])}}]
                            ++ Acc;
                    Values ->
                        Acc1 = validate_client_cert_auth_settings(Pair, Params, OldVal, Acc),
                        case Values == any orelse lists:member(Val, Values) of
                            true ->
                                NewKey = list_to_atom(Key),
                                case proplists:get_value(NewKey, OldVal) =/= Val of
                                    true ->
                                        [{NewKey, Val}] ++ Acc1;
                                    _Else ->
                                        Acc1
                                end;
                            Invalid ->
                                [{error, {400, io_lib:format("Invalid value '~s' "
                                                             "for key '~s'",
                                                             [Invalid, Key])
                                         }
                                 }] ++ Acc1
                        end
                end
        end,
    KeyChanged = lists:foldl(AccumulateChanges, [], Params),
    case proplists:get_value(error, KeyChanged, none) of
        none when length(KeyChanged) > 0 ->
            NewValue = lists:ukeysort(1, KeyChanged ++ OldVal),
            ns_config:set(client_cert_auth, NewValue),
            ns_audit:client_cert_auth(Req, NewValue),
            menelaus_util:reply(Req, 202);
        {Code, Error} ->
            menelaus_util:reply_json(Req, list_to_binary(Error), Code);
        _Else ->
            menelaus_util:reply(Req, 200)
    end.
