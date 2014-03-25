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

-export([start_link/3, init/1, handle_packet/5, handle_call/4, handle_cast/3]).

start_link(ConnName, ProducerNode, Bucket) ->
    upr_proxy:start_link(producer, ConnName, ProducerNode, Bucket, ?MODULE, []).

init([]) ->
    [].

handle_packet(request, ?UPR_SET_VBUCKET_STATE, Packet, State, ParentState) ->
    Consumer = upr_proxy:get_partner(ParentState),
    ok = gen_server:call(Consumer, {set_vbucket_state, Packet}),
    {proxy, State};

handle_packet(response, ?UPR_CLOSE_STREAM, Packet, State, ParentState) ->
    Consumer = upr_proxy:get_partner(ParentState),
    gen_server:cast(Consumer, {producer_stream_closed, Packet}),
    {block, State};

handle_packet(_, _, _, State, _ParentState) ->
    {proxy, State}.

handle_call(Msg, _From, State, _ParentState) ->
    ?rebalance_warning("Unhandled call: Msg = ~p, State = ~p", [Msg, State]),
    {reply, refused, State}.

handle_cast({close_stream, Partition}, State, ParentState) ->
    upr_commands:close_stream(upr_proxy:get_socket(ParentState), Partition, Partition),
    {noreply, State};

handle_cast(Msg, State, _ParentState) ->
    ?rebalance_warning("Unhandled cast: Msg = ~p, State = ~p", [Msg, State]),
    {noreply, State}.
