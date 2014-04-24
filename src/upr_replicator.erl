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
                connection_name :: nonempty_string(),
                producer_node :: node(),
                bucket :: bucket_name()}).

-define(VBUCKET_POLL_INTERVAL, 100).

init({ProducerNode, Bucket}) ->
    process_flag(trap_exit, true),

    ConnName = get_connection_name(node(), ProducerNode, Bucket),
    {ok, ConsumerConn} = upr_consumer_conn:start_link(ConnName, Bucket),
    {ok, ProducerConn} = upr_producer_conn:start_link(ConnName, ProducerNode, Bucket),

    erlang:register(consumer_server_name(ProducerNode, Bucket), ConsumerConn),

    upr_proxy:connect_proxies(ConsumerConn, ProducerConn),

    ?log_debug("initiated new upr replication with consumer side: ~p and producer side: ~p", [ConsumerConn, ProducerConn]),
    {ok, #state{
            producer_conn = ProducerConn,
            consumer_conn = ConsumerConn,
            connection_name = ConnName,
            producer_node = ProducerNode,
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
                         consumer_conn = Consumer,
                         connection_name = ConnName,
                         producer_node = ProdNode,
                         bucket = Bucket}) ->
    misc:terminate_and_wait(Reason, [Producer, Consumer]),
    case Reason of
        normal ->
            ok;
        shutdown ->
            ok;
        _ ->
            RV =
                (catch
                     misc:parallel_map(
                       fun ({Type, Node}) ->
                               upr_proxy:nuke_connection(Type, ConnName, Node, Bucket)
                       end,
                       [{consumer, node()}, {producer, ProdNode}],
                       5000)),

            ?log_debug("Terminating with reason ~p. Nuked connection ~p with result ~p.",
                       [Reason, ConnName, RV])
    end,
    ok.

handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};
handle_info(Msg, State) ->
    ?rebalance_warning("Unexpected handle_info(~p, ~p)", [Msg, State]),
    {noreply, State}.

handle_call({setup_replication, Partitions}, _From, #state{consumer_conn = Pid} = State) ->
    RV = spawn_and_wait(fun () ->
                                upr_consumer_conn:setup_streams(Pid, Partitions)
                        end),
    {reply, RV, State};

handle_call({takeover, Partition}, _From, #state{consumer_conn = Pid} = State) ->
    RV = spawn_and_wait(fun () ->
                                upr_consumer_conn:maybe_close_stream(Pid, Partition),
                                upr_consumer_conn:takeover(Pid, Partition)
                        end),
    {reply, RV, State};

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
            wait_for_data_move_on_one_node(Connection, Bucket, Partition)
    end.

get_connection_name(ConsumerNode, ProducerNode, Bucket) ->
    "ns_server:" ++ atom_to_list(ProducerNode) ++ "->" ++ atom_to_list(ConsumerNode) ++ ":" ++ Bucket.

spawn_and_wait(Body) ->
    WorkerPid = spawn_link(
                  fun () ->
                          try Body() of
                              RV ->
                                  exit({done, RV})
                          catch T:E ->
                                  Stack = erlang:get_stacktrace(),
                                  exit({done, T, E, Stack})
                          end
                  end),
    receive
        {'EXIT', WorkerPid, Reason} ->
            case Reason of
                {done, RV} ->
                    RV;
                {done, T, E, Stack} ->
                    erlang:raise(T, E, Stack);
                _ ->
                    ?log_error("Got unexpected reason from ~p: ~p", [WorkerPid, Reason]),
                    erlang:error({unexpected_reason, Reason})
            end;
        {'EXIT', From, Reason} = ExitMsg ->
            ?log_debug("Received exit with reason ~p from ~p. Killing child process ~p",
                       [Reason, From, WorkerPid]),
            misc:sync_shutdown_many_i_am_trapping_exits([WorkerPid]),
            erlang:error({child_interrupted, ExitMsg})
    end.
