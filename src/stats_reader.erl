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
%% @doc Read locally stored stats
%%

-module(stats_reader).

-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-include("ns_common.hrl").
-include("ns_stats.hrl").

-define(TIMEOUT, 5000).

-record(state, {bucket}).

-export([start_link/1,
         latest/3, latest/4, latest/5,
         latest_all/2, latest_all/3, latest_all/4]).

-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-import(stats_archiver, [avg/2]).

%%
%% API
%%

start_link(Bucket) ->
    gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, []).


%% @doc Get the latest samples for a given interval from the archive
latest(Period, Node, Bucket) when is_atom(Node) ->
    gen_server:call({server(Bucket), Node}, {latest, Period});
latest(Period, Nodes, Bucket) when is_list(Nodes), is_list(Bucket) ->
    R = {Replies, _} = gen_server:multi_call(Nodes, server(Bucket),
                                             {latest, Period},
                                             ?TIMEOUT),
    log_bad_responses(R),
    Replies.

latest(Period, Node, Bucket, N) when is_atom(Node), is_list(Bucket) ->
    gen_server:call({server(Bucket), Node}, {latest, Period, N});
latest(Period, Nodes, Bucket, N) when is_list(Nodes), is_list(Bucket) ->
    R = {Replies, _} = gen_server:multi_call(Nodes, server(Bucket),
                                             {latest, Period, N},
                                             ?TIMEOUT),
    log_bad_responses(R),
    Replies.


latest(Period, Node, Bucket, Step, N) when is_atom(Node) ->
    gen_server:call({server(Bucket), Node}, {latest, Period, Step, N});
latest(Period, Nodes, Bucket, Step, N) when is_list(Nodes) ->
    R = {Replies, _} = gen_server:multi_call(Nodes, server(Bucket),
                                             {latest, Period, Step, N},
                                             ?TIMEOUT),
    log_bad_responses(R),
    Replies.


latest_all(Period, Bucket) ->
    latest(Period, ns_node_disco:nodes_wanted(), Bucket).


latest_all(Period, Bucket, N) ->
    latest(Period, ns_node_disco:nodes_wanted(), Bucket, N).


latest_all(Period, Bucket, Step, N) ->
    latest(Period, ns_node_disco:nodes_wanted(), Bucket, Step, N).


%%
%% gen_server callbacks
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init(Bucket) ->
    {ok, #state{bucket=Bucket}}.

handle_call({latest, Period}, _From, #state{bucket=Bucket} = State) ->
    Reply = stats_archiver:latest_sample(Bucket, Period),
    {reply, Reply, State};
handle_call({latest, Period, N}, _From, #state{bucket=Bucket} = State) ->
    Reply = try fetch_latest(Bucket, Period, N) of
                Result -> Result
            catch Type:Err ->
                    {error, {Type, Err}}
            end,
    {reply, Reply, State};
handle_call({latest, Period, Step, N}, _From, #state{bucket=Bucket} = State) ->
    Reply = try resample(Bucket, Period, Step, N) of
                Result -> Result
            catch Type:Err ->
                    {error, {Type, Err}}
            end,
    {reply, Reply, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info(_Msg, State) -> % Don't crash on delayed responses from calls
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

%% @doc Return the last N records starting with the given key from Tab.
fetch_latest(Bucket, Period, N) ->
    case lists:keyfind(Period, 1, stats_archiver:archives()) of
        false ->
            {error, bad_period, Period};
        {_, Interval, _} ->
            Seconds = N * Interval,
            Tab = stats_archiver:table(Bucket, Period),
            case ets:last(Tab) of
                '$end_of_table' ->
                    {ok, []};
                Key ->
                    Oldest = Key - Seconds * 1000 + 500,
                    case qlc:eval(qlc:q([Sample || {TS,Sample} <- ets:table(Tab), TS > Oldest])) of
                        {error, _, _} = Error ->
                            Error;
                        Results ->
                            {ok, Results}
                    end
            end
    end.


log_bad_responses({Replies, Zombies}) ->
    case lists:filter(fun ({_, {ok, _}}) -> false; (_) -> true end, Replies) of
        [] ->
            ok;
        BadReplies ->
            ?stats_error("Bad replies: ~p", [BadReplies])
    end,
    case Zombies of
        [] ->
            ok;
        _ ->
            ?stats_error("Some nodes didn't respond: ~p", [Zombies])
    end.


%% @doc Resample the stats in a table. Only reads the necessary number of rows.
resample(Bucket, Period, Step, N) ->
    Seconds = N * Step,
    Tab = stats_archiver:table(Bucket, Period),
    case ets:last(Tab) of
        '$end_of_table' ->
            {ok, []};
        Key ->
            Oldest = Key - Seconds * 1000 + 500,
            Handle = qlc:q([Sample || {TS, Sample}
                                          <- ets:table(Tab), TS > Oldest]),
            F = fun (#stat_entry{timestamp = T} = Sample,
                     {T1, Acc, Chunk}) ->
                        case misc:trunc_ts(T, Step) of
                            T1 ->
                                {T1, Acc, [Sample|Chunk]};
                            T2 when T1 == undefined ->
                                {T2, Acc, [Sample]};
                            T2 ->
                                {T2, [avg(T1, Chunk)|Acc], [Sample]}
                        end
                end,
            case qlc:fold(F, {undefined, [], []}, Handle) of
                {error, _, _} = Error ->
                    Error;
                {undefined, [], []} ->
                    {ok, []};
                {T, Acc, LastChunk} ->
                    {ok, lists:reverse([avg(T, LastChunk)|Acc])}
            end
    end.


%% @doc Generate a suitable name for the per-bucket gen_server.
server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).
