%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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

%% Maintains design document replication between the <BucketName>/master
%% vbuckets (CouchDB databases) of all cluster nodes.

-module(capi_ddoc_replication_srv).
-include("couch_db.hrl").
-include("ns_common.hrl").


-export([start_link/1,
         proxy_server_name/1]).

%% C-release is using this server name for ddoc replication. So it's
%% better if we don't break backwards compat with it. This process
%% merely forwards casts to capi_set_view_manager
start_link(Bucket) ->
    proc_lib:start_link(erlang, apply, [fun start_proxy_loop/1, [Bucket]]).

start_proxy_loop(Bucket) ->
    SetViewMgr = erlang:whereis(capi_set_view_manager:server(Bucket)),
    erlang:link(SetViewMgr),
    erlang:register(proxy_server_name(Bucket), self()),
    proc_lib:init_ack({ok, self()}),
    proxy_loop(SetViewMgr).

proxy_loop(SetViewMgr) ->
    receive
        Msg ->
            SetViewMgr ! Msg,
            proxy_loop(SetViewMgr)
    end.

proxy_server_name(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).
