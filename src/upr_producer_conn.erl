%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
%% @doc producer side of the UPR proxy
%%
-module(upr_producer_conn).

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").

-export([start_link/4, init/1, handle_packet/4, handle_call/4, handle_cast/2]).

start_link(ConnName, ProducerNode, Bucket, ConsumerConn) ->
    upr_proxy:start_link(producer, ConnName, ProducerNode, Bucket, ?MODULE, ConsumerConn).

init(ConsumerConn) ->
    ConsumerConn.

handle_packet(_, _, _, State) ->
    {proxy, State}.

handle_call(Command, _From, _Sock, State) ->
    ?rebalance_warning("Unexpected handle_call(~p, ~p)", [Command, State]),
    {reply, refused, State}.

handle_cast(Msg, State) ->
    ?rebalance_warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.
