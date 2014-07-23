%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

-ifndef(_XDC_COMMON__HRL_).
-define(_XDC_COMMON__HRL_,).

%% couchdb headers
-include("couch_db.hrl").
-include("couch_api_wrap.hrl").

%% ns_server headers
-include("ns_common.hrl").

%% ------------------------------------%%
%%  constants and macros used by XDCR  %%
%% ------------------------------------%%
%% capture the last 10 entries of checkpoint history per bucket replicator
-define(XDCR_CHECKPOINT_HISTORY, 10).
%% capture the last 10 entries of error history per bucket replicator
-define(XDCR_ERROR_HISTORY, 10).
%% interval (millisecs) to compute rate stats
-define(XDCR_RATE_STAT_INTERVAL_MS, 1000).
%% sleep time in secs before retry
-define(XDCR_SLEEP_BEFORE_RETRY, 30).
%% constants used by XMEM
-define(XDCR_XMEM_CONNECTION_ATTEMPTS, 16).
-define(XDCR_XMEM_CONNECTION_TIMEOUT, 120000).  %% timeout in ms
%% builder of error/warning/debug msgs
-define(format_msg(Msg, Args), lists:flatten(io_lib:format(Msg, Args))).

%% concurrency throttle type
-define(XDCR_INIT_CONCUR_THROTTLE, "xdcr-init").
-define(XDCR_REPL_CONCUR_THROTTLE, "xdcr-repl").

-define(x_trace(Type, KV), case ale:is_loglevel_enabled(?XDCR_TRACE_LOGGER, info) of
                               false -> ok;
                               true -> ale:xlog(?XDCR_TRACE_LOGGER, info, {self(), Type, KV}, [])
                           end).
-define(x_trace_enabled(), ale:is_loglevel_enabled(?XDCR_TRACE_LOGGER, info)).

%% -------------------------%%
%%   XDCR data structures   %%
%% -------------------------%%

%% replication settings used by bucket level and vbucket level replicators
-record(rep, {
          id,
          source,
          target,
          replication_mode,
          options
         }).

-record(xdcr_stats_sample, {id,
                            data_replicated = 0,
                            docs_checked = 0,
                            docs_written = 0,
                            docs_opt_repd = 0,
                            activations = 0,
                            worker_batches = 0,
                            worker_batch_latency = 0,
                            succeeded_checkpoints = 0,
                            failed_checkpoints = 0,
                            work_time = 0,
                            commit_time = 0,
                            get_meta_batches = 0,
                            get_meta_latency = 0,
                            set_meta_batches = 0,
                            set_meta_latency = 0
                           }).

-record(xdcr_vb_stats_sample, {id_and_vb,
                               vbucket_seqno = 0,
                               through_seqno = 0}).

%% vbucket replication status and statistics, used by xdc_vbucket_rep
-record(rep_vb_status, {
          vb,
          pid,
          status = idle
 }).

%% vbucket checkpoint status used by each vbucket replicator and status reporting
%% to bucket replicator
-record(rep_checkpoint_status, {
          %% timestamp of the checkpoint from now() with granularity of microsecond, used
          %% as key for ordering
          ts,
          time,   % human readable local time
          vb,     % vbucket id
          succ    % true if a succesful checkpoint, false otherwise
 }).

%% batch of documents usd by vb replicator worker process
-record(batch, {
          docs = [],
          size = 0,
          items = 0
         }).

%% vbucket level replication state used by module xdc_vbucket_rep
-record(rep_state, {
          rep_details = #rep{},
          %% vbreplication stats
          status = #rep_vb_status{},
          %% time the vb replicator intialized
          rep_start_time,

          %% remote node
          xmem_remote,
          xmem_location,

          throttle,
          parent,
          source_name,
          target_name,
          target,
          src_master_db,
          remote_vbopaque :: term(),
          start_seq,
          committed_seq,
          current_through_seq,
          current_through_snapshot_seq,
          current_through_snapshot_end_seq,
          last_stream_end_seq = 0,
          source_cur_seq,
          dcp_failover_uuid :: non_neg_integer(),
          seqs_in_progress = [],
          highest_seq_done = ?LOWEST_SEQ,
          highest_seq_done_snapshot = {?LOWEST_SEQ, ?LOWEST_SEQ},
          rep_starttime,
          timer = nil, %% checkpoint timer

          %% timer to account the working time, reset every time we publish stats to
          %% bucket replicator
          work_start_time,
          last_checkpoint_time,
          workers,
          changes_queue,

          %% a boolean variable indicating that the rep has already
          %% behind db purger, at least one deletion has been lost.
          behind_purger,

          ckpt_api_request_base
         }).

%% vbucket replicator worker process state used by xdc_vbucket_rep_worker
-record(rep_worker_state, {
          cp,
          loop,
          max_parallel_conns,
          source,
          target,
          readers = [],
          writer = nil,
          pending_fetch = nil,
          flush_waiter = nil,
          source_db_compaction_notifier = nil,
          target_db_compaction_notifier = nil,
          batch = #batch{}
         }).

%% options to start xdc replication worker process
-record(rep_worker_option, {
          worker_id,               %% unique id of worker process starting from 1
          cp,                      %% parent vb replicator process
          source_bucket,
          target = #httpdb{},      %% target db
          changes_manager,         %% process to queue changes from storage
          max_conns,               %% max connections
          xmem_location,           %% XMem location
          opt_rep_threshold,       %% optimistic replication threshold
          batch_size,              %% batch size (in bytes)
          batch_items              %% batch items
         }).

%% statistics reported from worker process to its parent vbucket replicator
-record(worker_stat, {
          worker_id,
          seq = 0,
          snapshot_start_seq = 0,
          snapshot_end_seq = 0,
          worker_meta_latency_aggr = 0,
          worker_docs_latency_aggr = 0,
          worker_data_replicated = 0,
          worker_item_checked = 0,
          worker_item_replicated = 0,
          worker_item_opt_repd = 0
         }).

%%-----------------------------------------%%
%%            XDCR-MEMCACHED               %%
%%-----------------------------------------%%
% statistics
-record(xdc_vb_rep_xmem_statistics, {
          item_replicated = 0,
          data_replicated = 0,
          ckpt_issued = 0,
          ckpt_failed = 0
          }).

%% information needed talk to remote memcached
-record(xdc_rep_xmem_remote, {
          ip, %% inet:ip_address(),
          port, %% inet:port_number(),
          bucket = "default",
          vb,
          username = "_admin",
          password = "_admin",
          options = []
         }).

%% xmem server state
-record(xdc_vb_rep_xmem_srv_state, {
          vb,
          parent_vb_rep,
          num_workers,
          pid_workers,
          statistics = #xdc_vb_rep_xmem_statistics{},
          remote = #xdc_rep_xmem_remote{},
          seed,
          error_reports
         }).

%% xmem worker state
-record(xdc_xmem_location, {
          vb,
          connection_timeout,
          mcd_loc
         }).


-endif.

%% end of xdc_replicator.hrl
