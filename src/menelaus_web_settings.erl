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

get_bool("true") ->
    {ok, true};
get_bool("false") ->
    {ok, false};
get_bool(_) ->
    invalid.

get_number(Min, Max) ->
    fun (SV) ->
            menelaus_util:parse_validate_number(SV, Min, Max)
    end.

get_number(Min, Max, Default) ->
    fun (SV) ->
            case SV of
                "" ->
                    {ok, Default};
                _ ->
                    menelaus_util:parse_validate_number(SV, Min, Max)
            end
    end.

get_string(SV) ->
    {ok, list_to_binary(string:strip(SV))}.

conf(security) ->
    [{disable_ui_over_http, disableUIOverHttp, false, fun get_bool/1},
     {disable_ui_over_https, disableUIOverHttps, false, fun get_bool/1}];
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
    menelaus_util:reply_json(Req, {Settings}).

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
            menelaus_util:reply_json(Req, []);
        _ ->
            menelaus_util:reply_json(Req, {[{error, X} || X <- Errors]}, 400)
    end.
