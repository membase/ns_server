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
%%
%% @doc Store and aggregate statistics collected from memcached.
%%

-module(stats_archiver).

-include_lib("eunit/include/eunit.hrl").

-include("ns_stats.hrl").

-behaviour(gen_server).

-define(NUM_SAMPLES, 61).

-record(state, {bucket, samples, table}).

-export([start_link/1,
         latest/2, latest/3, latest/4,
         latest_all/2, latest_all/3]).

-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).


%%
%% API
%%

start_link(Bucket) ->
    gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, []).


%% @doc Get the latest samples for a given interval from the archive
latest(minute, Bucket) ->
    mnesia:activity(transaction,
                    fun () ->
                            Tab = table_name(Bucket),
                            Key = mnesia:last(table_name(Bucket)),
                            mnesia:read(Tab, Key)
                    end).


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


%%
%% gen_server callbacks
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init(Bucket) ->
    TableName = create_table(Bucket),
    ns_pubsub:subscribe(ns_stats_event,
                        fun ({stats, B, Stats}, {B, Pid}) ->
                                received(Pid, Stats),
                                {B, Pid};
                            (_, State) -> State
                        end, {Bucket, self()}),
    {ok, #state{bucket=Bucket, samples=ringbuffer:new(?NUM_SAMPLES),
                table=TableName}}.


handle_call(latest, _From, State = #state{samples=Samples}) ->
    {reply, lists:last(ringbuffer:to_list(Samples)), State};
handle_call({latest, N}, _From, State = #state{samples=Samples}) ->
    {reply, ringbuffer:to_list(N, Samples), State}.


handle_cast({stats, Sample}, State = #state{bucket=Bucket, table=Tab}) ->
    ok = mnesia:activity(transaction,
                         fun () -> mnesia:write(Tab, Sample, write) end),
    gen_event:notify(ns_stats_event, {sample_archived, Bucket, Sample}),
    {noreply, State}.


handle_info(unhandled, unhandled) ->
    unhandled.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

%% @doc Compute the average of a list of entries.
%% Timestamp is taken from the first entry.
avg(Samples) ->
    [First|Rest] = Samples,
    {TS, FirstList} = stat_to_list(First),
    Sums = lists:foldl(fun (E, Acc) ->
                               {_, L} = stat_to_list(E),
                               lists:zipwith(fun (A, B) -> A + B end, L, Acc)
                       end, FirstList, Rest),
    Count = length(Samples),
    Avgs = [X / Count || X <- Sums],
    list_to_stat(TS, Avgs).


create_table(Bucket) ->
    TableName = table_name(Bucket),
    case mnesia:create_table(TableName,
                             [{disc_copies, [node()]},
                              {record_name, stat_entry},
                              {type, ordered_set},
                              {attributes, record_info(fields, stat_entry)}]) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, _}} ->
            ok
    end,
    TableName.


%% @doc Convert a list of values from stat_to_list back to a stat entry.
list_to_stat(TS, List) ->
    list_to_tuple([stat_entry, TS | List]).


%% @doc Pass received stats to the archiver.
received(Pid, Stats) ->
    gen_server:cast(Pid, {stats, Stats}).


%% @doc Convert a stat entry to a list of values.
stat_to_list(Entry) ->
    [stat_entry, TS | L] = tuple_to_list(Entry),
    {TS, L}.


%% @doc Truncate a timestamp to a multiple of the given number of seconds.
ts_trunc(Resolution, TS) ->
    {MegaSecs, Secs, _} = TS,
    MegaSecs * 1000000 + trunc(Secs / Resolution) * Resolution.


%% @doc Generate a suitable name for the per-bucket gen_server.
server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

%% @doc Generate a suitable name for the Mnesia table.
table_name(Bucket) ->
    list_to_atom(lists:flatten(io_lib:format("~s-~s-~s", [?MODULE_STRING,
                                                          node(), Bucket]))).
