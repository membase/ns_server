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

-module(metakv).

-include("ns_common.hrl").
-include("ns_config.hrl").

-export([get/1,
         set/2, set/3,
         delete/1,
         delete_matching/1,
         mutate/3,
         iterate_matching/1, iterate_matching/2]).

%% Exported APIs

get(Key) ->
    case which_store(Key) of
        simple_store ->
            simple_store_get(Key);
        ns_config ->
            ns_config:search_with_vclock(ns_config:get(), {metakv, Key})
    end.

set(Key, Value) ->
    mutate(Key, Value, undefined).

set(Key, Value, Rev) ->
    mutate(Key, Value, Rev).

delete(Key) ->
    mutate(Key, ?DELETED_MARKER, undefined).

%% Create, update or delete the specified key.
%% For delete, Value is set to ?DELETED_MARKER.
mutate(Key, Value, Rev) ->
    case which_store(Key) of
        simple_store ->
            %% Simple store does not support revisions.
            simple_store_mutation(Key, Value);
        ns_config ->
            ns_config_mutation(Key, Value, Rev)
    end.

%% Delete key with the matching prefix
delete_matching(KeyPrefix) ->
    case which_store(KeyPrefix) of
        simple_store ->
            simple_store:delete_matching(?XDCR_CHECKPOINT_STORE, KeyPrefix);
        ns_config ->
            ns_config_delete_matching(KeyPrefix)
    end.

%% Read keys from appropriate store and return KVs that match the prefix
iterate_matching(KeyPrefix) ->
    case which_store(KeyPrefix) of
        simple_store ->
            simple_store:iterate_matching(?XDCR_CHECKPOINT_STORE, KeyPrefix);
        ns_config ->
            ns_config_iterate_matching(KeyPrefix)
    end.

%% User has passed the full KV list, we need to return KVs that match the
%% prefix.
iterate_matching(KeyPrefix, KVList) ->
    matching_kvs(KeyPrefix, KVList).

%% Internal

%% Currently, we have only two storage options:
%% 1. simple store for XDCR checkpoints.
%% 2. ns_config for everything else.
%%
%% Today, metakv uses simple store only for XDCR checkpoints.
%% In future, if simple_store has other metakv consumers,
%% then this module will need to take that into account.
%% Note, non-metakv consumers can use simple-store directly by using
%% the APIs in simple_store module.

which_store(Key) ->
    case misc:is_prefix(?XDCR_CHECKPOINT_PATTERN, Key) of
        true ->
            simple_store;
        _ ->
            ns_config
    end.

%% Simple Store related functions

simple_store_get(K) ->
    case simple_store:get(?XDCR_CHECKPOINT_STORE, K) of
        false ->
            false;
        V ->
            {value, V}
    end.

simple_store_mutation(Key, Value) ->
    case Value =:= ?DELETED_MARKER of
        true ->
            simple_store:delete(?XDCR_CHECKPOINT_STORE, Key);
        false ->
            simple_store:set(?XDCR_CHECKPOINT_STORE, Key, Value)
    end.

%% NS Config related functions

ns_config_mutation(Key, Value, Rev) ->
    K = {metakv, Key},
    work_queue:submit_sync_work(
      metakv_worker,
      fun () ->
              case Rev =:= undefined of
                  true ->
                      ns_config:set(K, Value),
                      ok;
                  false ->
                      RV = ns_config:run_txn(
                             fun (Cfg, SetFn) ->
                                     OldVC = get_old_vclock(Cfg, K),
                                     case Rev =:= OldVC of
                                         true ->
                                             {commit, SetFn(K, Value, Cfg)};
                                         false ->
                                             {abort, mismatch}
                                     end
                             end),
                      case RV of
                          {commit, _} ->
                              %% don't send whole config back
                              %% from worker
                              ok;
                          _ ->
                              RV
                      end
              end
      end).

get_old_vclock(Cfg, K) ->
    case ns_config:search_with_vclock(Cfg, K) of
        false ->
            missing;
        {value, OldV, OldVC} ->
            case OldV of
                ?DELETED_MARKER ->
                    missing;
                _ ->
                    OldVC
            end
    end.

ns_config_delete_matching(Key) ->
    Filter = mk_config_filter(Key),
    RV = ns_config:run_txn(
           fun (Cfg, SetFn) ->
                   KeysToDelete = [K || {K, V} <- hd(Cfg), Filter(K),
                                        ns_config:strip_metadata(V) =/= ?DELETED_MARKER],
                   NewCfg = lists:foldl(
                              fun (K, AccCfg) ->
                                      SetFn(K, ?DELETED_MARKER, AccCfg)
                              end,
                              Cfg, KeysToDelete),
                   {commit, NewCfg}
           end),
    case RV of
        {commit, _} ->
            ok;
        _ ->
            RV
    end.

mk_config_filter(KeyBin) ->
    KeyL = size(KeyBin),
    fun ({metakv, K}) when is_binary(K) ->
            case K of
                <<KeyBin:KeyL/binary, _/binary>> ->
                    true;
                _ ->
                    false
            end;
        (_K) ->
            false
    end.

ns_config_iterate_matching(Key) ->
    KVs = matching_kvs(Key, ns_config:get_kv_list()),
    %% This function gets called during first iteration of
    %% menelaus_metakv:handle_iterate(). Skip deleted entries for
    %% the first iteration. This will retain the behaviour as it existed
    %% before this code was moved here from menelaus_metakv.erl.
    [{K, V} || {K, V} <- KVs, ns_config:strip_metadata(V) =/= ?DELETED_MARKER].

matching_kvs(Key, KVList) ->
    Filter = mk_config_filter(Key),
    %% This function gets called during subsequent iteration of
    %% menelaus_metakv:handle_iterate(). Do not skip deleted entries.
    %% This will retain the behaviour as it existed
    %% before this code was moved here from menelaus_metakv.erl.
    [{K, V} || {K, V} <- KVList, Filter(K)].
