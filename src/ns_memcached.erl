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
%% Calls to memcached that can potentially take long time are passed
%% down to one of worker processes. ns_memcached process is
%% maintaining list of ready workers and calls queue. When
%% gen_server:call arrives it is added to calls queue. And if there's
%% ready worker, it is dequeued and sent to worker. Worker then does
%% direct gen_server:reply to caller.
%%
-module(ns_memcached).

-behaviour(gen_server).

-include("ns_common.hrl").

-define(CHECK_INTERVAL, 10000).
-define(CHECK_WARMUP_INTERVAL, 500).
-define(VBUCKET_POLL_INTERVAL, 100).
-define(EVAL_TIMEOUT, ns_config_ets_dup:get_timeout(ns_memcached_eval, 120000)).
-define(TIMEOUT, ns_config_ets_dup:get_timeout(ns_memcached_outer, 180000)).
-define(TIMEOUT_OPEN_CHECKPOINT, ns_config_ets_dup:get_timeout(ns_memcached_open_checkpoint, 180000)).
-define(TIMEOUT_HEAVY, ns_config_ets_dup:get_timeout(ns_memcached_outer_heavy, 180000)).
-define(TIMEOUT_VERY_HEAVY, ns_config_ets_dup:get_timeout(ns_memcached_outer_very_heavy, 360000)).
-define(CONNECTED_TIMEOUT, ns_config_ets_dup:get_timeout(ns_memcached_connected, 5000)).
-define(WARMED_TIMEOUT, ns_config_ets_dup:get_timeout(ns_memcached_warmed, 5000)).
-define(MARK_WARMED_TIMEOUT,
        ns_config_ets_dup:get_timeout(ns_memcached_mark_warmed, 5000)).
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
          status :: connecting | init | connected | warmed,
          start_time::tuple(),
          bucket::nonempty_string(),
          sock = still_connecting :: port() | still_connecting,
          timer::any(),
          work_requests = [],
          warmup_stats = [] :: [{binary(), binary()}]
         }).

%% external API
-export([active_buckets/0,
         backfilling/1,
         backfilling/2,
         connected/2,
         connected/3,
         warmed/2,
         warmed/3,
         warmed_buckets/0,
         warmed_buckets/1,
         mark_warmed/2,
         mark_warmed/3,
         disable_traffic/2,
         delete_vbucket/2, delete_vbucket/3,
         sync_delete_vbucket/2,
         get_vbucket/3,
         get_vbucket_details_stats/2,
         host_port/1,
         host_port/2,
         host_port_str/1,
         list_vbuckets/1, list_vbuckets/2,
         local_connected_and_list_vbuckets/1,
         list_vbuckets_prevstate/2,
         list_vbuckets_multi/2,
         set_vbucket/3, set_vbucket/4,
         server/1,
         stats/1, stats/2, stats/3,
         warmup_stats/1,
         topkeys/1,
         raw_stats/5,
         sync_bucket_config/1,
         deregister_tap_client/2,
         flush/1,
         get_vbucket_open_checkpoint/3,
         set/4,
         ready_nodes/4,
         sync/4, add/4, get/3, delete/3, delete/4,
         get_from_replica/3,
         get_meta/3,
         update_with_rev/7,
         connect_and_send_isasl_refresh/0,
         get_vbucket_checkpoint_ids/2,
         create_new_checkpoint/2,
         eval/2,
         wait_for_checkpoint_persistence/3,
         get_tap_docs_estimate/3,
         get_mass_tap_docs_estimate/2,
         set_cluster_config/2,
         get_random_key/1,
         compact_vbucket/3,
         get_upr_backfill_remaining_items/3]).

%% for ns_memcached_sockets_pool only
-export([connect/0]).

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
    ?log_debug("Starting ns_memcached"),
    Q = queue:new(),
    WorkersCount = case ns_config:search_node(ns_memcached_workers_count) of
                       false -> 4;
                       {value, DefinedWorkersCount} ->
                           DefinedWorkersCount
                   end,
    Self = self(),
    proc_lib:spawn_link(erlang, apply, [fun run_connect_phase/3, [Self, Bucket, WorkersCount]]),
    proc_lib:init_ack({ok, Self}),
    gen_server:enter_loop(?MODULE, [],
                          #state{
                                  status = connecting,
                                  bucket = Bucket,
                                  work_requests = [],
                                  fast_calls_queue = Q,
                                  heavy_calls_queue = Q,
                                  very_heavy_calls_queue = Q,
                                  running_fast = WorkersCount
                                }),
    erlang:error(impossible).

run_connect_phase(Parent, Bucket, WorkersCount) ->
    ?log_debug("Started 'connecting' phase of ns_memcached-~s. Parent is ~p", [Bucket, Parent]),
    RV = case connect() of
             {ok, Sock} ->
                 gen_tcp:controlling_process(Sock, Parent),
                 {ok, Sock};
             {error, _} = Error  ->
                 Error
         end,
    gen_server:cast(Parent, {connect_done, WorkersCount, RV}),
    erlang:unlink(Parent).

worker_init(Parent, ParentState) ->
    ParentState1 = do_worker_init(ParentState),
    worker_loop(Parent, ParentState1, #state.running_fast).

do_worker_init(State) ->
    {ok, Sock} = connect(),
    ok = mc_client_binary:select_bucket(Sock, State#state.bucket),
    State#state{sock = Sock}.

worker_loop(Parent, #state{sock = Sock} = State, PrevCounterSlot) ->
    {Msg, From, StartTS, CounterSlot} = gen_server:call(Parent, {get_work, PrevCounterSlot}, infinity),
    WorkStartTS = os:timestamp(),

    {Reply, NewState} =
        case do_handle_call(Msg, From, State) of
            %% note we only accept calls that don't mutate state. So in- and
            %% out- going states asserted to be same.
            {reply, R, State} ->
                {R, State};
            {compromised_reply, R, State} ->
                ok = gen_tcp:close(Sock),
                ?log_warning("Call ~p compromised our connection. Reconnecting.",
                             [Msg]),
                {R, do_worker_init(State)}
        end,

    gen_server:reply(From, Reply),
    verify_report_long_call(StartTS, WorkStartTS, NewState, Msg, []),
    worker_loop(Parent, NewState, CounterSlot).

handle_call({get_work, CounterSlot}, From, #state{work_requests = Froms} = State) ->
    State2 = State#state{work_requests = [From | Froms]},
    Counter = erlang:element(CounterSlot, State2) - 1,
    State3 = erlang:setelement(CounterSlot, State2, Counter),
    {noreply, maybe_deliver_work(State3)};
handle_call(connected, _From, #state{status=Status} = State) ->
    Warmed = Status =:= warmed,
    Connected = Warmed orelse Status =:= connected,
    Reply = [{connected, Connected},
             {warmed, Warmed}],
    {reply, Reply, State};
handle_call(connected_and_list_vbuckets, _From, #state{status = Status} = State)
  when Status =:= init orelse Status =:= connecting ->
    {reply, warming_up, State};
handle_call(connected_and_list_vbuckets, From, State) ->
    handle_call(list_vbuckets, From, State);
handle_call(disable_traffic, _From, State) ->
    case State#state.status of
        Status when Status =:= warmed; Status =:= connected ->
            ?log_info("Disabling traffic and unmarking bucket as warmed"),
            case mc_client_binary:disable_traffic(State#state.sock) of
                ok ->
                    State2 = State#state{status=connected,
                                         start_time = os:timestamp()},
                    {reply, ok, State2};
                {memcached_error, _, _} = Error ->
                    ?log_error("disabling traffic failed: ~p", [Error]),
                    {reply, Error, State}
            end;
        _ ->
            {reply, bad_status, State}
    end;
handle_call(mark_warmed, _From, #state{status=Status,
                                       bucket=Bucket,
                                       start_time=Start,
                                       sock=Sock} = State) ->
    {NewStatus, Reply} =
        case Status of
            connected ->
                ?log_info("Enabling traffic to bucket ~p", [Bucket]),
                case mc_client_binary:enable_traffic(Sock) of
                    ok ->
                        Time = timer:now_diff(os:timestamp(), Start) div 1000000,
                        ?log_info("Bucket ~p marked as warmed in ~p seconds",
                                  [Bucket, Time]),
                        {warmed, ok};
                    Error ->
                        ?log_error("Failed to enable traffic to bucket ~p: ~p",
                                   [Bucket, Error]),
                        {Status, Error}
                end;
            warmed ->
                {warmed, ok};
            _ ->
                {Status, bad_status}
        end,

    {reply, Reply, State#state{status=NewStatus}};
handle_call(sync_bucket_config = Msg, _From, State) ->
    StartTS = os:timestamp(),
    handle_info(check_config, State),
    verify_report_long_call(StartTS, StartTS, State, Msg, {reply, ok, State});
handle_call(warmup_stats, _From, State) ->
    {reply, State#state.warmup_stats, State};
handle_call(Msg, From, State) ->
    StartTS = os:timestamp(),
    NewState = queue_call(Msg, From, StartTS, State),
    {noreply, NewState}.

perform_very_long_call(Fun, Bucket) ->
    misc:executing_on_new_process(
      fun () ->
              case ns_memcached_sockets_pool:take_socket(Bucket) of
                  {ok, Sock} ->
                      {reply, R} = Fun(Sock),
                      ns_memcached_sockets_pool:put_socket(Sock),
                      R;
                  Error ->
                      Error
              end
      end).

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
                ?log_debug("call ~p took too long: ~p us", [Msg, Diff]);
            true ->
                ok
        end
    end.

%% anything effectful is likely to be heavy
assign_queue({delete_vbucket, _}) -> #state.very_heavy_calls_queue;
assign_queue({sync_delete_vbucket, _}) -> #state.very_heavy_calls_queue;
assign_queue(flush) -> #state.very_heavy_calls_queue;
assign_queue({set_vbucket, _, _}) -> #state.heavy_calls_queue;
assign_queue({deregister_tap_client, _}) -> #state.heavy_calls_queue;
assign_queue({add, _Key, _VBucket, _Value}) -> #state.heavy_calls_queue;
assign_queue({get, _Key, _VBucket}) -> #state.heavy_calls_queue;
assign_queue({get_from_replica, _Key, _VBucket}) -> #state.heavy_calls_queue;
assign_queue({get_meta, _Key, _VBucket}) -> #state.heavy_calls_queue;
assign_queue({delete, _Key, _VBucket, _CAS}) -> #state.heavy_calls_queue;
assign_queue({set, _Key, _VBucket, _Value}) -> #state.heavy_calls_queue;
assign_queue({update_with_rev, _Key, _VBucket, _Value, _Meta, _Deleted, _LocalCAS}) -> #state.heavy_calls_queue;
assign_queue({sync, _Key, _VBucket, _CAS}) -> #state.very_heavy_calls_queue;
assign_queue({get_mass_tap_docs_estimate, _VBuckets}) -> #state.very_heavy_calls_queue;
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

maybe_deliver_work(#state{running_very_heavy = RunningVeryHeavy,
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
                            case RunningVeryHeavy of
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
do_handle_call({sync_delete_vbucket, VBucket}, _From, #state{sock=Sock} = State) ->
    ?log_info("sync-deleting vbucket ~p", [VBucket]),
    ok = mc_client_binary:set_vbucket(Sock, VBucket, dead),
    Reply = mc_client_binary:sync_delete_vbucket(Sock, VBucket),
    {reply, Reply, State};
do_handle_call({get_vbucket, VBucket}, _From, State) ->
    Reply = mc_client_binary:get_vbucket(State#state.sock, VBucket),
    {reply, Reply, State};
do_handle_call({get_vbucket_details_stats, VBucket}, _From, State) ->
    VBucketStr = integer_to_list(VBucket),
    Prefix = list_to_binary(VBucketStr),
    Reply = mc_binary:quick_stats(
              State#state.sock,
              iolist_to_binary([<<"vbucket-details ">>, VBucketStr]),
              fun (<<"vb_", K/binary>>, V, Acc) ->
                      case binary:split(K, [<<":">>]) of
                          [Prefix, Key] ->
                              [{binary_to_list(Key), binary_to_list(V)} | Acc];
                          _ ->
                              Acc
                      end
              end, []),
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

do_handle_call({delete, Key, VBucket, CAS}, _From, State) ->
    Reply = mc_client_binary:cmd(?DELETE, State#state.sock, undefined, undefined,
                                 {#mc_header{vbucket = VBucket},
                                  #mc_entry{key = Key, cas = CAS}}),
    {reply, Reply, State};

do_handle_call({set, Key, VBucket, Val}, _From, State) ->
    Reply = mc_client_binary:cmd(?SET, State#state.sock, undefined, undefined,
                                 {#mc_header{vbucket = VBucket},
                                  #mc_entry{key = Key, data = Val}}),
    {reply, Reply, State};

do_handle_call({update_with_rev, VBucket, Key, Value, Rev, Deleting, LocalCAS},
               _From, State) ->
    Reply = mc_client_binary:update_with_rev(State#state.sock,
                                             VBucket, Key, Value, Rev, Deleting, LocalCAS),
    {reply, Reply, State};

do_handle_call({create_new_checkpoint, VBucket},
            _From, State) ->
    Reply = mc_client_binary:create_new_checkpoint(State#state.sock, VBucket),
    {reply, Reply, State};


do_handle_call({add, Key, VBucket, Val}, _From, State) ->
    Reply = mc_client_binary:cmd(?ADD, State#state.sock, undefined, undefined,
                                 {#mc_header{vbucket = VBucket},
                                  #mc_entry{key = Key, data = Val}}),
    {reply, Reply, State};

do_handle_call({get, Key, VBucket}, _From, State) ->
    Reply = mc_client_binary:cmd(?GET, State#state.sock, undefined, undefined,
                                 {#mc_header{vbucket = VBucket},
                                  #mc_entry{key = Key}}),
    {reply, Reply, State};

do_handle_call({get_from_replica, Key, VBucket}, _From, State) ->
    Reply = mc_client_binary:cmd(?CMD_GET_REPLICA, State#state.sock, undefined, undefined,
                                 {#mc_header{vbucket = VBucket},
                                  #mc_entry{key = Key}}),
    {reply, Reply, State};

do_handle_call({get_meta, Key, VBucket}, _From, State) ->
    Reply = mc_client_binary:get_meta(State#state.sock, Key, VBucket),
    {reply, Reply, State};

do_handle_call({sync, Key, VBucket, CAS}, _From, State) ->
    {reply, mc_client_binary:sync(State#state.sock, VBucket, Key, CAS), State};

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
do_handle_call({get_tap_docs_estimate, VBucketId, TapName}, _From, State) ->
    {reply, mc_client_binary:get_tap_docs_estimate(State#state.sock, VBucketId, TapName), State};
do_handle_call({get_mass_tap_docs_estimate, VBuckets}, _From, State) ->
    {reply, mc_client_binary:get_mass_tap_docs_estimate(State#state.sock, VBuckets), State};
do_handle_call({set_cluster_config, Blob}, _From, State) ->
    {reply, mc_client_binary:set_cluster_config(State#state.sock, Blob), State};
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
do_handle_call({eval, Fn, Ref}, _From, #state{sock=Sock} = State) ->
    try
        R = Fn(Sock),
        {reply, R, State}
    catch
        T:E ->
            {compromised_reply,
             {thrown, Ref, T, E, erlang:get_stacktrace()}, State}
    end;
do_handle_call({get_vbucket_checkpoint_ids, VBucketId}, _From, State) ->
    Res = mc_binary:quick_stats(
            State#state.sock, iolist_to_binary([<<"checkpoint ">>, integer_to_list(VBucketId)]),
            fun (K, V, {PersistedAcc, OpenAcc} = Acc) ->
                    case misc:is_binary_ends_with(K, <<":persisted_checkpoint_id">>) of
                        true ->
                            {list_to_integer(binary_to_list(V)), OpenAcc};
                        _->
                            case misc:is_binary_ends_with(K, <<":open_checkpoint_id">>) of
                                true ->
                                    {PersistedAcc, list_to_integer(binary_to_list(V))};
                                _ ->
                                    Acc
                            end
                    end
            end,
            {undefined, undefined}),
    {reply, Res, State};
do_handle_call(get_random_key, _From, State) ->
    {reply, mc_client_binary:get_random_key(State#state.sock), State};
do_handle_call({get_upr_backfill_remaining_items, ConnName, VBucket}, _From, State) ->
    Key = list_to_binary("upr-vbtakeover " ++ integer_to_list(VBucket) ++ " " ++ ConnName),

    {ok, Reply} = mc_binary:quick_stats(State#state.sock,
                                        Key,
                                        fun (<<"backfillRemaining">>, <<V/binary>>, _Acc) ->
                                                list_to_integer(binary_to_list(V));
                                            (_, _, Acc) -> Acc
                                        end, undefined),
    {reply, Reply, State};

do_handle_call(_, _From, State) ->
    {reply, unhandled, State}.


complete_connection_phase({ok, Sock}, Bucket) ->
    case ensure_bucket(Sock, Bucket) of
        ok ->
            {ok, Sock};
        EnsureBucketError ->
            {ensure_bucket_failed, EnsureBucketError}
    end;
complete_connection_phase(Err, _Bucket) ->
    Err.

handle_cast({connect_done, WorkersCount, RV}, #state{bucket = Bucket,
                                                     status = OldStatus} = State) ->
    gen_event:notify(buckets_events, {started, Bucket}),

    case complete_connection_phase(RV, Bucket) of
        {ok, Sock} ->
            connecting = OldStatus,

            ?log_info("Main ns_memcached connection established: ~p", [RV]),

            {ok, Timer} = timer2:send_interval(?CHECK_WARMUP_INTERVAL, check_started),
            Self = self(),
            Self ! check_started,
            erlang:process_flag(trap_exit, true),

            InitialState = State#state{
                             timer = Timer,
                             start_time = os:timestamp(),
                             sock = Sock,
                             status = init
                            },
            [proc_lib:spawn_link(erlang, apply, [fun worker_init/2, [Self, InitialState]])
             || _ <- lists:seq(1, WorkersCount)],
            {noreply, InitialState};
        Error ->
            ?log_info("Failed to establish ns_memcached connection: ~p", [RV]),
            {stop, Error}
    end;

handle_cast(start_completed, #state{start_time=Start,
                                    bucket=Bucket} = State) ->
    ale:info(?USER_LOGGER, "Bucket ~p loaded on node ~p in ~p seconds.",
             [Bucket, node(), timer:now_diff(os:timestamp(), Start) div 1000000]),
    gen_event:notify(buckets_events, {loaded, Bucket}),
    timer2:send_interval(?CHECK_INTERVAL, check_config),
    BucketConfig = case ns_bucket:get_bucket(State#state.bucket) of
                       {ok, BC} -> BC;
                       not_present -> []
                   end,
    NewStatus = case proplists:get_value(type, BucketConfig, unknown) of
                    memcached ->
                        %% memcached buckets are warmed up automagically
                        warmed;
                    _ ->
                        connected
                end,
    {noreply, State#state{status=NewStatus, warmup_stats=[]}}.


handle_info(check_started, #state{status=Status} = State)
  when Status =:= connected orelse Status =:= warmed ->
    {noreply, State};
handle_info(check_started, #state{timer=Timer, sock=Sock} = State) ->
    Stats = retrieve_warmup_stats(Sock),
    case has_started(Stats) of
        true ->
            {ok, cancel} = timer2:cancel(Timer),
            misc:flush(check_started),
            Pid = self(),
            proc_lib:spawn_link(
              fun () ->
                      ns_config_isasl_sync:sync(),

                      gen_server:cast(Pid, start_completed),
                      %% we don't want exit signal in parent's message
                      %% box if everything went fine. Otherwise
                      %% ns_memcached would terminate itself (see
                      %% handle_info for EXIT message below)
                      erlang:unlink(Pid)
              end),
            {noreply, State};
        false ->
            {ok, S} = Stats,
            {noreply, State#state{warmup_stats = S}}
    end;
handle_info(check_config, State) ->
    misc:flush(check_config),
    StartTS = os:timestamp(),
    ensure_bucket(State#state.sock, State#state.bucket),
    Diff = timer:now_diff(os:timestamp(), StartTS),
    if
        Diff > ?SLOW_CALL_THRESHOLD_MICROS ->
            ?log_debug("handle_info(ensure_bucket,..) took too long: ~p us", [Diff]);
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


terminate(_Reason, #state{sock = still_connecting}) ->
    ?log_debug("Dying when socket is not yet connected");
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
        Reason == normal; Reason == shutdown; Reason =:= {shutdown, reconfig} ->
            Reconfig = (Reason =:= {shutdown, reconfig}),

            ale:info(?USER_LOGGER, "Shutting down bucket ~p on ~p for ~s",
                     [Bucket, node(), if
                                          Reconfig -> "reconfiguration";
                                          Deleting -> "deletion";
                                          true -> "server shutdown"
                                      end]),
            try
                case Deleting orelse Reconfig of
                    false ->
                        %% if this is system shutdown bucket engine
                        %% now can reliably delete all buckets as part of shutdown.
                        %% if this is supervisor crash, we're fine too
                        ?log_info("This bucket shutdown is not due to bucket deletion or reconfiguration. Doing nothing");
                    true ->
                        ok = mc_client_binary:delete_bucket(Sock, Bucket, [{force, not(Reconfig)}])
                end
            catch E2:R2 ->
                    ?log_error("Failed to delete bucket ~p: ~p",
                               [Bucket, {E2, R2}])
            after
                case NoBucket of
                    %% files are deleted here only when bucket is deleted; in
                    %% all the other cases (like node removal or failover) we
                    %% leave them on the file system and let others decide
                    %% when they should be deleted
                    true ->
                        ?log_debug("Proceeding into vbuckets dbs deletions"),
                        ns_storage_conf:delete_databases_and_files(Bucket);
                    _ -> ok
                end
            end;
        true ->
            ale:info(?USER_LOGGER,
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

-spec connected_common(node(), bucket_name(), Timeout, NewRespFn) -> boolean()
  when Timeout :: pos_integer() | infinity,
       NewRespFn :: fun ((list()) -> boolean()).
connected_common(Node, Bucket, Timeout, NewRespFn) ->
    Address = {server(Bucket), Node},
    try
        %% I decided to not introduce new call to detect if ns_memcached is
        %% warmed up because it would require additional round trip for some
        %% nodes: first detect that node does not understand the new call,
        %% then call the old one. Instead new nodes will return a proplist as
        %% a reply to the 'connected' call saying if node is connected and
        %% warmed up. It's also important that this call is performed either
        %% from some node to itself or from master to any other node. And
        %% since we more or less guarantee that master is always on the newest
        %% version, it should not impose backward compatibility issues.
        R = do_call(Address, connected, Timeout),
        handle_connected_result(R, NewRespFn)
    catch
        _:_ ->
            false
    end.

-spec connected(node(), bucket_name(), pos_integer() | infinity) -> boolean().
connected(Node, Bucket, Timeout) ->
    connected_common(Node, Bucket, Timeout,
                     fun extract_new_response_connected/1).

-spec connected(node(), bucket_name()) -> boolean().
connected(Node, Bucket) ->
    connected(Node, Bucket, ?CONNECTED_TIMEOUT).

-spec warmed(node(), bucket_name(), pos_integer() | infinity) -> boolean().
warmed(Node, Bucket, Timeout) ->
    connected_common(Node, Bucket, Timeout,
                     fun extract_new_response_warmed/1).

-spec warmed(node(), bucket_name()) -> boolean().
warmed(Node, Bucket) ->
    warmed(Node, Bucket, ?WARMED_TIMEOUT).

-spec mark_warmed([node()], bucket_name(), Timeout) -> Result
  when Timeout :: pos_integer() | infinity,
       Result :: {Replies, BadNodes},
       Replies :: [{node(), any()}],
       BadNodes :: [node()].
mark_warmed(Nodes, Bucket, Timeout) ->
    gen_server:multi_call(Nodes, server(Bucket), mark_warmed, Timeout).

-spec mark_warmed([node()], bucket_name()) -> Result
   when Result :: {Replies, BadNodes},
        Replies :: [{node(), any()}],
        BadNodes :: [node()].
mark_warmed(Nodes, Bucket) ->
    mark_warmed(Nodes, Bucket, ?MARK_WARMED_TIMEOUT).

-spec ready_nodes([node()], bucket_name(), up | connected, pos_integer() | infinity | default) -> [node()].
ready_nodes(Nodes, Bucket, Type, default) ->
    ready_nodes(Nodes, Bucket, Type, ?CONNECTED_TIMEOUT);
ready_nodes(Nodes, Bucket, Type, Timeout) ->
    UpNodes = ordsets:intersection(ordsets:from_list(Nodes),
                                   ordsets:from_list([node() | nodes()])),
    {Replies0, _BadNodes} = gen_server:multi_call(UpNodes, server(Bucket), connected, Timeout),

    Replies =
        lists:keymap(
          fun (R) ->
                  handle_connected_result(R, fun extract_new_response_connected/1)
          end, 2, Replies0),

    case Type of
        up ->
            [N || {N, _} <- Replies];
        connected ->
            [N || {N, true} <- Replies]
    end.

warmed_buckets() ->
    warmed_buckets(?WARMED_TIMEOUT).

warmed_buckets(Timeout) ->
    RVs = misc:parallel_map(
            fun (Bucket) ->
                    {Bucket, warmed(node(), Bucket, Timeout)}
            end, active_buckets(), infinity),
    [Bucket || {Bucket, true} <- RVs].

%% @doc Send flush command to specified bucket
-spec flush(bucket_name()) -> ok.
flush(Bucket) ->
    do_call({server(Bucket), node()}, flush, ?TIMEOUT_VERY_HEAVY).


%% @doc send an add command to memcached instance
-spec add(bucket_name(), binary(), integer(), binary()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}.
add(Bucket, Key, VBucket, Value) ->
    do_call({server(Bucket), node()},
            {add, Key, VBucket, Value}, ?TIMEOUT_HEAVY).

%% @doc send get command to memcached instance
-spec get(bucket_name(), binary(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}.
get(Bucket, Key, VBucket) ->
    do_call({server(Bucket), node()}, {get, Key, VBucket}, ?TIMEOUT_HEAVY).

%% @doc send get_from_replica command to memcached instance. for testing only
-spec get_from_replica(bucket_name(), binary(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}.
get_from_replica(Bucket, Key, VBucket) ->
    do_call({server(Bucket), node()}, {get_from_replica, Key, VBucket}, ?TIMEOUT_HEAVY).

%% @doc send an get metadata command to memcached
-spec get_meta(bucket_name(), binary(), integer()) ->
    {ok, rev(), integer(), integer()}
    | {memcached_error, key_enoent, integer()}
    | mc_error().
get_meta(Bucket, Key, VBucket) ->
    do_call({server(Bucket), node()},
            {get_meta, Key, VBucket}, ?TIMEOUT_HEAVY).


%% @doc send a set command to memcached instance
-spec delete(bucket_name(), binary(), integer(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}, any()} | {memcached_error, any(), any()}.
delete(Bucket, Key, VBucket, CAS) ->
    do_call({server(Bucket), node()},
            {delete, Key, VBucket, CAS}, ?TIMEOUT_HEAVY).


delete(Bucket, Key, VBucket) ->
    delete(Bucket, Key, VBucket, 0).

%% @doc send a set command to memcached instance
-spec set(bucket_name(), binary(), integer(), binary()) ->
    {ok, #mc_header{}, #mc_entry{}, any()} | {memcached_error, any(), any()}.
set(Bucket, Key, VBucket, Value) ->
    do_call({server(Bucket), node()},
            {set, Key, VBucket, Value}, ?TIMEOUT_HEAVY).


-spec update_with_rev(Bucket::bucket_name(), VBucket::vbucket_id(),
                      Id::binary(), Value::binary() | undefined, Rev :: rev(),
                      Deleted::boolean(), LocalCAS::non_neg_integer()) ->
                             {ok, #mc_header{}, #mc_entry{}} |
                             {memcached_error, atom(), binary()}.
update_with_rev(Bucket, VBucket, Id, Value, Rev, Deleted, LocalCAS) ->
    do_call(server(Bucket),
            {update_with_rev, VBucket,
             Id, Value, Rev, Deleted,
             LocalCAS},
            ?TIMEOUT_HEAVY).

-spec create_new_checkpoint(bucket_name(), vbucket_id()) ->
    {ok, Checkpoint::integer(), Checkpoint::integer()} | mc_error().
create_new_checkpoint(Bucket, VBucket) ->
    do_call(server(Bucket),
            {create_new_checkpoint, VBucket},
            ?TIMEOUT_HEAVY).

eval(Bucket, Fn) ->
    Ref = make_ref(),
    case do_call(server(Bucket), {eval, Fn, Ref}, ?EVAL_TIMEOUT) of
        {thrown, Ref, T, E, Stack} ->
            erlang:raise(T, E, Stack);
        V ->
            V
    end.

%% @doc send a sync command to memcached instance
-spec sync(bucket_name(), binary(), integer(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}.
sync(Bucket, Key, VBucket, CAS) ->
    do_call({server(Bucket), node()},
            {sync, Key, VBucket, CAS}, ?TIMEOUT_VERY_HEAVY).

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


-spec sync_delete_vbucket(bucket_name(), vbucket_id()) ->
                                 ok | mc_error().
sync_delete_vbucket(Bucket, VBucket) ->
    do_call(server(Bucket), {sync_delete_vbucket, VBucket},
            infinity).


-spec get_vbucket(node(), bucket_name(), vbucket_id()) ->
                         {ok, vbucket_state()} | mc_error().
get_vbucket(Node, Bucket, VBucket) ->
    do_call({server(Bucket), Node}, {get_vbucket, VBucket}, ?TIMEOUT).

-spec get_vbucket_details_stats(bucket_name(), vbucket_id()) ->
                                       {ok, [{nonempty_string(),nonempty_string()}]} | mc_error().
get_vbucket_details_stats(Bucket, VBucket) ->
    do_call(server(Bucket), {get_vbucket_details_stats, VBucket}, ?TIMEOUT).


-spec host_port(node(), any()) ->
                           {nonempty_string(), pos_integer() | undefined}.
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

-spec local_connected_and_list_vbuckets(bucket_name()) -> warming_up | {ok, [{vbucket_id(), vbucket_state()}]}.
local_connected_and_list_vbuckets(Bucket) ->
    do_call(server(Bucket), connected_and_list_vbuckets, ?TIMEOUT).

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

-spec warmup_stats(bucket_name()) -> [{binary(), binary()}].
warmup_stats(Bucket) ->
    do_call(server(Bucket), warmup_stats, ?TIMEOUT).

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

-spec get_vbucket_checkpoint_ids(bucket_name(), vbucket_id()) ->
                                        {ok, {undefined | checkpoint_id(), undefined | checkpoint_id()}}.
get_vbucket_checkpoint_ids(Bucket, VBucketId) ->
    do_call(server(Bucket), {get_vbucket_checkpoint_ids, VBucketId}, ?TIMEOUT).

-spec get_upr_backfill_remaining_items(bucket_name(), string(), vbucket_id()) ->
                                        undefined | integer().
get_upr_backfill_remaining_items(Bucket, ConnName, VBucket) ->
    do_call(server(Bucket), {get_upr_backfill_remaining_items, ConnName, VBucket}, ?TIMEOUT).

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
        {Engine, ConfigString, BucketType, ExtraParams, DBSubDir} ->
            case mc_client_binary:select_bucket(Sock, Bucket) of
                ok ->
                    ensure_bucket_config(Sock, Bucket, BucketType, ExtraParams);
                {memcached_error, key_enoent, _} ->
                    ok = filelib:ensure_dir(DBSubDir),
                    case mc_client_binary:create_bucket(Sock, Bucket, Engine,
                                                        ConfigString) of
                        ok ->
                            ?log_info("Created bucket ~p with config string ~p",
                                      [Bucket, ConfigString]),
                            ok = mc_client_binary:select_bucket(Sock, Bucket);
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
ensure_bucket_config(Sock, Bucket, membase, {MaxSize, DBDir, NumThreads}) ->
    MaxSizeBin = list_to_binary(integer_to_list(MaxSize)),
    DBDirBin = list_to_binary(DBDir),
    NumThreadsBin = list_to_binary(integer_to_list(NumThreads)),
    {ok, {ActualMaxSizeBin,
          ActualDBDirBin,
          ActualNumThreads}} = mc_binary:quick_stats(
                                 Sock, <<>>,
                                 fun (<<"ep_max_size">>, V, {_, Path, T}) ->
                                         {V, Path, T};
                                     (<<"ep_dbname">>, V, {S, _, T}) ->
                                         {S, V, T};
                                     (<<"ep_max_num_workers">>, V, {S, Path, _}) ->
                                         {S, Path, V};
                                     (_, _, CD) ->
                                         CD
                                 end, {missing_max_size, missing_path, missing_num_threads}),

    NeedRestart = (NumThreadsBin =/= ActualNumThreads),
    case NeedRestart of
        true ->
            ale:info(?USER_LOGGER, "Bucket ~p needs to be recreated since "
                     "number of readers/writers changed from ~s to ~s",
                     [Bucket, ActualNumThreads, NumThreadsBin]),
            exit({shutdown, reconfig});
        false ->
            case ActualMaxSizeBin of
                MaxSizeBin ->
                    ok;
                X1 when is_binary(X1) ->
                    ?log_info("Changing max_size of ~p from ~s to ~s", [Bucket, X1,
                                                                        MaxSizeBin]),
                    ok = mc_client_binary:set_flush_param(Sock, <<"max_size">>, MaxSizeBin)
            end,
            case ActualDBDirBin of
                DBDirBin ->
                    ok;
                X2 when is_binary(X2) ->
                    ?log_info("Changing dbname of ~p from ~s to ~s", [Bucket, X2,
                                                                      DBDirBin]),
                    %% Just exit; this will delete and recreate the bucket
                    exit(normal)
            end
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

retrieve_warmup_stats(Sock) ->
    mc_client_binary:stats(Sock, <<"warmup">>, fun (K, V, Acc) -> [{K, V}|Acc] end, []).

has_started({memcached_error, key_enoent, _}) ->
    %% this is memcached bucket, warmup is done :)
    true;
has_started({ok, WarmupStats}) ->
    case lists:keyfind(<<"ep_warmup_thread">>, 1, WarmupStats) of
        {_, <<"complete">>} ->
            true;
        {_, V} when is_binary(V) ->
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

handle_connected_result(R, NewRespFn) ->
    case is_list(R) of
        %% new nodes will return a proplist to us
        true ->
            NewRespFn(R);
        false ->
            R
    end.

extract_new_response_connected(Resp) when is_list(Resp) ->
    R = proplists:get_value(connected, Resp),
    true = is_boolean(R),
    R.

extract_new_response_warmed(Resp) when is_list(Resp) ->
    R = proplists:get_value(warmed, Resp),
    true = is_boolean(R),
    R.

-spec disable_traffic(bucket_name(), non_neg_integer() | infinity) -> ok | bad_status | mc_error().
disable_traffic(Bucket, Timeout) ->
    gen_server:call(server(Bucket), disable_traffic, Timeout).

-spec wait_for_checkpoint_persistence(bucket_name(), vbucket_id(), checkpoint_id()) -> ok | mc_error().
wait_for_checkpoint_persistence(Bucket, VBucketId, CheckpointId) ->
    perform_very_long_call(
      fun (Sock) ->
              {reply, mc_client_binary:wait_for_checkpoint_persistence(Sock, VBucketId, CheckpointId)}
      end, Bucket).

-spec compact_vbucket(bucket_name(), vbucket_id(),
                      {integer(), integer(), boolean()}) ->
                             ok | mc_error().
compact_vbucket(Bucket, VBucket, {PurgeBeforeTS, PurgeBeforeSeqNo, DropDeletes}) ->
    perform_very_long_call(
      fun (Sock) ->
              {reply, mc_client_binary:compact_vbucket(Sock, VBucket,
                                                       PurgeBeforeTS, PurgeBeforeSeqNo, DropDeletes)}
      end, Bucket).


-spec get_tap_docs_estimate(bucket_name(), vbucket_id(), binary()) ->
                                   {ok, {non_neg_integer(), non_neg_integer(), binary()}}.
get_tap_docs_estimate(Bucket, VBucketId, TapName) ->
    do_call(server(Bucket), {get_tap_docs_estimate, VBucketId, TapName}, ?TIMEOUT).

get_mass_tap_docs_estimate(Bucket, VBuckets) ->
    do_call(server(Bucket), {get_mass_tap_docs_estimate, VBuckets}, ?TIMEOUT_VERY_HEAVY).

-spec set_cluster_config(bucket_name(), binary()) -> ok | mc_error().
set_cluster_config(Bucket, Blob) ->
    do_call(server(Bucket), {set_cluster_config, Blob}, ?TIMEOUT).

get_random_key(Bucket) ->
    do_call(server(Bucket), get_random_key, ?TIMEOUT).
