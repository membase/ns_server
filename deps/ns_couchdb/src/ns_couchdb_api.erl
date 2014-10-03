%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
%% @doc api that contains almost everything (with the exception of compaction_api)
%%      that ns_server node calls on ns_couchdb node
%%

-module(ns_couchdb_api).

-include("ns_common.hrl").
-include("couch_db.hrl").

-export([set_db_and_ix_paths/2,
         get_db_and_ix_paths/0,
         get_tasks/0,
         restart_couch/0,
         delete_couch_database/1,
         fetch_stats/0,
         fetch_couch_stats/1,
         delete_databases_and_files/1,
         wait_index_updated/2,
         initiate_indexing/1,
         set_vbucket_states/3,
         reset_master_vbucket/1,
         get_design_doc_signatures/1,
         foreach_doc/3,
         update_doc/2,
         get_doc/2,

         get_master_vbucket_size/1,
         start_master_vbucket_compact/1,
         cancel_master_vbucket_compact/1,
         start_view_compact/4,
         cancel_view_compact/3,
         try_to_cleanup_indexes/1,
         get_view_group_data_size/2,
         get_safe_purge_seqs/1,

         link_to_doc_mgr/3]).

-export([handle_rpc/1]).

-export([handle_link/3]).

-define(RPC_TIMEOUT, infinity).

-spec get_db_and_ix_paths() -> [{db_path | index_path, string()}].
get_db_and_ix_paths() ->
    maybe_rpc_couchdb_node(get_db_and_ix_paths).

-spec set_db_and_ix_paths(DbPath :: string(), IxPath :: string()) -> ok.
set_db_and_ix_paths(DbPath0, IxPath0) ->
    maybe_rpc_couchdb_node({set_db_and_ix_paths, DbPath0, IxPath0}).

get_tasks() ->
    maybe_rpc_couchdb_node(get_tasks).

restart_couch() ->
    maybe_rpc_couchdb_node(restart_couch).

delete_couch_database(DB) ->
    maybe_rpc_couchdb_node({delete_couch_database, DB}).

fetch_stats() ->
    maybe_rpc_couchdb_node(fetch_stats).

fetch_couch_stats(BucketName) ->
    maybe_rpc_couchdb_node({fetch_couch_stats, BucketName}).

delete_databases_and_files(Bucket) ->
    maybe_rpc_couchdb_node({delete_databases_and_files, Bucket}).

wait_index_updated(Bucket, VBucket) ->
    maybe_rpc_couchdb_node({wait_index_updated, Bucket, VBucket}).

initiate_indexing(Bucket) ->
    maybe_rpc_couchdb_node({initiate_indexing, Bucket}).

set_vbucket_states(Bucket, WantedVBuckets, RebalanceVBuckets) ->
    maybe_rpc_couchdb_node({set_vbucket_states, Bucket, WantedVBuckets, RebalanceVBuckets}).

reset_master_vbucket(Bucket) ->
    maybe_rpc_couchdb_node({reset_master_vbucket, Bucket}).

get_design_doc_signatures(Bucket) ->
    maybe_rpc_couchdb_node({get_design_doc_signatures, Bucket}).

-spec foreach_doc(ext_bucket_name() | xdcr,
                  fun ((tuple()) -> any()),
                  non_neg_integer() | infinity) -> [{binary(), any()}].
foreach_doc(Bucket, Fun, Timeout) ->
    maybe_rpc_couchdb_node({foreach_doc, Bucket, Fun, Timeout}).

update_doc(Bucket, Doc) ->
    maybe_rpc_couchdb_node({update_doc, Bucket, Doc}).

-spec get_doc(ext_bucket_name() | xdcr, binary()) -> {ok, #doc{}} | {not_found, atom()}.
get_doc(Bucket, Id) ->
    maybe_rpc_couchdb_node({get_doc, Bucket, Id}).

get_master_vbucket_size(Bucket) ->
    maybe_rpc_couchdb_node({get_master_vbucket_size, Bucket}).

start_master_vbucket_compact(Bucket) ->
    maybe_rpc_couchdb_node({start_master_vbucket_compact, Bucket}).

cancel_master_vbucket_compact(Db) ->
    maybe_rpc_couchdb_node({cancel_master_vbucket_compact, Db}).

start_view_compact(Bucket, DDocId, Type, InitialStatus) ->
    maybe_rpc_couchdb_node({start_view_compact, Bucket, DDocId, Type, InitialStatus}).

cancel_view_compact(Bucket, DDocId, Type) ->
    maybe_rpc_couchdb_node({cancel_view_compact, Bucket, DDocId, Type}).

try_to_cleanup_indexes(BucketName) ->
    maybe_rpc_couchdb_node({try_to_cleanup_indexes, BucketName}).

get_view_group_data_size(BucketName, DDocId) ->
    maybe_rpc_couchdb_node({get_view_group_data_size, BucketName, DDocId}).

get_safe_purge_seqs(BucketName) ->
    maybe_rpc_couchdb_node({get_safe_purge_seqs, BucketName}).

-spec link_to_doc_mgr(atom(), ext_bucket_name() | xdcr, pid()) -> {ok, pid()} | {badrpc, any()}.
link_to_doc_mgr(Type, Bucket, Pid) ->
    maybe_rpc_couchdb_node({link_to_doc_mgr, Type, Bucket, Pid}).

maybe_rpc_couchdb_node(Request) ->
    ThisNode = node(),
    case ns_node_disco:couchdb_node() of
        ThisNode ->
            handle_rpc(Request);
        Node ->
            rpc_couchdb_node(1, Node, Request)
    end.

rpc_couchdb_node(Try, Node, Request) ->
    RV = rpc:call(Node, ?MODULE, handle_rpc, [Request], ?RPC_TIMEOUT),
    NotYet = case RV of
                 {badrpc, nodedown} ->
                     true;
                 {badrpc, {'EXIT', {noproc, _}}} ->
                     true;
                 {badrpc, {'EXIT', retry}} ->
                     true;
                 _ ->
                     false
             end,
    case {Try, NotYet} of
        {600, true} -> %% 10 minutes
            Stack = try throw(42) catch 42 -> erlang:get_stacktrace() end,
            ?log_debug("RPC to couchdb node failed for ~p with ~p~nStack: ~p", [Request, RV, Stack]),
            RV;
        {_, true} ->
            retry_rpc_couchdb_node(Try, Node, Request);
        {_, false} ->
            RV
    end.

retry_rpc_couchdb_node(Try, Node, Request) ->
    ?log_debug("Wait for couchdb node to be able to serve ~p. Attempt ~p", [Request, Try]),
    receive
        {'EXIT', Pid, Reason} ->
            ?log_debug("Received exit from ~p with reason ~p", [Pid, Reason]),
            exit(Reason)
    after 1000 ->
            ok
    end,
    rpc_couchdb_node(Try + 1, Node, Request).

handle_rpc(get_db_and_ix_paths) ->
    try
        cb_config_couch_sync:get_db_and_ix_paths()
    catch
        error:badarg ->
            exit(retry)
    end;
handle_rpc({set_db_and_ix_paths, DbPath0, IxPath0}) ->
    try
        cb_config_couch_sync:set_db_and_ix_paths(DbPath0, IxPath0)
    catch
        error:badarg ->
            exit(retry)
    end;
handle_rpc(get_tasks) ->
    couch_task_status:all();
handle_rpc(restart_couch) ->
    cb_couch_sup:restart_couch();
handle_rpc({delete_couch_database, DB}) ->
    ns_couchdb_storage:delete_couch_database(DB);
handle_rpc(fetch_stats) ->
    ns_couchdb_stats_collector:get_stats();
handle_rpc({fetch_couch_stats, BucketName}) ->
    couch_stats_reader:fetch_stats(BucketName);
handle_rpc({delete_databases_and_files, Bucket}) ->
    ns_couchdb_storage:delete_databases_and_files(Bucket);
handle_rpc({initiate_indexing, Bucket}) ->
    capi_set_view_manager:initiate_indexing(Bucket);
handle_rpc({wait_index_updated, Bucket, VBucket}) ->
    capi_set_view_manager:wait_index_updated(Bucket, VBucket);
handle_rpc({set_vbucket_states, BucketName, WantedVBuckets, RebalanceVBuckets}) ->
    capi_set_view_manager:set_vbucket_states(BucketName,
                                             WantedVBuckets,
                                             RebalanceVBuckets);
handle_rpc({reset_master_vbucket, BucketName}) ->
    capi_set_view_manager:reset_master_vbucket(BucketName);

handle_rpc({get_design_doc_signatures, Bucket}) ->
    try
        capi_utils:get_design_doc_signatures(Bucket)
    catch
        error:badarg ->
            exit(retry)
    end;

handle_rpc({foreach_doc, xdcr, Fun, Timeout}) ->
    xdc_rdoc_manager:foreach_doc(Fun, Timeout);
handle_rpc({foreach_doc, Bucket, Fun, Timeout}) ->
    capi_set_view_manager:foreach_doc(Bucket, Fun, Timeout);

handle_rpc({update_doc, xdcr, Doc}) ->
    xdc_rdoc_manager:update_doc(Doc);
handle_rpc({update_doc, Bucket, #doc{id = <<"_local/", _/binary>> = Id} = Doc}) ->
    capi_frontend:with_master_vbucket(
      Bucket,
      fun (DB) ->
              ok = couch_db:update_doc(DB, #doc{id = Id, body = Doc})
      end);
handle_rpc({update_doc, Bucket, Doc}) ->
    capi_set_view_manager:update_doc(Bucket, Doc);

handle_rpc({get_doc, xdcr, Id}) ->
    xdc_rdoc_manager:get_doc(Id);
handle_rpc({get_doc, Bucket, <<"_local/", _/binary>> = Id}) ->
    capi_frontend:with_master_vbucket(
      Bucket,
      fun (DB) ->
              couch_db:open_doc_int(DB, Id, [ejson_body])
      end);

handle_rpc({get_master_vbucket_size, Bucket}) ->
    capi_frontend:with_master_vbucket(
      Bucket,
      fun (Db) ->
              {ok, DbInfo} = couch_db:get_db_info(Db),

              {proplists:get_value(data_size, DbInfo, 0),
               proplists:get_value(disk_size, DbInfo)}
      end);

handle_rpc({start_master_vbucket_compact, Bucket}) ->
    capi_frontend:with_master_vbucket(
      Bucket,
      fun (Db) ->
              {ok, Compactor} = couch_db:start_compact(Db, [dropdeletes]),
              %% return Db here assuming that Db#db.update_pid is alive and well
              %% after the Db is closed
              {ok, Compactor, Db}
      end);

handle_rpc({cancel_master_vbucket_compact, Db}) ->
    couch_db:cancel_compact(Db);

handle_rpc({start_view_compact, Bucket, DDocId, Type, InitialStatus}) ->
    couch_set_view_compactor:start_compact(mapreduce_view, Bucket,
                                           DDocId, Type, prod,
                                           InitialStatus);

handle_rpc({cancel_view_compact, Bucket, DDocId, Type}) ->
    couch_set_view_compactor:cancel_compact(mapreduce_view,
                                            Bucket, DDocId,
                                            Type, prod);

handle_rpc({try_to_cleanup_indexes, BucketName}) ->
    ?log_info("Cleaning up indexes for bucket `~s`", [BucketName]),

    try
        couch_set_view:cleanup_index_files(mapreduce_view, BucketName)
    catch SetViewT:SetViewE ->
            ?log_error("Error while doing cleanup of old "
                       "index files for bucket `~s`: ~p~n~p",
                       [BucketName, {SetViewT, SetViewE}, erlang:get_stacktrace()])
    end,

    try
        couch_set_view:cleanup_index_files(spatial_view, BucketName)
    catch SpatialT:SpatialE ->
            ?log_error("Error while doing cleanup of old "
                       "spatial index files for bucket `~s`: ~p~n~p",
                       [BucketName, {SpatialT, SpatialE}, erlang:get_stacktrace()])
    end;

handle_rpc({get_view_group_data_size, BucketName, DDocId}) ->
    couch_set_view:get_group_data_size(mapreduce_view, BucketName, DDocId);

handle_rpc({get_safe_purge_seqs, BucketName}) ->
    capi_set_view_manager:get_safe_purge_seqs(BucketName);

handle_rpc({link_to_doc_mgr, Type, xdcr, Pid}) ->
    case xdc_rdoc_manager:link(Type, Pid) of
        retry ->
            exit(retry);
        RV ->
            RV
    end;
handle_rpc({link_to_doc_mgr, Type, Bucket, Pid}) ->
    case capi_set_view_manager:link(Type, Bucket, Pid) of
        retry ->
            exit(retry);
        RV ->
            RV
    end.

handle_link(Pid, N, State) ->
    OldPid = element(N, State),
    handle_link(Pid, OldPid, N, State).

handle_link(Pid, undefined, N, State) ->
    erlang:link(Pid),
    {reply, {ok, self()}, setelement(N, State, Pid)};
handle_link(_Pid, OldPid, _N, State) ->
    ?log_debug("Process already linked to ~p. Retry", [OldPid]),
    {reply, retry, State}.
