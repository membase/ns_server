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
%% @doc partitions replicator that uses UPR protocol
%%
-module(upr_replicator).

-behaviour(gen_server).

-include("ns_common.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([start_link/2,
         get_partitions/2,
         setup_replication/3,
         takeover/3,
         wait_for_data_move/3]).

-record(state, {producer_conn :: pid(),
                consumer_conn :: pid(),
                connection_name,
                bucket}).

-define(VBUCKET_POLL_INTERVAL, 100).

init({ProducerNode, Bucket}) ->
    process_flag(trap_exit, true),

    ConnName = get_connection_name(node(), ProducerNode, Bucket),
    {ok, ConsumerConn} = upr_consumer_conn:start_link(ConnName, Bucket),
    {ok, ProducerConn} = upr_producer_conn:start_link(ConnName, ProducerNode, Bucket),

    erlang:register(consumer_server_name(ProducerNode, Bucket), ConsumerConn),

    upr_proxy:connect_proxies(ConsumerConn, ProducerConn),
    {ok, #state{
            producer_conn = ProducerConn,
            consumer_conn = ConsumerConn,
            connection_name = ConnName,
            bucket = Bucket
           }}.

start_link(ProducerNode, Bucket) ->
    gen_server:start_link({local, server_name(ProducerNode, Bucket)}, ?MODULE,
                          {ProducerNode, Bucket}, []).

server_name(ProducerNode, Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket ++ "-" ++ atom_to_list(ProducerNode)).

consumer_server_name(ProducerNode, Bucket) ->
    list_to_atom("upr_consumer_conn-" ++ Bucket ++ "-" ++ atom_to_list(ProducerNode)).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_cast(Msg, State) ->
    ?rebalance_warning("Unhandled cast: ~p" , [Msg]),
    {noreply, State}.

terminate(Reason, #state{producer_conn = Producer,
                         consumer_conn = Consumer}) ->
    misc:terminate_and_wait(Reason, [Producer, Consumer]).

handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};
handle_info(Msg, State) ->
    ?rebalance_warning("Unexpected handle_info(~p, ~p)", [Msg, State]),
    {noreply, State}.

handle_call({setup_replication, Partitions}, _From, #state{consumer_conn = Pid} = State) ->
    {reply, upr_consumer_conn:setup_streams(Pid, Partitions), State};

handle_call({takeover, Partition}, _From, #state{consumer_conn = Pid} = State) ->
    upr_consumer_conn:maybe_close_stream(Pid, Partition),
    {reply, upr_consumer_conn:takeover(Pid, Partition), State};

handle_call(Command, _From, State) ->
    ?rebalance_warning("Unexpected handle_call(~p, ~p)", [Command, State]),
    {reply, refused, State}.

get_partitions(ProducerNode, Bucket) ->
    try gen_server:call(consumer_server_name(ProducerNode, Bucket), get_partitions, infinity) of
        Result ->
            Result
    catch exit:{noproc, _} ->
            not_running
    end.

setup_replication(ProducerNode, Bucket, Partitions) ->
    gen_server:call(server_name(ProducerNode, Bucket),
                    {setup_replication, Partitions}, infinity).

takeover(ProducerNode, Bucket, Partition) ->
    gen_server:call(server_name(ProducerNode, Bucket),
                    {takeover, Partition},
                    infinity).

wait_for_data_move([], _, _) ->
    ok;
wait_for_data_move([Node | Rest], Bucket, Partition) ->
    Connection = get_connection_name(Node, node(), Bucket),
    case wait_for_data_move_on_one_node(Connection, Bucket, Partition) of
        undefined ->
            ?log_error("No upr backfill stats for bucket ~p, partition ~p, connection ~p",
                       [Bucket, Partition, Connection]),
            {error, no_stats_for_this_vbucket};
        _ ->
            wait_for_data_move(Rest, Bucket, Partition)
    end.

wait_for_data_move_on_one_node(Connection, Bucket, Partition) ->
    case ns_memcached:get_upr_backfill_remaining_items(Bucket, Connection, Partition) of
        undefined ->
            undefined;
        N when N < 1000 ->
            ok;
        _ ->
            timer:sleep(?VBUCKET_POLL_INTERVAL),
            wait_for_data_move_on_one_node(Bucket, Connection, Partition)
    end.

get_connection_name(ConsumerNode, ProducerNode, Bucket) ->
    atom_to_list(ProducerNode) ++ "->" ++ atom_to_list(ConsumerNode) ++ ":" ++ Bucket.
