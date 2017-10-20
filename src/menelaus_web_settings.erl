%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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
%% @doc handlers for settings related REST API's

-module(menelaus_web_settings).

-include("ns_common.hrl").

-export([build_kvs/1,
         handle_get/2,
         handle_post/2]).

-export([handle_settings_web/1,
         handle_settings_web_post/1,

         handle_settings_alerts/1,
         handle_settings_alerts_post/1,
         handle_settings_alerts_send_test_email/1,
         handle_reset_alerts/1,

         handle_settings_stats/1,
         handle_settings_stats_post/1,

         handle_settings_auto_reprovision/1,
         handle_settings_auto_reprovision_post/1,
         handle_settings_auto_reprovision_reset_count/1,

         handle_settings_max_parallel_indexers/1,
         handle_settings_max_parallel_indexers_post/1,

         handle_settings_view_update_daemon/1,
         handle_settings_view_update_daemon_post/1,

         handle_settings_audit/1,
         handle_settings_audit_post/1]).

-import(menelaus_util,
        [parse_validate_number/3,
         is_valid_positive_integer/1,
         parse_validate_port_number/1,
         reply_json/2,
         reply_json/3,
         reply_text/3,
         reply/2,
         validate_has_params/1,
         validate_boolean/2,
         validate_dir/2,
         validate_integer/2,
         validate_range/5,
         validate_range/4,
         validate_by_fun/3,
         validate_any_value/2,
         validate_unsupported_params/1,
         execute_if_validated/3]).

get_bool("true") ->
    {ok, true};
get_bool("false") ->
    {ok, false};
get_bool(_) ->
    invalid.

get_number(Min, Max) ->
    fun (SV) ->
            parse_validate_number(SV, Min, Max)
    end.

get_number(Min, Max, Default) ->
    fun (SV) ->
            case SV of
                "" ->
                    {ok, Default};
                _ ->
                    parse_validate_number(SV, Min, Max)
            end
    end.

get_string(SV) ->
    {ok, list_to_binary(string:strip(SV))}.

conf(security) ->
    [{disable_ui_over_http, disableUIOverHttp, false, fun get_bool/1},
     {disable_ui_over_https, disableUIOverHttps, false, fun get_bool/1},
     {ui_session_timeout, uiSessionTimeout, undefined, get_number(60, 1000000, undefined)}];
conf(internal) ->
    [{index_aware_rebalance_disabled, indexAwareRebalanceDisabled, false, fun get_bool/1},
     {rebalance_index_waiting_disabled, rebalanceIndexWaitingDisabled, false, fun get_bool/1},
     {index_pausing_disabled, rebalanceIndexPausingDisabled, false, fun get_bool/1},
     {rebalance_ignore_view_compactions, rebalanceIgnoreViewCompactions, false, fun get_bool/1},
     {rebalance_moves_per_node, rebalanceMovesPerNode, 1, get_number(1, 1024)},
     {rebalance_moves_before_compaction, rebalanceMovesBeforeCompaction, 64, get_number(1, 1024)},
     {{couchdb, max_parallel_indexers}, maxParallelIndexers, <<>>, get_number(1, 1024)},
     {{couchdb, max_parallel_replica_indexers}, maxParallelReplicaIndexers, <<>>, get_number(1, 1024)},
     {max_bucket_count, maxBucketCount, 10, get_number(1, 8192)},
     {{request_limit, rest}, restRequestLimit, undefined, get_number(0, 99999, undefined)},
     {{request_limit, capi}, capiRequestLimit, undefined, get_number(0, 99999, undefined)},
     {drop_request_memory_threshold_mib, dropRequestMemoryThresholdMiB, undefined,
      get_number(0, 99999, undefined)},
     {gotraceback, gotraceback, <<"crash">>, fun get_string/1},
     {{auto_failover_disabled, index}, indexAutoFailoverDisabled, true, fun get_bool/1},
     {{cert, use_sha1}, certUseSha1, false, fun get_bool/1}] ++
        case cluster_compat_mode:is_goxdcr_enabled() of
            false ->
                [{{xdcr, max_concurrent_reps}, xdcrMaxConcurrentReps, 32, get_number(1, 256)},
                 {{xdcr, checkpoint_interval}, xdcrCheckpointInterval, 1800, get_number(60, 14400)},
                 {{xdcr, worker_batch_size}, xdcrWorkerBatchSize, 500, get_number(500, 10000)},
                 {{xdcr, doc_batch_size_kb}, xdcrDocBatchSizeKb, 2048, get_number(10, 100000)},
                 {{xdcr, failure_restart_interval}, xdcrFailureRestartInterval, 30, get_number(1, 300)},
                 {{xdcr, optimistic_replication_threshold}, xdcrOptimisticReplicationThreshold, 256,
                  get_number(0, 20*1024*1024, undefined)},
                 {xdcr_anticipatory_delay, xdcrAnticipatoryDelay, 0, get_number(0, 99999)}];
            true ->
                []
        end.

build_kvs(Type) ->
    Conf = conf(Type),
    [{JK, case ns_config:read_key_fast(CK, DV) of
              undefined ->
                  DV;
              V ->
                  V
          end}
     || {CK, JK, DV, _} <- Conf].

handle_get(Type, Req) ->
    Settings = lists:filter(
                 fun ({_, undefined}) ->
                         false;
                     (_) ->
                         true
                 end, build_kvs(Type)),
    reply_json(Req, {Settings}).

audit_fun(Type) ->
    list_to_atom(atom_to_list(Type) ++ "_settings").

handle_post(Type, Req) ->
    Conf = [{CK, atom_to_list(JK), JK, Parser} ||
               {CK, JK, _, Parser} <- conf(Type)],
    Params = Req:parse_post(),
    CurrentValues = build_kvs(Type),
    {ToSet, Errors} =
        lists:foldl(
          fun ({SJK, SV}, {ListToSet, ListErrors}) ->
                  case lists:keyfind(SJK, 2, Conf) of
                      {CK, SJK, JK, Parser} ->
                          case Parser(SV) of
                              {ok, V} ->
                                  case proplists:get_value(JK, CurrentValues) of
                                      V ->
                                          {ListToSet, ListErrors};
                                      _ ->
                                          {[{CK, V} | ListToSet], ListErrors}
                                  end;
                              _ ->
                                  {ListToSet,
                                   [iolist_to_binary(io_lib:format("~s is invalid", [SJK])) | ListErrors]}
                          end;
                      false ->
                          {ListToSet,
                           [iolist_to_binary(io_lib:format("Unknown key ~s", [SJK])) | ListErrors]}
                  end
          end, {[], []}, Params),

    case Errors of
        [] ->
            case ToSet of
                [] ->
                    ok;
                _ ->
                    ns_config:set(ToSet),
                    AuditFun = audit_fun(Type),
                    ns_audit:AuditFun(Req, ToSet)
            end,
            reply_json(Req, []);
        _ ->
            reply_json(Req, {[{error, X} || X <- Errors]}, 400)
    end.

handle_settings_max_parallel_indexers(Req) ->
    Config = ns_config:get(),

    GlobalValue =
        case ns_config:search(Config, {couchdb, max_parallel_indexers}) of
            false ->
                null;
            {value, V} ->
                V
        end,
    ThisNodeValue =
        case ns_config:search_node(node(), Config, {couchdb, max_parallel_indexers}) of
            false ->
                null;
            {value, V2} ->
                V2
        end,

    reply_json(Req, {struct, [{globalValue, GlobalValue},
                              {nodes, {struct, [{node(), ThisNodeValue}]}}]}).

handle_settings_max_parallel_indexers_post(Req) ->
    Params = Req:parse_post(),
    V = proplists:get_value("globalValue", Params, ""),
    case parse_validate_number(V, 1, 1024) of
        {ok, Parsed} ->
            ns_config:set({couchdb, max_parallel_indexers}, Parsed),
            handle_settings_max_parallel_indexers(Req);
        Error ->
            reply_json(
              Req, {struct, [{'_', iolist_to_binary(io_lib:format("Invalid globalValue: ~p", [Error]))}]}, 400)
    end.

handle_settings_view_update_daemon(Req) ->
    {value, Config} = ns_config:search(set_view_update_daemon),

    UpdateInterval = proplists:get_value(update_interval, Config),
    UpdateMinChanges = proplists:get_value(update_min_changes, Config),
    ReplicaUpdateMinChanges = proplists:get_value(replica_update_min_changes, Config),

    true = (UpdateInterval =/= undefined),
    true = (UpdateMinChanges =/= undefined),
    true = (UpdateMinChanges =/= undefined),

    reply_json(Req, {struct, [{updateInterval, UpdateInterval},
                              {updateMinChanges, UpdateMinChanges},
                              {replicaUpdateMinChanges, ReplicaUpdateMinChanges}]}).

handle_settings_view_update_daemon_post(Req) ->
    Params = Req:parse_post(),

    {Props, Errors} =
        lists:foldl(
          fun ({Key, RestKey}, {AccProps, AccErrors} = Acc) ->
                  Raw = proplists:get_value(RestKey, Params),

                  case Raw of
                      undefined ->
                          Acc;
                      _ ->
                          case parse_validate_number(Raw, 0, undefined) of
                              {ok, Value} ->
                                  {[{Key, Value} | AccProps], AccErrors};
                              Error ->
                                  Msg = io_lib:format("Invalid ~s: ~p",
                                                      [RestKey, Error]),
                                  {AccProps, [{RestKey, iolist_to_binary(Msg)}]}
                          end
                  end
          end, {[], []},
          [{update_interval, "updateInterval"},
           {update_min_changes, "updateMinChanges"},
           {replica_update_min_changes, "replicaUpdateMinChanges"}]),

    case Errors of
        [] ->
            {value, CurrentProps} = ns_config:search(set_view_update_daemon),
            MergedProps = misc:update_proplist(CurrentProps, Props),
            ns_config:set(set_view_update_daemon, MergedProps),
            handle_settings_view_update_daemon(Req);
        _ ->
            reply_json(Req, {struct, Errors}, 400)
    end.

handle_settings_web(Req) ->
    reply_json(Req, build_settings_web()).

build_settings_web() ->
    Port = proplists:get_value(port, menelaus_web:webconfig()),
    User = case ns_config_auth:get_user(admin) of
               undefined ->
                   "";
               U ->
                   U
           end,
    {struct, [{port, Port},
              {username, list_to_binary(User)}]}.

%% @doc Settings to en-/disable stats sending to some remote server
handle_settings_stats(Req) ->
    reply_json(Req, {struct, build_settings_stats()}).

build_settings_stats() ->
    Defaults = default_settings_stats_config(),
    [{send_stats, SendStats}] = ns_config:search_prop(
                                  ns_config:get(), settings, stats, Defaults),
    [{sendStats, SendStats}].

default_settings_stats_config() ->
    [{send_stats, false}].

handle_settings_stats_post(Req) ->
    PostArgs = Req:parse_post(),
    SendStats = proplists:get_value("sendStats", PostArgs),
    case validate_settings_stats(SendStats) of
        error ->
            reply_text(Req, "The value of \"sendStats\" must be true or false.", 400);
        SendStats2 ->
            ns_config:set(settings, [{stats, [{send_stats, SendStats2}]}]),
            reply(Req, 200)
    end.

validate_settings_stats(SendStats) ->
    case SendStats of
        "true" -> true;
        "false" -> false;
        _ -> error
    end.

%% @doc Settings to en-/disable auto-reprovision
handle_settings_auto_reprovision(Req) ->
    menelaus_util:assert_is_50(),

    Config = build_settings_auto_reprovision(),
    Enabled = proplists:get_value(enabled, Config),
    MaxNodes = proplists:get_value(max_nodes, Config),
    Count = proplists:get_value(count, Config),
    reply_json(Req, {struct, [{enabled, Enabled},
                              {max_nodes, MaxNodes},
                              {count, Count}]}).

build_settings_auto_reprovision() ->
    {value, Config} = ns_config:search(ns_config:get(), auto_reprovision_cfg),
    Config.

handle_settings_auto_reprovision_post(Req) ->
    menelaus_util:assert_is_50(),

    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    Enabled = proplists:get_value("enabled", PostArgs),
    MaxNodes = proplists:get_value("maxNodes", PostArgs),
    case {ValidateOnly,
          validate_settings_auto_reprovision(Enabled, MaxNodes)} of
        {false, [true, MaxNodes2]} ->
            auto_reprovision:enable(MaxNodes2),
            reply(Req, 200);
        {false, false} ->
            auto_reprovision:disable(),
            reply(Req, 200);
        {false, {error, Errors}} ->
            Errors2 = [<<Msg/binary, "\n">> || {_, Msg} <- Errors],
            reply_text(Req, Errors2, 400);
        {true, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 200);
        %% Validation only and no errors
        {true, _}->
            reply_json(Req, {struct, [{errors, null}]}, 200)
    end.

validate_settings_auto_reprovision(Enabled, MaxNodes) ->
    Enabled2 = case Enabled of
        "true" -> true;
        "false" -> false;
        _ -> {enabled, <<"The value of \"enabled\" must be true or false">>}
    end,
    case Enabled2 of
        true ->
            case is_valid_positive_integer(MaxNodes) of
                true ->
                    [Enabled2, list_to_integer(MaxNodes)];
                false ->
                    {error, [{maxNodes,
                              <<"The value of \"maxNodes\" must be a positive integer">>}]}
            end;
        false ->
            Enabled2;
        Error ->
            {error, [Error]}
    end.

%% @doc Resets the number of nodes that were automatically reprovisioned to zero
handle_settings_auto_reprovision_reset_count(Req) ->
    menelaus_util:assert_is_50(),

    auto_reprovision:reset_count(),
    reply(Req, 200).

is_valid_port_number_or_error("SAME") -> true;
is_valid_port_number_or_error(StringPort) ->
    case (catch parse_validate_port_number(StringPort)) of
        {error, [Error]} ->
            Error;
        _ ->
            true
    end.

is_port_free("SAME") ->
    true;
is_port_free(Port) ->
    ns_bucket:is_port_free(list_to_integer(Port)).

validate_settings(Port, U, P) ->
    case lists:all(fun erlang:is_list/1, [Port, U, P]) of
        false -> [<<"All parameters must be given">>];
        _ -> Candidates = [is_valid_port_number_or_error(Port),
                           is_port_free(Port)
                           orelse <<"Port is already in use">>,
                           case {U, P} of
                               {[], _} -> <<"Username and password are required.">>;
                               {[_Head | _], P} ->
                                   case menelaus_web_rbac:validate_cred(U, username) of
                                       true ->
                                           menelaus_web_rbac:validate_cred(P, password);
                                       Msg ->
                                           Msg
                                   end
                           end],
             lists:filter(fun (E) -> E =/= true end,
                          Candidates)
    end.

%% These represent settings for a cluster.  Node settings should go
%% through the /node URIs
handle_settings_web_post(Req) ->
    menelaus_web_rbac:assert_no_users_upgrade(),

    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",

    Port = proplists:get_value("port", PostArgs),
    U = proplists:get_value("username", PostArgs),
    P = proplists:get_value("password", PostArgs),
    case validate_settings(Port, U, P) of
        [_Head | _] = Errors ->
            reply_json(Req, Errors, 400);
        [] ->
            case ValidateOnly of
                true ->
                    reply(Req, 200);
                false ->
                    do_handle_settings_web_post(Port, U, P, Req)
            end
    end.

do_handle_settings_web_post(Port, U, P, Req) ->
    PortInt = case Port of
                  "SAME" -> proplists:get_value(port, menelaus_web:webconfig());
                  _      -> list_to_integer(Port)
              end,
    case Port =/= PortInt orelse ns_config_auth:credentials_changed(admin, U, P) of
        false -> ok; % No change.
        true ->
            menelaus_web_buckets:maybe_cleanup_old_buckets(),
            ns_config:set(rest, [{port, PortInt}]),
            ns_config_auth:set_credentials(admin, U, P),
            case ns_config:search(uuid) of
                false ->
                    Uuid = couch_uuids:random(),
                    ns_config:set(uuid, Uuid);
                _ ->
                    ok
            end,
            ns_audit:password_change(Req, {U, admin}),

            menelaus_ui_auth:reset()

            %% No need to restart right here, as our ns_config
            %% event watcher will do it later if necessary.
    end,
    {PureHostName, _} = misc:split_host_port(Req:get_header_value("host"), ""),
    NewHost = misc:maybe_add_brackets(PureHostName) ++ ":" ++ integer_to_list(PortInt),
    %% TODO: detect and support https when time will come
    reply_json(Req, {struct, [{newBaseUri, list_to_binary("http://" ++ NewHost ++ "/")}]}).

handle_settings_alerts(Req) ->
    {value, Config} = ns_config:search(email_alerts),
    reply_json(Req, {struct, menelaus_alert:build_alerts_json(Config)}).

handle_settings_alerts_post(Req) ->
    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    case {ValidateOnly, menelaus_alert:parse_settings_alerts_post(PostArgs)} of
        {false, {ok, Config}} ->
            ns_config:set(email_alerts, Config),
            ns_audit:alerts(Req, Config),
            reply(Req, 200);
        {false, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400);
        {true, {ok, _}} ->
            reply_json(Req, {struct, [{errors, null}]}, 200);
        {true, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 200)
    end.

%% @doc Sends a test email with the current settings
handle_settings_alerts_send_test_email(Req) ->
    PostArgs = Req:parse_post(),
    Subject = proplists:get_value("subject", PostArgs),
    Body = proplists:get_value("body", PostArgs),
    PostArgs1 = [{K, V} || {K, V} <- PostArgs,
                           not lists:member(K, ["subject", "body"])],
    {ok, Config} = menelaus_alert:parse_settings_alerts_post(PostArgs1),

    case ns_mail:send(Subject, Body, Config) of
        ok ->
            reply(Req, 200);
        {error, Reason} ->
            Msg =
                case Reason of
                    {_, _, {error, R}} ->
                        R;
                    {_, _, R} ->
                        R;
                    R ->
                        R
                end,

            reply_json(Req, {struct, [{error, couch_util:to_binary(Msg)}]}, 400)
    end.

handle_reset_alerts(Req) ->
    Params = Req:parse_qs(),
    Token = list_to_binary(proplists:get_value("token", Params, "")),
    reply_json(Req, menelaus_web_alerts_srv:consume_alerts(Token)).

handle_settings_audit(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_40(),

    Props = ns_audit_cfg:get_global(),
    Json = lists:map(fun ({K, V}) when is_list(V) ->
                             {K, list_to_binary(V)};
                         (Other) ->
                             Other
                     end, Props),
    reply_json(Req, {Json}).

validate_settings_audit(Args) ->
    R = validate_has_params({Args, [], []}),
    R0 = validate_boolean(auditdEnabled, R),
    R1 = validate_dir(logPath, validate_any_value(logPath, R0)),
    R2 = validate_integer(rotateInterval, R1),
    R3 = validate_range(
           rotateInterval, 15*60, 60*60*24*7,
           fun (Name, _Min, _Max) ->
                   io_lib:format("The value of ~p must be in range from 15 minutes to 7 days",
                                 [Name])
           end, R2),
    R4 = validate_by_fun(
           fun (Value) ->
                   case Value rem 60 of
                       0 ->
                           ok;
                       _ ->
                           {error, "Value must not be a fraction of minute"}
                   end
           end, rotateInterval, R3),
    R5 = validate_integer(rotateSize, R4),
    R6 = validate_range(rotateSize, 0, 500*1024*1024, R5),
    validate_unsupported_params(R6).

handle_settings_audit_post(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_40(),

    Args = Req:parse_post(),
    execute_if_validated(fun (Values) ->
                                 ns_audit_cfg:set_global(Values),
                                 reply(Req, 200)
                         end, Req, validate_settings_audit(Args)).
