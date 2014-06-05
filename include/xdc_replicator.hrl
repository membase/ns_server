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

%% rate of replicaiton stat maintained in bucket replicator
-record(ratestat, {
          timestamp = now(),
          item_replicated = 0,
          data_replicated = 0,
          curr_rate_item = 0,
          curr_rate_data = 0
}).

%% vbucket replication status and statistics, used by xdc_vbucket_rep
-record(rep_vb_status, {
          vb,
          pid,
          status = idle,

          %% following stats initialized to 0 when vb replicator starts, and refreshed
          %% when update stat to bucket replicator. The bucket replicator is responsible
          %% for aggretating the statistics for each vb. These stats may be from different
          %% vb replicator processes. We do not need to persist these stats in checkpoint
          %% doc. Consequently the lifetime of these stats at vb replicator level is the
          %% same as that of its parent vb replicator process.

          %% # of docs have been checked for eligibility of replication
          docs_checked = 0,
          %% of docs have been replicated
          docs_written = 0,
          %% of docs have been replicated optimistically
          docs_opt_repd = 0,
          %% bytes of data replicated
          data_replicated = 0,
          %% num of checkpoints issued successfully
          num_checkpoints = 0,
          %% total num of failed checkpoints
          num_failedckpts = 0,
          work_time = 0, % in MS
          commit_time = 0,  % in MS

          %% following stats are handled differently from above. They will not be
          %% aggregated at bucket replicator, instead, each vb replicator will
          %% fetch these stats from couchdb and worker_queue, and publish them
          %% directly to bucket replicator

          %% # of docs to replicate
          num_changes_left = 0,
          %% num of docs in changes queue
          docs_changes_queue = 0,
          %% size of changes queues
          size_changes_queue = 0,

          %% following are per vb stats since the replication starts
          %% from the very beginning. They are persisted in the checkpoint
          %% documents and may span the lifetime of multiple vb replicators
          %% for the same vbucket
          total_docs_checked = 0,
          total_docs_written = 0,
          total_docs_opt_repd = 0,
          total_data_replicated = 0,

          %% latency stats
          meta_latency_aggr = 0,
          meta_latency_wt = 0,
          docs_latency_aggr = 0,
          docs_latency_wt = 0,

          %% worker stats
          workers_stat = dict:new() %% dict of each worker's latency stats (key = pid, value = #worker_stat{})
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

%% bucket level replication state used by module xdc_replication
-record(replication, {
          rep = #rep{},                    % the basic replication settings
          mode,                            % replication mode
          vbucket_sup,                     % the supervisor for vb replicators
          vbs = [],                        % list of vb we should be replicating
          num_tokens = 0,                  % number of available tokens used by throttles
          init_throttle,                   % limits # of concurrent vb replicators initializing
          work_throttle,                   % limits # of concurrent vb replicators working
          num_active = 0,                  % number of active replicators
          num_waiting = 0,                 % number of waiting replicators
          vb_rep_dict = dict:new(),        % contains state and stats for each replicator

          %% rate of replication
          ratestat = #ratestat{},
          %% history of last N errors
          error_reports = ringbuffer:new(?XDCR_ERROR_HISTORY),
          %% history of last N checkpoints
          checkpoint_history = ringbuffer:new(?XDCR_CHECKPOINT_HISTORY)
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
          source,                               % note: only used by old path
          target,
          src_master_db,
          local_vbuuid,                         % note: only used by old path
          remote_vbopaque :: term(),
          start_seq,
          committed_seq,
          current_through_seq,
          current_through_snapshot_seq,
          current_through_snapshot_end_seq,
          last_stream_end_seq = 0,
          source_cur_seq,
          upr_failover_uuid :: non_neg_integer(),
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
          source,                  %note: only used by old path
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
