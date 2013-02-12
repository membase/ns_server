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

%% couchdb headers
-include("couch_db.hrl").
-include("couch_js_functions.hrl").
-include("couch_api_wrap.hrl").
-include("../lhttpc/lhttpc.hrl").

%% ns_server headers
-include("ns_common.hrl").
-include("replication_infos_ddoc.hrl").

%% imported functions
-import(couch_util, [
                     get_value/2,
                     get_value/3,
                     to_binary/1
                    ]).

%% constants used by XDCR
-define(REP_ID_VERSION, 2).
%% capture the last 10 entries of checkpoint history per bucket replicator
-define(XDCR_CHECKPOINT_HISTORY, 10).
%% capture the last 10 entries of error history per bucket replicator
-define(XDCR_ERROR_HISTORY, 10).
%% interval (secs) to compute rate stats
-define(XDCR_RATE_STAT_INTERVAL, 1).

%% data structures

%% replication settings used by bucket level and vbucket level replicators
-record(rep, {
          id,
          source,
          target,
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
          total_data_replicated = 0,

          %% rate of replication
          ratestat = #ratestat{}
 }).

%% vbucket checkpoint status used by each vbucket replicator and status reporting
%% to bucket replicator
-record(rep_checkpoint_status, {
          %% timestamp of the checkpoint from now() with granularity of microsecond, used
          %% as key for ordering
          ts,
          time,   % human readable local time
          vb,     % vbucket id
          succ,   % true if a succesful checkpoint, false otherwise
          error   % error msg
 }).

%% batch of documents usd by vb replicator worker process
-record(batch, {
          docs = [],
          size = 0
         }).

%% bucket level replication state used by module xdc_replication
-record(replication, {
          rep = #rep{},                    % the basic replication settings
          vbucket_sup,                     % the supervisor for vb replicators
          vbs = [],                        % list of vb we should be replicating
          init_throttle,                   % limits # of concurrent vb replicators initializing
          work_throttle,                   % limits # of concurrent vb replicators working
          num_active = 0,                  % number of active replicators
          num_waiting = 0,                 % number of waiting replicators
          vb_rep_dict = dict:new(),        % contains state and stats for each replicator

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
          throttle,
          parent,
          source_name,
          target_name,
          source,
          target,
          src_master_db,
          tgt_master_db,
          history,
          checkpoint_history,
          start_seq,
          committed_seq,
          current_through_seq,
          source_cur_seq,
          seqs_in_progress = [],
          highest_seq_done = ?LOWEST_SEQ,
          source_log,
          target_log,
          rep_starttime,
          src_starttime,
          tgt_starttime,
          timer = nil, %% checkpoint timer

          %% timer to account the working time, reset every time we publish stats to
          %% bucket replicator
          work_start_time,
          last_checkpoint_time,
          workers,
          changes_queue,
          session_id,
          source_seq = nil
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

%% concurrency throttle state used by module concurrency_throttle
-record(concurrency_throttle_state, {
          %% parent process creating the throttle server
          parent,
          %% token counter
          count,
          %% table of waiting requests to be scheduled
          %% (key = Pid, value = {Signal, LoadKey})
          waiting_pool,
          %% table of active, scheduled requests
          %% (key = Pid, value = LoadKey)
          active_pool,
          %% table of load at target node
          %% (key = TargetNode, value = number of active requests on that node)
          target_load,
          %% table of monitoring refs
          %% (key = Pid, value = monitoring reference)
          monitor_dict
         }).
