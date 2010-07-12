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

-module(stats_archiver).

-include_lib("eunit/include/eunit.hrl").

-include("ns_stats.hrl").

-behaviour(gen_server).

-define(NUM_SAMPLES, 61).

-record(state, {bucket, samples}).

-export([start_link/1,
         latest/2, latest/3, latest/4,
         latest_all/2, latest_all/3]).

-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).


%% API

start_link(Bucket) ->
    gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, []).

latest(minute, Bucket) ->
    gen_server:call(server(Bucket), latest).

latest(minute, Node, Bucket) when is_atom(Node), is_list(Bucket) ->
    gen_server:call({server(Bucket), Node}, latest);
latest(minute, Nodes, Bucket) when is_list(Bucket) ->
    gen_server:multi_call(Nodes, server(Bucket), latest);
latest(minute, Bucket, N) ->
    gen_server:call(server(Bucket), {latest, N}).

latest(minute, Node, Bucket, N) when is_atom(Node) ->
    gen_server:call({server(Bucket), Node}, {latest, N});
latest(minute, Nodes, Bucket, N) ->
    gen_server:multi_call(Nodes, server(Bucket), {latest, N}).

latest_all(minute, Bucket) ->
    gen_server:multi_call(server(Bucket), latest).

latest_all(minute, Bucket, N) ->
    gen_server:multi_call(server(Bucket), {latest, N}).


%% gen_server callbacks
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init(Bucket) ->
    ns_pubsub:subscribe(ns_stats_event,
                        fun (Event = {stats, B, _}, {B, Pid}) ->
                                Pid ! Event,
                                {B, Pid};
                            (_, State) -> State
                        end, {Bucket, self()}),
    {ok, #state{bucket=Bucket, samples=ringbuffer:new(?NUM_SAMPLES)}}.


handle_call(latest, _From, State = #state{samples=Samples}) ->
    {reply, lists:last(ringbuffer:to_list(Samples)), State};
handle_call({latest, N}, _From, State = #state{samples=Samples}) ->
    {reply, ringbuffer:to_list(N, Samples), State}.


handle_cast(unhandled, unhandled) ->
    unhandled.


handle_info({stats, Bucket, Sample}, State = #state{bucket=Bucket,
                                                   samples=Samples}) ->
    gen_event:notify(ns_stats_event, {sample_archived, Bucket, Sample}),
    {noreply, State#state{samples=ringbuffer:add(Sample,
                                                 Samples)}}.


terminate(_Reason, _State) ->
    ok.


%% Internal functions

server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).
