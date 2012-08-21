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

-define(XDCR_CHECKPOINT_INTERVAL, 60000).

%% Maximum number of concurrent vbucket replications allowed per doc
-define(MAX_CONCURRENT_REPS_PER_DOC, 32).

%% TODO: maybe make both buffer max sizes configurable
-define(DOC_BUFFER_BYTE_SIZE, 512 * 1024).   %% for remote targets
-define(DOC_BUFFER_LEN, 10).                 %% for local targets, # of documents
-define(MAX_BULK_ATT_SIZE, 64 * 1024).
-define(MAX_BULK_ATTS_PER_DOC, 8).
-define(STATS_DELAY, 10000000).              %% 10 seconds (in microseconds)

%% data structures
-record(rep, {
          id,
          source,
          target,
          options
         }).

-record(rep_state_record, {
          rep,
          starting,
          retries_left,
          max_retries
         }).


-record(rep_vb_status, {
          vb,
          pid,
          status = idle,
          num_changes_left = 0,
          docs_checked = 0,
          docs_written = 0
 }).

-record(rep_state, {
          rep_details,
          status = #rep_vb_status{},
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
          timer, %% checkpoint timer
          workers,
          session_id,
          source_seq = nil
         }).

-record(batch, {
          docs = [],
          size = 0
         }).

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



-record(concurrency_throttle_state, {
          %% token counter
          count,
          %% table of replications waiting to be scheduled
          %% (key = Pid, value = {Signal, TargetNode})
          waiting_reps,
          %% table of active replications
          %% (key = Pid, value = target node replicated to)
          active_reps,
          %% table of load at target node
          %% (key = TargetNode, value = number of active reps on that node)
          target_load,
          %% table of monitoring refs
          %% (key = Pid of reps, value = monitoring reference)
          monitor_dict
         }).
