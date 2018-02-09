%% @author Couchbase <info@couchbase.com>
%% @copyright 2015-2018 Couchbase, Inc.
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
-module(menelaus_web_indexes).

-include("ns_common.hrl").
-export([handle_settings_get/1, handle_settings_post/1, handle_index_status/1]).

-import(menelaus_util,
        [reply/2,
         reply_json/2,
         validate_any_value/3,
         validate_by_fun/3,
         validate_one_of/4,
         validate_has_params/1,
         validate_unsupported_params/1,
         validate_integer/2,
         validate_range/4,
         execute_if_validated/3]).

handle_settings_get(Req) ->
    Settings = get_settings(),
    true = (Settings =/= undefined),
    reply_json(Req, {Settings}).

get_settings() ->
    S0 = index_settings_manager:get(generalSettings),
    case cluster_compat_mode:is_cluster_45() of
        true ->
            [{storageMode, index_settings_manager:get(storageMode)}] ++ S0;
        false ->
            S0
    end.

validate_settings_post(Args) ->
    R0 = validate_has_params({Args, [], []}),
    R1 = lists:foldl(
           fun ({Key, Min, Max}, Acc) ->
                   Acc1 = validate_integer(Key, Acc),
                   validate_range(Key, Min, Max, Acc1)
           end, R0, integer_settings()),
    R2 = validate_string(R1, logLevel),
    R3 = case cluster_compat_mode:is_cluster_45() of
             true ->
                 validate_storage_mode(R2);
             false ->
                 R2
         end,

    validate_unsupported_params(R3).

validate_storage_mode(State) ->
    %% Note, at the beginning the storage mode will be empty. Once set,
    %% validate_string will prevent user from changing it back to empty
    %% since it is not one of the acceptable values.
    State1 = validate_string(State, storageMode),

    %% Do not allow:
    %% - setting index storage mode to mem optimized or plasma in community edition
    %% - changing index storage mode in community edition
    %% - changing index storage mode when there are nodes running index
    %%   service in the cluster in enterprise edition.
    %% - changing index storage mode back to forestdb after having it set to either
    %%   memory_optimized or plasma in enterprise edition.
    %% - setting the storage mode to forestdb on a newly configured 5.0 enterprise cluster.
    IndexErr = "Changing the optimization mode of global indexes is not supported when index service nodes are present in the cluster. Please remove all index service nodes to change this option.",

    OldValue = index_settings_manager:get(storageMode),
    validate_by_fun(
      fun (Value) when Value =:= OldValue ->
              ok;
          (Value) ->
              case OldValue =:= <<"">> of
                  true ->
                      is_storage_mode_acceptable(Value);
                  false ->
                      %% Note it is not sufficient to check service_active_nodes(index) because the
                      %% index nodes could be down or failed over. However, we should allow the
                      %% storage mode to be changed if there is an index node in "inactiveAdded"
                      %% state (the state set when a node has been added but the rebalance has not
                      %% been run yet).
                      NodesWanted = ns_node_disco:nodes_wanted(),
                      AllIndexNodes = ns_cluster_membership:service_nodes(NodesWanted, index),
                      InactiveAddedNodes = ns_cluster_membership:inactive_added_nodes(),
                      IndexNodes = AllIndexNodes -- InactiveAddedNodes,

                      case IndexNodes of
                          [] ->
                              is_storage_mode_acceptable(Value);
                          _ ->
                              ?log_debug("Index nodes ~p present. Cannot change index storage mode.~n",
                                         [IndexNodes]),
                              {error, IndexErr}
                      end
              end
      end, storageMode, State1).

is_storage_mode_acceptable(Value) ->
    ReportError = fun(Msg) ->
                          ?log_debug(Msg),
                          {error, Msg}
                  end,

    case Value of
        ?INDEX_STORAGE_MODE_FORESTDB ->
            case cluster_compat_mode:is_cluster_50() andalso
                cluster_compat_mode:is_enterprise() of
                true ->
                    ReportError("Storage mode cannot be set to 'forestdb' in 5.0 enterprise edition.");
                false ->
                    ok
            end;
        ?INDEX_STORAGE_MODE_MEMORY_OPTIMIZED ->
            case cluster_compat_mode:is_enterprise() of
                true ->
                    ok;
                false ->
                    ReportError("Memory optimized indexes are restricted to enterprise edition and "
                                "are not available in the community edition.")
            end;
        ?INDEX_STORAGE_MODE_PLASMA ->
            case cluster_compat_mode:is_cluster_50() andalso
                cluster_compat_mode:is_enterprise() of
                true ->
                    ok;
                false ->
                    ReportError("Storage mode can be set to 'plasma' only if the cluster is "
                                "5.0 enterprise edition.")
            end;
        _ ->
            ReportError(io_lib:format("Invalid value '~s'", [binary_to_list(Value)]))
    end.

acceptable_values(logLevel) ->
    ["silent", "fatal", "error", "warn", "info", "verbose", "timing", "debug",
     "trace"];
acceptable_values(storageMode) ->
    Modes = case cluster_compat_mode:is_enterprise() of
                true ->
                    case cluster_compat_mode:is_cluster_50() of
                        true ->
                            [?INDEX_STORAGE_MODE_PLASMA,
                             ?INDEX_STORAGE_MODE_MEMORY_OPTIMIZED];
                        false ->
                            [?INDEX_STORAGE_MODE_FORESTDB,
                             ?INDEX_STORAGE_MODE_MEMORY_OPTIMIZED]
                    end;
                false ->
                    [?INDEX_STORAGE_MODE_FORESTDB]
            end,
    [binary_to_list(X) || X <- Modes].

validate_string(State, Param) ->
    validate_one_of(Param, acceptable_values(Param), State,
                    fun list_to_binary/1).

update_storage_mode(Req, Values) ->
    case proplists:get_value(storageMode, Values) of
        undefined ->
            Values;
        StorageMode ->
            ok = update_settings(storageMode, StorageMode),
            ns_audit:modify_index_storage_mode(Req, StorageMode),
            proplists:delete(storageMode, Values)
    end.
update_settings(Key, Value) ->
    case index_settings_manager:update(Key, Value) of
        {ok, _} ->
            ok;
        retry_needed ->
            erlang:error(exceeded_retries)
    end.

handle_settings_post(Req) ->
    execute_if_validated(
      fun (Values) ->
              Values1 = case cluster_compat_mode:is_cluster_45() of
                            true ->
                                update_storage_mode(Req, Values);
                            false ->
                                Values
                        end,
              case Values1 of
                  [] ->
                      ok;
                  _ ->
                      ok = update_settings(generalSettings, Values1)
              end,
              reply_json(Req, {get_settings()})
      end, Req, validate_settings_post(Req:parse_post())).

integer_settings() ->
    NearInfinity = 1 bsl 64 - 1,
    [{indexerThreads, 0, 1024},
     {memorySnapshotInterval, 1, NearInfinity},
     {stableSnapshotInterval, 1, NearInfinity},
     {maxRollbackPoints, 1, NearInfinity}].

handle_index_status(Req) ->
    {ok, Indexes0, Stale, Version} = service_index:get_indexes(),
    Indexes = [{Props} || Props <- Indexes0],

    Warnings =
        case Stale of
            true ->
                Msg = <<"Cannot communicate with indexer process. "
                        "Information on indexes may be stale. Will retry.">>,
                [Msg];
            false ->
                []
        end,

    reply_json(Req, {[{indexes, Indexes},
                      {version, Version},
                      {warnings, Warnings}]}).
