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

-include("ns_common.hrl").
-include("ns_stats.hrl").

-behaviour(gen_server).

-define(INIT_TIMEOUT, 5000).
-define(TRUNC_FREQ, 10).

-record(state, {bucket, samples_since_truncate = 1}).

-export([start_link/1,
         latest/3, latest/4,
         latest_all/2, latest_all/3]).

-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).


%%
%% API
%%

start_link(Bucket) ->
    gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket,
                          [{timeout, ?INIT_TIMEOUT}]).


%% @doc Get the latest samples for a given interval from the archive
latest(Period, Node, Bucket) when is_atom(Node) ->
    [{Node, [Result]}] = latest(Period, [Node], Bucket),
    Result;
latest(Period, Nodes, Bucket) when is_list(Nodes), is_list(Bucket) ->
    misc:pmap(fun (Node) ->
                      {Node, mnesia:transaction(
                               fun () ->
                                       Tab = table_name(Node, Bucket, Period),
                                       Key = mnesia:last(Tab),
                                       mnesia:read(Tab, Key)
                               end)}
              end, Nodes, length(Nodes)).


latest(Period, Node, Bucket, N) when is_atom(Node), is_list(Bucket) ->
    [{Node, Results}] = latest(Period, [Node], Bucket, N),
    Results;
latest(Period, Nodes, Bucket, N) when is_list(Nodes), is_list(Bucket) ->
    misc:pmap(fun (Node) ->
                      {Node, walk(table_name(Node, Bucket, Period), N)}
              end, Nodes, length(Nodes)).


latest_all(Period, Bucket) ->
    latest(Period, ns_node_disco:nodes_wanted(), Bucket).


latest_all(Period, Bucket, N) ->
    latest(Period, ns_node_disco:nodes_wanted(), Bucket, N).


%%
%% gen_server callbacks
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init(Bucket) ->
    create_tables(Bucket),
    ns_pubsub:subscribe(ns_stats_event),
    {ok, #state{bucket=Bucket}}.


handle_call(unhandled, unhandled, unhandled) ->
    unhandled.


handle_cast(unhandled, unhandled) ->
    unhandled.


handle_info({stats, Bucket, Sample}, State = #state{bucket=Bucket}) ->
    Tab = table_name(node(), Bucket, minute),
    {atomic, ok} = mnesia:transaction(fun () -> mnesia:write(Tab, Sample, write) end),
    gen_event:notify(ns_stats_event, {sample_archived, Bucket, Sample}),
    {noreply, maybe_truncate(State)};
handle_info({sample_archived, _, _}, State) ->
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

archives() ->
    [{minute, 1, 60}, % in seconds
     {hour, 10, 360}, % 10 second intervals
     {day, 24, 360},  % 240 second intervals (4 minutes)
     {week, 7, 360}   % 1680 second intervals (28 minutes)
    ].


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


create_tables(Bucket) ->
    Node = node(),
    ?log_info("Creating tables for bucket ~p if they don't already exist.",
              [Bucket]),
    lists:foreach(
      fun ({Period, _, _}) ->
              TableName = table_name(Node, Bucket, Period),
              case mnesia:create_table(TableName,
                                       [{disc_copies, [Node]},
                                        {record_name, stat_entry},
                                        {type, ordered_set},
                                        {attributes,
                                         record_info(fields, stat_entry)}]) of
                  {atomic, ok} ->
                      ?log_info("Created table for bucket ~p.", [Bucket]);
                  {aborted, {already_exists, _}} ->
                      ?log_info("Table already existed for bucket ~p.",
                                [Bucket])
              end
      end, archives()).


%% @doc Convert a list of values from stat_to_list back to a stat entry.
list_to_stat(TS, List) ->
    list_to_tuple([stat_entry, TS | List]).


%% @doc Truncate the table if necessary.
maybe_truncate(#state{bucket=Bucket, samples_since_truncate=?TRUNC_FREQ} = State) ->
    truncate(table_name(node(), Bucket, minute), 60),
    State#state{samples_since_truncate=1};
maybe_truncate(#state{samples_since_truncate=N} = State) when N < ?TRUNC_FREQ ->
    State#state{samples_since_truncate=N+1}.


%% @doc Convert a stat entry to a list of values.
stat_to_list(Entry) ->
    [stat_entry, TS | L] = tuple_to_list(Entry),
    {TS, L}.


%% @doc Generate a suitable name for the per-bucket gen_server.
server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

%% @doc Generate a suitable name for the Mnesia table.
table_name(Node, Bucket, Period) ->
    list_to_atom(lists:flatten(io_lib:format("~s-~s-~s-~s",
                                             [?MODULE_STRING,
                                              Node, Bucket, Period]))).


%% @doc Truncate the given table to the last N records.
truncate(Tab, N) ->
    {atomic, _M} = mnesia:transaction(
                     fun () -> truncate(Tab, mnesia:last(Tab), N, 0) end).



truncate(_Tab, '$end_of_table', N, M) ->
    case N of
        0 -> M;
        _ -> -N
    end;
truncate(Tab, Key, 0, M) ->
    NextKey = mnesia:prev(Tab, Key),
    ok = mnesia:delete({Tab, Key}),
    truncate(Tab, NextKey, 0, M + 1);
truncate(Tab, Key, N, 0) ->
    truncate(Tab, mnesia:prev(Tab, Key), N - 1, 0).


%% @doc Return the last N records starting with the given key from Tab.
walk(Tab, N) ->
    {atomic, Results} = mnesia:transaction(
                          fun () -> walk(Tab, mnesia:last(Tab), N, []) end),
    Results.


walk(_Tab, Key, N, Records) when N == 0; Key == '$end_of_table' ->
    Records;
walk(Tab, Key, N, Records) ->
    [Record] = mnesia:read(Tab, Key),
    NextKey = mnesia:prev(Tab, Key),
    walk(Tab, NextKey, N - 1, [Record | Records]).
