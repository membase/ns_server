%% @author Couchbase <info@couchbase.com>
%% @copyright 2012-2014 Couchbase, Inc.
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
-record(remote_node, {host :: string(),
                      port :: integer(),
                      memcached_port :: integer(),
                      ssl_proxy_port :: pos_integer() | undefined | needed_but_unknown,
                      https_port :: pos_integer() | undefined | needed_but_unknown,
                      https_capi_port :: pos_integer() | undefined | needed_but_unknown
                     }).

-record(remote_cluster, {uuid :: binary(),
                         nodes :: [#remote_node{}],
                         cert :: binary() | undefined
                        }).

-type remote_bucket_node() :: {Host :: binary(), MCDPort :: integer()}.

-record(remote_bucket, {name :: binary(),
                        uuid :: binary(),
                        password :: binary(),
                        cluster_uuid :: binary(),
                        cluster_cert :: binary() | undefined,
                        server_list_nodes :: [#remote_node{}],
                        bucket_caps :: [binary()],
                        raw_vbucket_map :: dict(),
                        capi_vbucket_map :: dict(),
                        cluster_version :: {integer(), integer()}}).
