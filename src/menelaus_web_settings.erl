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

-export([build_internal_settings_kvs/0,
         handle_internal_settings/1,
         handle_internal_settings_post/1]).

internal_settings_conf() ->
    GetBool = fun (SV) ->
                      case SV of
                          "true" -> {ok, true};
                          "false" -> {ok, false};
                          _ -> invalid
                      end
              end,

    GetNumber = fun (Min, Max) ->
                        fun (SV) ->
                                menelaus_util:parse_validate_number(SV, Min, Max)
                        end
                end,
    GetNumberOrEmpty = fun (Min, Max, Empty) ->
                               fun (SV) ->
                                       case SV of
                                           "" -> Empty;
                                           _ ->
                                               menelaus_util:parse_validate_number(SV, Min, Max)
                                       end
                               end
                       end,
    GetString = fun (SV) ->
                        {ok, list_to_binary(string:strip(SV))}
                end,

    [{index_aware_rebalance_disabled, indexAwareRebalanceDisabled, false, GetBool},
     {rebalance_index_waiting_disabled, rebalanceIndexWaitingDisabled, false, GetBool},
     {index_pausing_disabled, rebalanceIndexPausingDisabled, false, GetBool},
     {rebalance_ignore_view_compactions, rebalanceIgnoreViewCompactions, false, GetBool},
     {rebalance_moves_per_node, rebalanceMovesPerNode, 1, GetNumber(1, 1024)},
     {rebalance_moves_before_compaction, rebalanceMovesBeforeCompaction, 64, GetNumber(1, 1024)},
     {{couchdb, max_parallel_indexers}, maxParallelIndexers, <<>>, GetNumber(1, 1024)},
     {{couchdb, max_parallel_replica_indexers}, maxParallelReplicaIndexers, <<>>, GetNumber(1, 1024)},
     {max_bucket_count, maxBucketCount, 10, GetNumber(1, 8192)},
     {{request_limit, rest}, restRequestLimit, undefined, GetNumberOrEmpty(0, 99999, {ok, undefined})},
     {{request_limit, capi}, capiRequestLimit, undefined, GetNumberOrEmpty(0, 99999, {ok, undefined})},
     {drop_request_memory_threshold_mib, dropRequestMemoryThresholdMiB, undefined,
      GetNumberOrEmpty(0, 99999, {ok, undefined})},
     {gotraceback, gotraceback, <<"crash">>, GetString},
     {{auto_failover_disabled, index}, indexAutoFailoverDisabled, true, GetBool},
     {{cert, use_sha1}, certUseSha1, false, GetBool}] ++
        case cluster_compat_mode:is_goxdcr_enabled() of
            false ->
                [{{xdcr, max_concurrent_reps}, xdcrMaxConcurrentReps, 32, GetNumber(1, 256)},
                 {{xdcr, checkpoint_interval}, xdcrCheckpointInterval, 1800, GetNumber(60, 14400)},
                 {{xdcr, worker_batch_size}, xdcrWorkerBatchSize, 500, GetNumber(500, 10000)},
                 {{xdcr, doc_batch_size_kb}, xdcrDocBatchSizeKb, 2048, GetNumber(10, 100000)},
                 {{xdcr, failure_restart_interval}, xdcrFailureRestartInterval, 30, GetNumber(1, 300)},
                 {{xdcr, optimistic_replication_threshold}, xdcrOptimisticReplicationThreshold, 256,
                  GetNumberOrEmpty(0, 20*1024*1024, undefined)},
                 {xdcr_anticipatory_delay, xdcrAnticipatoryDelay, 0, GetNumber(0, 99999)}];
            true ->
                []
        end.

build_internal_settings_kvs() ->
    Conf = internal_settings_conf(),
    [{JK, case ns_config:read_key_fast(CK, DV) of
              undefined ->
                  DV;
              V ->
                  V
          end}
     || {CK, JK, DV, _} <- Conf].

handle_internal_settings(Req) ->
    InternalSettings = lists:filter(
                         fun ({_, undefined}) ->
                                 false;
                             (_) ->
                                 true
                         end, build_internal_settings_kvs()),
    menelaus_util:reply_json(Req, {InternalSettings}).

handle_internal_settings_post(Req) ->
    Conf = [{CK, atom_to_list(JK), JK, Parser} ||
               {CK, JK, _, Parser} <- internal_settings_conf()],
    Params = Req:parse_post(),
    CurrentValues = build_internal_settings_kvs(),
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
                    ns_audit:internal_settings(Req, ToSet)
            end,
            menelaus_util:reply_json(Req, []);
        _ ->
            menelaus_util:reply_json(Req, {[{error, X} || X <- Errors]}, 400)
    end.
