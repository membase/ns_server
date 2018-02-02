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
-record(dcp_packet, {
          opcode :: non_neg_integer(),
          datatype = 0 :: non_neg_integer(),
          vbucket = 0 :: non_neg_integer(),
          status = 0 :: non_neg_integer(),
          opaque = 0 :: non_neg_integer(),
          cas = 0:: non_neg_integer(),
          ext = <<>> :: binary(),
          key = <<>> :: binary(),
          body = <<>> :: binary()
}).

-record(dcp_mutation, {id,
                       local_seq,
                       rev,
                       body,
                       datatype,
                       deleted,
                       snapshot_start_seq,
                       snapshot_end_seq
}).

-type callback_arg() :: #dcp_mutation{} | {failover_id, term()} | stream_end.
-type callback_fun() :: fun((callback_arg(), any()) -> {ok, any()} | {stop, any()}).

-define(XDCR_DCP_BUFFER_SIZE, 1048576).
