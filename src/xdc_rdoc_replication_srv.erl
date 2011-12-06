%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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
-module(xdc_rdoc_replication_srv).

-behaviour(cb_generic_replication_srv).

-include("couch_db.hrl").

-export([start_link/0]).
-export([server_name/1, init/1, local_url/1, remote_url/2, get_servers/1]).

start_link() ->
    cb_generic_replication_srv:start_link(?MODULE, []).

server_name([]) ->
    ?MODULE.

init([]) ->
    Self = self(),

    ns_pubsub:subscribe(
      ns_node_disco_events,
      fun ({ns_node_disco_events, _Old, _New}, _) ->
              cb_generic_replication_srv:force_update(Self)
      end,
      empty),

    {ok, {}}.

local_url({}) ->
    <<"_replicator">>.

remote_url(Node, {}) ->
    Url = capi_utils:capi_url(Node, "/_replicator", "127.0.0.1"),
    ?l2b(Url).

get_servers({}) ->
    ns_node_disco:nodes_wanted() -- [node()].
