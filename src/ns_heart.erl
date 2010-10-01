%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
-module(ns_heart).

-behaviour(gen_server).

-define(EXPENSIVE_CHECK_INTERVAL, 60000). % In ms

-export([start_link/0, status_all/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% gen_server handlers

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    timer:send_interval(1000, beat),
    timer:send_interval(?EXPENSIVE_CHECK_INTERVAL, do_expensive_checks),
    {ok, expensive_checks()}.

handle_call(status, _From, State) ->
    {reply, current_status(State), State};
handle_call(Request, _From, State) ->
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(beat, State) ->
    misc:flush(beat),
    ns_doctor:heartbeat(current_status(State)),
    {noreply, State};
handle_info(do_expensive_checks, _State) ->
    {noreply, expensive_checks()}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API
status_all() ->
    {Replies, _} = gen_server:multi_call([node() | nodes()], ?MODULE, status, 5000),
    Replies.

stats() ->
    Stats = [wall_clock, context_switches, garbage_collection, io, reductions,
             run_queue, runtime],
    [{Stat, statistics(Stat)} || Stat <- Stats].

%% Internal fuctions
current_status(Expensive) ->
    [{active_buckets, ns_memcached:active_buckets()},
     {memory, erlang:memory()},
     {memory_data, memsup:get_memory_data()},
     {disk_data, disksup:get_disk_data()}|
     Expensive].

expensive_checks() ->
    [{system_memory_data, memsup:get_system_memory_data()},
     {statistics, stats()}].
