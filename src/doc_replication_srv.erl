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
%% @doc entry point for document replicators from other nodes. resides
%%      on ns_server nodes, accepts pushed document changes from document
%%      replicators from other nodes and forwards them to the document
%%      manager that runs on ns_couchdb node
%%

-module(doc_replication_srv).
-include("ns_common.hrl").


-export([start_link/1,
         proxy_server_name/1]).

start_link(Bucket) ->
    proc_lib:start_link(erlang, apply, [fun start_proxy_loop/1, [Bucket]]).

start_proxy_loop(Bucket) ->
    erlang:register(proxy_server_name(Bucket), self()),
    proc_lib:init_ack({ok, self()}),
    DocMgr = ns_couchdb_api:wait_for_doc_manager(),
    proxy_loop(DocMgr).

proxy_loop(DocMgr) ->
    receive
        Msg ->
            DocMgr ! Msg,
            proxy_loop(DocMgr)
    end.

proxy_server_name(xdcr) ->
    xdc_rdoc_replication_srv;
proxy_server_name(Bucket) ->
    list_to_atom("capi_ddoc_replication_srv-" ++ Bucket).
