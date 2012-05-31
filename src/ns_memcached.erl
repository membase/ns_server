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
%% This module lets you treat a memcached process as a gen_server.
%% Right now we have one of these registered per node, which stays
%% connected to the local memcached server as the admin user. All
%% communication with that memcached server is expected to pass
%% through distributed erlang, not using memcached prototocol over the
%% LAN.
%%
%% Calls to memcached that potentially can take took long are passed
%% down to one of worker processes. ns_memcached process is
%% maintaining list of ready workers and calls queue. When
%% gen_server:call arrives this is added to calls queue. And if
%% there's ready worker, it is dequeued and sent to worker. Worker
%% then does gen_server:reply to caller.
%%
-module(ns_memcached).

-behaviour(gen_server).

-include("ns_common.hrl").

-define(CHECK_INTERVAL, 10000).
-define(CHECK_WARMUP_INTERVAL, 500).
-define(VBUCKET_POLL_INTERVAL, 100).
-define(TIMEOUT, ns_config_ets_dup:get_timeout(ns_memcached_outer, 30000)).
-define(TIMEOUT_OPEN_CHECKPOINT, ns_config_ets_dup:get_timeout(ns_memcached_open_checkpoint, 30000)).
-define(TIMEOUT_HEAVY, ns_config_ets_dup:get_timeout(ns_memcached_outer_heavy, 30000)).
-define(TIMEOUT_VERY_HEAVY, ns_config_ets_dup:get_timeout(ns_memcached_outer_very_heavy, 60000)).
-define(CONNECTED_TIMEOUT, ns_config_ets_dup:get_timeout(ns_memcached_connected, 5000)).
%% half-second is definitely 'slow' for any definition of slow
-define(SLOW_CALL_THRESHOLD_MICROS, 500000).

-define(CONNECTION_ATTEMPTS, 5).

%% gen_server API
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {
          running_fast = 0,
          running_heavy = 0,
          running_very_heavy = 0,
          %% NOTE: otherwise dialyzer seemingly thinks it's possible
          %% for queue fields to be undefined
          fast_calls_queue = impossible :: queue(),
          heavy_calls_queue = impossible :: queue(),
          very_heavy_calls_queue = impossible :: queue(),
          status::atom(),
          start_time::tuple(),
          bucket::nonempty_string(),
          sock::port(),
          timer::any(),
          work_requests = []
         }).

%% external API
-export([active_buckets/0,
         backfilling/1,
         backfilling/2,
         connected/2,
         connected/3,
         connected_buckets/0,
         connected_buckets/1,
         delete_vbucket/2, delete_vbucket/3,
         get_vbucket/3,
         host_port/1,
         host_port/2,
         host_port_str/1,
         list_vbuckets/1, list_vbuckets/2,
         list_vbuckets_prevstate/2,
         list_vbuckets_multi/2,
         set_vbucket/3, set_vbucket/4,
         server/1,
         stats/1, stats/2, stats/3,
         topkeys/1,
         raw_stats/5,
         sync_bucket_config/1,
         deregister_tap_client/2,
         flush/1,
         get_vbucket_open_checkpoint/3,
         ready_nodes/4,
         connect_and_send_isasl_refresh/0]).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

%%
%% gen_server API implementation
%%

start_link(Bucket) ->
    %% Use proc_lib so that start_link doesn't fail if we can't
    %% connect.
    gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, []).


%%
%% gen_server callback implementation
%%

init(Bucket) ->
    %% this trap_exit is necessary for terminate callback to work
    process_flag(trap_exit, true),

    {ok, Timer} = timer:send_interval(?CHECK_WARMUP_INTERVAL, check_started),
    case connect() of
        {ok, Sock} ->
            case ensure_bucket(Sock, Bucket) of
                ok -> init_with_created_bucket(Bucket, Timer, Sock);
                EnsureBucketError ->
                    {stop, {ensure_bucket_failed, EnsureBucketError}}
            end;
        {error, Error} ->
            {stop, Error}
    end.

init_with_created_bucket(Bucket, Timer, Sock) ->
    gen_event:notify(buckets_events, {started, Bucket}),
    Q = queue:new(),
    WorkersCount = case ns_config:search_node(ns_memcached_workers_count) of
                       false -> 4;
                       {value, DefinedWorkersCount} ->
                           DefinedWorkersCount
                   end,
    InitialState = #state{
      timer=Timer,
      status=init,
      start_time=os:timestamp(),
      sock=Sock,
      bucket=Bucket,
      work_requests=[],
      fast_calls_queue = Q,
      heavy_calls_queue = Q,
      very_heavy_calls_queue = Q,
      running_fast = WorkersCount
     },
    Self = self(),
    [proc_lib:spawn_link(erlang, apply, [fun worker_init/2, [Self, InitialState]])
     || _ <- lists:seq(1, WorkersCount)],
    {ok, InitialState}.

worker_init(Parent, ParentState) ->
    {ok, Sock} = connect(),
    ok = mc_client_binary:select_bucket(Sock, ParentState#state.bucket),
    worker_loop(Parent, ParentState#state{sock = Sock}, #state.running_fast).

worker_loop(Parent, State, PrevCounterSlot) ->
    {Msg, From, StartTS, CounterSlot} = gen_server:call(Parent, {get_work, PrevCounterSlot}, infinity),
    WorkStartTS = os:timestamp(),
    %% note we only accept calls that don't mutate state. So in- and
    %% out- going states asserted to be same.
    {reply, Reply, State} = do_handle_call(Msg, From, State),
    gen_server:reply(From, Reply),
    verify_report_long_call(StartTS, WorkStartTS, State, Msg, []),
    worker_loop(Parent, State, CounterSlot).

handle_call({get_work, CounterSlot}, From, #state{work_requests = Froms} = State) ->
    State2 = State#state{work_requests = [From | Froms]},
    Counter = erlang:element(CounterSlot, State2) - 1,
    State3 = erlang:setelement(CounterSlot, State2, Counter),
    {noreply, maybe_deliver_work(State3)};
handle_call(connected, _From, #state{status=Status} = State) ->
    {reply, Status =:= connected, State};
handle_call(sync_bucket_config = Msg, _From, State) ->
    StartTS = os:timestamp(),
    handle_info(check_config, State),
    verify_report_long_call(StartTS, StartTS, State, Msg, {reply, ok, State});
handle_call(Msg, From, State) ->
    StartTS = os:timestamp(),
    NewState = queue_call(Msg, From, StartTS, State),
    {noreply, NewState}.

verify_report_long_call(StartTS, ActualStartTS, State, Msg, RV) ->
    try
        RV
    after
        EndTS = os:timestamp(),
        Diff = timer:now_diff(EndTS, ActualStartTS),
        QDiff = timer:now_diff(EndTS, StartTS),
        ServiceName = "ns_memcached-" ++ State#state.bucket,
        (catch
             begin
                 system_stats_collector:increment_counter({ServiceName, call_time}, Diff),
                 system_stats_collector:increment_counter({ServiceName, q_call_time}, QDiff),
                 system_stats_collector:increment_counter({ServiceName, calls}, 1)
             end),
        if
            Diff > ?SLOW_CALL_THRESHOLD_MICROS ->
                (catch
                     begin
                         system_stats_collector:increment_counter({ServiceName, long_call_time}, Diff),
                         system_stats_collector:increment_counter({ServiceName, long_calls}, 1)
                     end),
                ?log_error("call ~p took too long: ~p us", [Msg, Diff]);
            true ->
                ok
        end
    end.

%% anything effectful is likely to be heavy
assign_queue({delete_vbucket, _}) -> #state.very_heavy_calls_queue;
assign_queue(flush) -> #state.very_heavy_calls_queue;
assign_queue({set_vbucket, _, _}) -> #state.heavy_calls_queue;
assign_queue({deregister_tap_client, _}) -> #state.heavy_calls_queue;
assign_queue(_) -> #state.fast_calls_queue.

queue_to_counter_slot(#state.very_heavy_calls_queue) -> #state.running_very_heavy;
queue_to_counter_slot(#state.heavy_calls_queue) -> #state.running_heavy;
queue_to_counter_slot(#state.fast_calls_queue) -> #state.running_fast.

queue_call(Msg, From, StartTS, State) ->
    QI = assign_queue(Msg),
    Q = erlang:element(QI, State),
    CounterSlot = queue_to_counter_slot(QI),
    Q2 = queue:snoc(Q, {Msg, From, StartTS, CounterSlot}),
    State2 = erlang:setelement(QI, State, Q2),
    maybe_deliver_work(State2).

maybe_deliver_work(#state{running_heavy = RunningHeavy,
                          running_fast = RunningFast,
                          work_requests = Froms} = State) ->
    case Froms of
        [] ->
            State;
        [From | RestFroms] ->
            StartedHeavy =
                %% we only consider starting heavy calls if
                %% there's extra free worker for fast calls. Thus
                %% we're considering heavy queues first. Otherwise
                %% we'll be starving them.
                case RestFroms =/= [] orelse RunningFast > 0 of
                    false ->
                        failed;
                    _ ->
                        StartedVeryHeavy =
                            case RunningHeavy of
                                %% we allow only one concurrent very
                                %% heavy call. Thus it makes sense to
                                %% consider very heavy queue first
                                0 ->
                                    try_deliver_work(State, From, RestFroms, #state.very_heavy_calls_queue);
                                _ ->
                                    failed
                            end,
                        case StartedVeryHeavy of
                            failed ->
                                try_deliver_work(State, From, RestFroms, #state.heavy_calls_queue);
                            _ ->
                                StartedVeryHeavy
                        end
                end,
            StartedFast =
                case StartedHeavy of
                    failed ->
                        try_deliver_work(State, From, RestFroms, #state.fast_calls_queue);
                    _ ->
                        StartedHeavy
                end,
            case StartedFast of
                failed ->
                    State;
                _ ->
                    maybe_deliver_work(StartedFast)
            end
    end.

%% -spec try_deliver_work(#state{}, any(), [any()], (#state.very_heavy_calls_queue) | (#state.heavy_calls_queue) | (#state.fast_calls_queue)) ->
%%                               failed | #state{}.
-spec try_deliver_work(#state{}, any(), [any()], 5 | 6 | 7) ->
                              failed | #state{}.
try_deliver_work(State, From, RestFroms, QueueSlot) ->
    Q = erlang:element(QueueSlot, State),
    case queue:is_empty(Q) of
        true ->
            failed;
        _ ->
            {_Msg, _From, _StartTS, CounterSlot} = Call = queue:head(Q),
            gen_server:reply(From, Call),
            State2 = State#state{work_requests = RestFroms},
            Counter = erlang:element(CounterSlot, State2),
            State3 = erlang:setelement(CounterSlot, State2, Counter + 1),
            erlang:setelement(QueueSlot, State3, queue:tail(Q))
    end.


do_handle_call({raw_stats, SubStat, StatsFun, StatsFunState}, _From, State) ->
    try mc_binary:quick_stats(State#state.sock, SubStat, StatsFun, StatsFunState) of
        Reply ->
            {reply, Reply, State}
    catch T:E ->
            {reply, {exception, {T, E}}, State}
    end;
do_handle_call(backfilling, _From, State) ->
    End = <<":pending_backfill">>,
    ES = byte_size(End),
    {ok, Reply} = mc_binary:quick_stats(
                    State#state.sock, <<"tap">>,
                    fun (<<"eq_tapq:", K/binary>>, <<"true">>, Acc) ->
                            S = byte_size(K) - ES,
                            case K of
                                <<_:S/binary, End/binary>> ->
                                    true;
                                _ ->
                                    Acc
                            end;
                        (_, _, Acc) ->
                            Acc
                    end, false),
    {reply, Reply, State};
do_handle_call({delete_vbucket, VBucket}, _From, #state{sock=Sock} = State) ->
    case mc_client_binary:delete_vbucket(Sock, VBucket) of
        ok ->
            {reply, ok, State};
        {memcached_error, einval, _} ->
            ok = mc_client_binary:set_vbucket(Sock, VBucket,
                                              dead),
            Reply = mc_client_binary:delete_vbucket(Sock, VBucket),
            {reply, Reply, State}
    end;
do_handle_call({get_vbucket, VBucket}, _From, State) ->
    Reply = mc_client_binary:get_vbucket(State#state.sock, VBucket),
    {reply, Reply, State};
do_handle_call(list_buckets, _From, State) ->
    Reply = mc_client_binary:list_buckets(State#state.sock),
    {reply, Reply, State};
do_handle_call(list_vbuckets_prevstate, _From, State) ->
    Reply = mc_binary:quick_stats(
              State#state.sock, <<"prev-vbucket">>,
              fun (<<"vb_", K/binary>>, V, Acc) ->
                      [{list_to_integer(binary_to_list(K)),
                        binary_to_existing_atom(V, latin1)} | Acc]
              end, []),
    {reply, Reply, State};
do_handle_call(list_vbuckets, _From, State) ->
    Reply = mc_binary:quick_stats(
              State#state.sock, <<"vbucket">>,
              fun (<<"vb_", K/binary>>, V, Acc) ->
                      [{list_to_integer(binary_to_list(K)),
                        binary_to_existing_atom(V, latin1)} | Acc]
              end, []),
    {reply, Reply, State};
do_handle_call(flush, _From, State) ->
    Reply = mc_client_binary:flush(State#state.sock),
    {reply, Reply, State};
do_handle_call({set_flush_param, Key, Value}, _From, State) ->
    Reply = mc_client_binary:set_flush_param(State#state.sock, Key, Value),
    {reply, Reply, State};
do_handle_call({set_vbucket, VBucket, VBState}, _From,
            #state{sock=Sock} = State) ->
    (catch master_activity_events:note_vbucket_state_change(State#state.bucket, node(), VBucket, VBState)),
    Reply = mc_client_binary:set_vbucket(Sock, VBucket, VBState),
    case Reply of
        ok ->
            ?log_info("Changed vbucket ~p state to ~p", [VBucket, VBState]);
        _ ->
            ?log_error("Failed to change vbucket ~p state to ~p: ~p", [VBucket, VBState, Reply])
    end,
    {reply, Reply, State};
do_handle_call({stats, Key}, _From, State) ->
    Reply = mc_binary:quick_stats(State#state.sock, Key, fun mc_binary:quick_stats_append/3, []),
    {reply, Reply, State};
do_handle_call(topkeys, _From, State) ->
    Reply = mc_binary:quick_stats(
              State#state.sock, <<"topkeys">>,
              fun (K, V, Acc) ->
                      VString = binary_to_list(V),
                      Tokens = string:tokens(VString, ","),
                      [{binary_to_list(K),
                        lists:map(fun (S) ->
                                          [Key, Value] = string:tokens(S, "="),
                                          {list_to_atom(Key),
                                           list_to_integer(Value)}
                                  end,
                                  Tokens)} | Acc]
              end,
              []),
    {reply, Reply, State};
do_handle_call({deregister_tap_client, TapName}, _From, State) ->
    mc_client_binary:deregister_tap_client(State#state.sock, TapName),
    {reply, ok, State};
do_handle_call(_, _From, State) ->
    {reply, unhandled, State}.


handle_cast(_, State) ->
    {noreply, State}.


handle_info(check_started, #state{status=connected} = State) ->
    {noreply, State};
handle_info(check_started, #state{timer=Timer, start_time=Start,
                                  sock=Sock, bucket=Bucket} = State) ->
    case has_started(Sock) of
        true ->
            {ok, cancel} = timer:cancel(Timer),
            ?user_log(1, "Bucket ~p loaded on node ~p in ~p seconds.",
                      [Bucket, node(), timer:now_diff(os:timestamp(), Start) div 1000000]),
            gen_event:notify(buckets_events, {loaded, Bucket}),
            timer:send_interval(?CHECK_INTERVAL, check_config),
            {noreply, State#state{status=connected}};
        false ->
            {noreply, State}
    end;
handle_info(check_config, State) ->
    misc:flush(check_config),
    StartTS = os:timestamp(),
    ensure_bucket(State#state.sock, State#state.bucket),
    Diff = timer:now_diff(os:timestamp(), StartTS),
    if
        Diff > ?SLOW_CALL_THRESHOLD_MICROS ->
            ?log_error("handle_info(ensure_bucket,..) took too long: ~p us", [Diff]);
        true ->
            ok
    end,
    {noreply, State};
handle_info({'EXIT', _, Reason} = Msg, State) ->
    ?log_debug("Got ~p. Exiting.", [Msg]),
    {stop, Reason, State};
handle_info(Msg, State) ->
    ?log_warning("Unexpected handle_info(~p, ~p)", [Msg, State]),
    {noreply, State}.


terminate(Reason, #state{bucket=Bucket, sock=Sock}) ->
    NsConfig = try ns_config:get()
               catch T:E ->
                       ?log_error("Failed to reach ns_config:get() ~p:~p~n~p~n",
                                  [T,E,erlang:get_stacktrace()]),
                       undefined
               end,
    BucketConfigs = ns_bucket:get_buckets(NsConfig),
    NoBucket = NsConfig =/= undefined andalso
        not lists:keymember(Bucket, 1, BucketConfigs),
    NodeDying = NsConfig =/= undefined
        andalso (ns_config:search(NsConfig, i_am_a_dead_man) =/= false
                 orelse not lists:member(Bucket, ns_bucket:node_bucket_names(node(), BucketConfigs))),
    Deleting = NoBucket orelse NodeDying,

    if
        Reason == normal; Reason == shutdown ->
            ?user_log(2, "Shutting down bucket ~p on ~p for ~s",
                      [Bucket, node(), case Deleting of
                                           true -> "deletion";
                                           false -> "server shutdown"
                                       end]),
            try
                ok = mc_client_binary:delete_bucket(Sock, Bucket, [{force, Deleting}])
            catch
                E2:R2 ->
                    ?log_error("Failed to delete bucket ~p: ~p",
                               [Bucket, {E2, R2}])
            after
                case NoBucket of
                    %% files are deleted here only when bucket is deleted; in
                    %% all the other cases (like node removal or failover) we
                    %% leave them on the file system and let others decide
                    %% when they should be deleted
                    true -> ns_storage_conf:delete_db_files(Bucket);
                    _ -> ok
                end
            end;
        true ->
            ?user_log(4,
                      "Control connection to memcached on ~p disconnected: ~p",
                      [node(), Reason])
    end,
    gen_event:notify(buckets_events, {stopped, Bucket, Deleting, Reason}),
    ok = gen_tcp:close(Sock),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%
%% API
%%

-spec active_buckets() -> [bucket_name()].
active_buckets() ->
    [Bucket || ?MODULE_STRING "-" ++ Bucket <-
                   [atom_to_list(Name) || Name <- registered()]].

-spec connected(node(), bucket_name(), integer() | infinity) -> boolean().
connected(Node, Bucket, Timeout) ->
    Address = {server(Bucket), Node},
    try
        do_call(Address, connected, Timeout)
    catch
        _:_ ->
            false
    end.

-spec connected(node(), bucket_name()) -> boolean().
connected(Node, Bucket) ->
    connected(Node, Bucket, ?CONNECTED_TIMEOUT).

-spec ready_nodes([node()], bucket_name(), up | connected, pos_integer() | infinity | default) -> [node()].
ready_nodes(Nodes, Bucket, Type, default) ->
    ready_nodes(Nodes, Bucket, Type, ?CONNECTED_TIMEOUT);
ready_nodes(Nodes, Bucket, Type, Timeout) ->
    UpNodes = ordsets:intersection(ordsets:from_list(Nodes),
                                   ordsets:from_list([node() | nodes()])),
    {Replies, _BadNodes} = gen_server:multi_call(UpNodes, server(Bucket), connected, Timeout),
    case Type of
        up ->
            [N || {N, _} <- Replies];
        connected ->
            [N || {N, true} <- Replies]
    end.

connected_buckets() ->
    connected_buckets(?CONNECTED_TIMEOUT).

connected_buckets(Timeout) ->
    lists:filter(fun (N) ->
                         connected(node(), N, Timeout)
                 end, active_buckets()).

%% @doc Send flush command to specified bucket
-spec flush(bucket_name()) -> ok.
flush(Bucket) ->
    do_call({server(Bucket), node()}, flush, ?TIMEOUT_VERY_HEAVY).

%% @doc Returns true if backfill is running on this node for the given bucket.
-spec backfilling(bucket_name()) ->
                         boolean().
backfilling(Bucket) ->
    backfilling(node(), Bucket).

%% @doc Returns true if backfill is running on the given node for the given
%% bucket.
-spec backfilling(node(), bucket_name()) ->
                         boolean().
backfilling(Node, Bucket) ->
    do_call({server(Bucket), Node}, backfilling, ?TIMEOUT).

%% @doc Delete a vbucket. Will set the vbucket to dead state if it
%% isn't already, blocking until it successfully does so.
-spec delete_vbucket(bucket_name(), vbucket_id()) ->
                            ok | mc_error().
delete_vbucket(Bucket, VBucket) ->
    do_call(server(Bucket), {delete_vbucket, VBucket}, ?TIMEOUT_VERY_HEAVY).


-spec delete_vbucket(node(), bucket_name(), vbucket_id()) ->
                            ok | mc_error().
delete_vbucket(Node, Bucket, VBucket) ->
    do_call({server(Bucket), Node}, {delete_vbucket, VBucket},
                    ?TIMEOUT_VERY_HEAVY).


-spec get_vbucket(node(), bucket_name(), vbucket_id()) ->
                         {ok, vbucket_state()} | mc_error().
get_vbucket(Node, Bucket, VBucket) ->
    do_call({server(Bucket), Node}, {get_vbucket, VBucket}, ?TIMEOUT).


-spec host_port(node(), any()) ->
                           {nonempty_string(), pos_integer()}.
host_port(Node, Config) ->
    DefaultPort = ns_config:search_node_prop(Node, Config, memcached, port),
    Port = ns_config:search_node_prop(Node, Config,
                                      memcached, dedicated_port, DefaultPort),
    {_Name, Host} = misc:node_name_host(Node),
    {Host, Port}.

-spec host_port(node()) ->
                           {nonempty_string(), pos_integer()}.
host_port(Node) ->
    host_port(Node, ns_config:get()).

-spec host_port_str(node()) ->
                           nonempty_string().
host_port_str(Node) ->
    {Host, Port} = host_port(Node),
    Host ++ ":" ++ integer_to_list(Port).


-spec list_vbuckets(bucket_name()) ->
    {ok, [{vbucket_id(), vbucket_state()}]} | mc_error().
list_vbuckets(Bucket) ->
    list_vbuckets(node(), Bucket).


-spec list_vbuckets(node(), bucket_name()) ->
    {ok, [{vbucket_id(), vbucket_state()}]} | mc_error().
list_vbuckets(Node, Bucket) ->
    do_call({server(Bucket), Node}, list_vbuckets, ?TIMEOUT).

-spec list_vbuckets_prevstate(node(), bucket_name()) ->
    {ok, [{vbucket_id(), vbucket_state()}]} | mc_error().
list_vbuckets_prevstate(Node, Bucket) ->
    do_call({server(Bucket), Node}, list_vbuckets_prevstate, ?TIMEOUT).


-spec list_vbuckets_multi([node()], bucket_name()) ->
                                 {[{node(), {ok, [{vbucket_id(),
                                                   vbucket_state()}]}}],
                                  [node()]}.
list_vbuckets_multi(Nodes, Bucket) ->
    UpNodes = [node()|nodes()],
    {LiveNodes, DeadNodes} = lists:partition(
                               fun (Node) ->
                                       lists:member(Node, UpNodes)
                               end, Nodes),
    {Replies, Zombies} =
        gen_server:multi_call(LiveNodes, server(Bucket), list_vbuckets,
                              ?TIMEOUT),
    {Replies, Zombies ++ DeadNodes}.


-spec set_vbucket(bucket_name(), vbucket_id(), vbucket_state()) ->
                         ok | mc_error().
set_vbucket(Bucket, VBucket, VBState) ->
    do_call(server(Bucket), {set_vbucket, VBucket, VBState}, ?TIMEOUT_HEAVY).


-spec set_vbucket(node(), bucket_name(), vbucket_id(), vbucket_state()) ->
                         ok | mc_error().
set_vbucket(Node, Bucket, VBucket, VBState) ->
    do_call({server(Bucket), Node}, {set_vbucket, VBucket, VBState},
                    ?TIMEOUT_HEAVY).


-spec stats(bucket_name()) ->
                   {ok, [{binary(), binary()}]} | mc_error().
stats(Bucket) ->
    stats(Bucket, <<>>).


-spec stats(bucket_name(), binary() | string()) ->
                   {ok, [{binary(), binary()}]} | mc_error().
stats(Bucket, Key) ->
    do_call(server(Bucket), {stats, Key}, ?TIMEOUT).


-spec stats(node(), bucket_name(), binary()) ->
                   {ok, [{binary(), binary()}]} | mc_error().
stats(Node, Bucket, Key) ->
    do_call({server(Bucket), Node}, {stats, Key}, ?TIMEOUT).

sync_bucket_config(Bucket) ->
    do_call(server(Bucket), sync_bucket_config, infinity).

-spec deregister_tap_client(Bucket::bucket_name(),
                            TapName::binary()) -> ok.
deregister_tap_client(Bucket, TapName) ->
    do_call(server(Bucket), {deregister_tap_client, TapName}).


-spec topkeys(bucket_name()) ->
                     {ok, [{nonempty_string(), [{atom(), integer()}]}]} |
                     mc_error().
topkeys(Bucket) ->
    do_call(server(Bucket), topkeys, ?TIMEOUT).


-spec raw_stats(node(), bucket_name(), binary(), fun(), any()) -> {ok, any()} | {exception, any()} | {error, any()}.
raw_stats(Node, Bucket, SubStats, Fn, FnState) ->
    do_call({ns_memcached:server(Bucket), Node},
                    {raw_stats, SubStats, Fn, FnState}).


-spec get_vbucket_open_checkpoint(Nodes::[node()],
                           Bucket::bucket_name(),
                           VBucketId::vbucket_id()) -> [{node(), integer() | missing}].
get_vbucket_open_checkpoint(Nodes, Bucket, VBucketId) ->
    StatName = <<"vb_", (iolist_to_binary(integer_to_list(VBucketId)))/binary, ":open_checkpoint_id">>,
    {OkNodes, BadNodes} = gen_server:multi_call(Nodes, server(Bucket), {stats, <<"checkpoint">>}, ?TIMEOUT_OPEN_CHECKPOINT),
    case BadNodes of
        [] -> ok;
        _ ->
            ?log_error("Some nodes failed checkpoint stats call: ~p", [BadNodes])
    end,
    [begin
         PList = case proplists:get_value(N, OkNodes) of
                     {ok, Good} -> Good;
                     undefined ->
                         [];
                     Bad ->
                         ?log_error("checkpoints stats call on ~p returned bad value: ~p", [N, Bad]),
                         []
                 end,
         Value = case proplists:get_value(StatName, PList) of
                     undefined ->
                         missing;
                     Value0 ->
                         list_to_integer(binary_to_list(Value0))
                 end,
         {N, Value}
     end || N <- Nodes].

connect_and_send_isasl_refresh() ->
    case connect(1) of
        {ok, Sock}  ->
            try
                ok = mc_client_binary:refresh_isasl(Sock)
            after
                gen_tcp:close(Sock)
            end;
        Error ->
            Error
    end.

%%
%% Internal functions
%%

connect() ->
    connect(?CONNECTION_ATTEMPTS).

connect(0) ->
    {error, couldnt_connect_to_memcached};
connect(Tries) ->
    Config = ns_config:get(),
    Port = ns_config:search_node_prop(Config, memcached, dedicated_port),
    User = ns_config:search_node_prop(Config, memcached, admin_user),
    Pass = ns_config:search_node_prop(Config, memcached, admin_pass),
    try
        {ok, S} = gen_tcp:connect("127.0.0.1", Port,
                                  [binary, {packet, 0}, {active, false}]),
        ok = mc_client_binary:auth(S, {<<"PLAIN">>,
                                       {list_to_binary(User),
                                        list_to_binary(Pass)}}),
        S of
        Sock -> {ok, Sock}
    catch
        E:R ->
            ?log_warning("Unable to connect: ~p, retrying.", [{E, R}]),
            timer:sleep(1000), % Avoid reconnecting too fast.
            connect(Tries - 1)
    end.


ensure_bucket(Sock, Bucket) ->
    try ns_bucket:config_string(Bucket) of
        {Engine, ConfigString, BucketType, ExtraParams} ->
            case mc_client_binary:select_bucket(Sock, Bucket) of
                ok ->
                    ensure_bucket_config(Sock, Bucket, BucketType, ExtraParams);
                {memcached_error, key_enoent, _} ->
                    case mc_client_binary:create_bucket(Sock, Bucket, Engine,
                                                        ConfigString) of
                        ok ->
                            ?log_info("Created bucket ~p with config string ~p",
                                      [Bucket, ConfigString]),
                            ok = mc_client_binary:select_bucket(Sock, Bucket);
                        {memcached_error, key_eexists, <<"Bucket exists: stopping">>} ->
                            %% Waiting for an old bucket with this name to shut down
                            ?log_info("Waiting for ~p to finish shutting down before we start it.",
                                      [Bucket]),
                            timer:sleep(1000),
                            ensure_bucket(Sock, Bucket);
                        Error ->
                            {error, {bucket_create_error, Error}}
                    end;
                Error ->
                    {error, {bucket_select_error, Error}}
            end
    catch
        E:R ->
            ?log_error("Unable to get config for bucket ~p: ~p",
                       [Bucket, {E, R, erlang:get_stacktrace()}]),
            {E, R}
    end.


-spec ensure_bucket_config(port(), bucket_name(), bucket_type(),
                           {pos_integer(), nonempty_string()}) ->
                                  ok | no_return().
ensure_bucket_config(Sock, Bucket, membase, {MaxSize, DBDir}) ->
    MaxSizeBin = list_to_binary(integer_to_list(MaxSize)),
    DBDirBin = list_to_binary(DBDir),
    {ok, {ActualMaxSizeBin,
          ActualDBDirBin}} = mc_binary:quick_stats(
                               Sock, <<>>,
                               fun (<<"ep_max_data_size">>, V, {_, Path}) ->
                                       {V, Path};
                                   (<<"ep_dbname">>, V, {S, _}) ->
                                       {S, V};
                                   (_, _, CD) ->
                                       CD
                               end, {missing_max_size, missing_path}),
    case ActualMaxSizeBin of
        MaxSizeBin ->
            ok;
        X1 when is_binary(X1) ->
            ?log_info("Changing max_size of ~p from ~s to ~s", [Bucket, X1,
                                                                MaxSizeBin]),
            mc_client_binary:set_flush_param(Sock, <<"max_size">>, MaxSizeBin)
    end,
    case ActualDBDirBin of
        DBDirBin ->
            ok;
        X2 when is_binary(X2) ->
            ?log_info("Changing dbname of ~p from ~s to ~s", [Bucket, X2,
                                                              DBDirBin]),
            %% Just exit; this will delete and recreate the bucket
            exit(normal)
    end;
ensure_bucket_config(Sock, _Bucket, memcached, _MaxSize) ->
    %% TODO: change max size of memcached bucket also
    %% Make sure it's a memcached bucket
    {ok, present} = mc_binary:quick_stats(
                      Sock, <<>>,
                      fun (<<"evictions">>, _, _) ->
                              present;
                          (_, _, CD) ->
                              CD
                      end, not_present),
    ok.


server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

has_started(Sock) ->
    Fun = fun (<<"ep_warmup_thread">>, V, _) -> V;
              (_, _, CD) -> CD
          end,
    case mc_binary:quick_stats(Sock, <<>>, Fun, missing_stat) of
        {ok, <<"complete">>} ->
            true;
        {ok, missing_stat} ->
            true;
        {ok, _} ->
            false
    end.

do_call(Server, Msg, Timeout) ->
    StartTS = os:timestamp(),
    try
        gen_server:call(Server, Msg, Timeout)
    after
        try
            EndTS = os:timestamp(),
            Diff = timer:now_diff(EndTS, StartTS),
            Service = case Server of
                          _ when is_atom(Server) ->
                              atom_to_list(Server);
                          _ ->
                              "unknown"
                      end,
            system_stats_collector:increment_counter({Service, e2e_call_time}, Diff),
            system_stats_collector:increment_counter({Service, e2e_calls}, 1)
        catch T:E ->
                ?log_debug("failed to measure ns_memcached call:~n~p", [{T,E,erlang:get_stacktrace()}])
        end
    end.

do_call(Server, Msg) ->
    do_call(Server, Msg, 5000).
