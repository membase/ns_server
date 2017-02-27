%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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
-module(master_activity_events).

-include("ns_common.hrl").

-export([start_link_timestamper/0,
         note_vbucket_state_change/4,
         note_bucket_creation/3,
         note_bucket_deletion/1,
         note_rebalance_start/5,
         note_set_ff_map/3,
         note_set_map/3,
         note_vbucket_mover/6,
         note_move_done/2,
         note_failover/1,
         note_became_master/0,
         note_name_changed/0,
         note_observed_death/3,
         note_bucket_rebalance_started/1,
         note_bucket_rebalance_ended/1,
         note_bucket_failover_started/2,
         note_bucket_failover_ended/2,
         note_indexing_initiated/3,
         note_seqno_waiting_started/4,
         note_seqno_waiting_ended/4,
         note_takeover_started/4,
         note_takeover_ended/4,
         note_backfill_phase_ended/2,
         note_wait_index_updated_started/3,
         note_wait_index_updated_ended/3,
         note_compaction_inhibited/2,
         note_compaction_uninhibit_started/2,
         note_compaction_uninhibit_done/2,
         note_forced_inhibited_view_compaction/1,
         event_to_jsons/1,
         event_to_formatted_iolist/1,
         format_some_history/1,
         note_dcp_replicator_start/5,
         note_dcp_add_stream/6,
         note_dcp_close_stream/5,
         note_dcp_add_stream_response/7,
         note_dcp_close_stream_response/7,
         note_dcp_set_vbucket_state/4,
         note_set_service_map/2,
         note_autofailover_node_state_change/4,
         note_autofailover_done/2
        ]).

-export([stream_events/2]).

submit_cast(Arg) ->
    (catch gen_event:notify(master_activity_events_ingress, {submit_master_event, Arg})).

note_vbucket_state_change(Bucket, Node, VBucketId, NewState) ->
    submit_cast({vbucket_state_change, Bucket, Node, VBucketId, NewState}).

note_bucket_creation(BucketName, BucketType, NewConfig) ->
    submit_cast({create_bucket, BucketName, BucketType, NewConfig}).

note_bucket_deletion(BucketName) ->
    submit_cast({delete_bucket, BucketName}).

note_rebalance_start(Pid, KeepNodes, EjectNodes, FailedNodes, DeltaNodes) ->
    submit_cast({rebalance_start, Pid, KeepNodes, EjectNodes, FailedNodes, DeltaNodes}),
    master_activity_events_pids_watcher:observe_fate_of(Pid, {rebalance_end}).

note_vbucket_mover(Pid, BucketName, Node, VBucketId, OldChain, NewChain) ->
    submit_cast({vbucket_move_start, Pid, BucketName, Node, VBucketId, OldChain, NewChain}),
    master_activity_events_pids_watcher:observe_fate_of(Pid, {vbucket_mover_terminate, BucketName, VBucketId}).

note_move_done(BucketName, VBucketId) ->
    submit_cast({vbucket_move_done, BucketName, VBucketId}).

note_failover(Node) ->
    submit_cast({failover, Node}).

note_became_master() ->
    submit_cast({became_master, node()}).

note_set_ff_map(BucketName, undefined, _OldMap) ->
    submit_cast({set_ff_map, BucketName, undefined});
note_set_ff_map(BucketName, NewMap, OldMap) ->
    Work = fun () ->
                   {set_ff_map, BucketName,
                    misc:compute_map_diff(NewMap, OldMap)}
           end,
    (catch gen_event:notify(master_activity_events_ingress,
                            {submit_custom_master_event, Work})).

note_set_map(BucketName, NewMap, OldMap) ->
    Work = fun () ->
                   {set_map, BucketName,
                    misc:compute_map_diff(NewMap, OldMap)}
           end,
    (catch gen_event:notify(master_activity_events_ingress,
                            {submit_custom_master_event, Work})).

note_name_changed() ->
    Name = node(),
    submit_cast({name_changed, Name}).

note_observed_death(Pid, Reason, EventTuple) ->
    submit_cast(list_to_tuple(tuple_to_list(EventTuple) ++ [Pid, Reason])).

note_bucket_rebalance_started(BucketName) ->
    submit_cast({bucket_rebalance_started, BucketName, self()}).

note_bucket_rebalance_ended(BucketName) ->
    submit_cast({bucket_rebalance_ended, BucketName, self()}).

note_bucket_failover_started(BucketName, Node) ->
    submit_cast({bucket_failover_started, BucketName, Node, self()}).

note_bucket_failover_ended(BucketName, Node) ->
    submit_cast({bucket_failover_ended, BucketName, Node, self()}).

note_indexing_initiated(_BucketName, [], _VBucket) -> ok;
note_indexing_initiated(BucketName, [MasterNode], VBucket) ->
    submit_cast({indexing_initated, BucketName, MasterNode, VBucket}).

note_seqno_waiting_started(BucketName, VBucket, SeqNo, Nodes) ->
    submit_cast({seqno_waiting_started, BucketName, VBucket, SeqNo, Nodes}).

note_seqno_waiting_ended(BucketName, VBucket, SeqNo, Nodes) ->
    submit_cast({seqno_waiting_ended, BucketName, VBucket, SeqNo, Nodes}).

note_takeover_started(BucketName, VBucket, OldMaster, NewMaster) ->
    submit_cast({takeover_started, BucketName, VBucket, OldMaster, NewMaster}).

note_takeover_ended(BucketName, VBucket, OldMaster, NewMaster) ->
    submit_cast({takeover_ended, BucketName, VBucket, OldMaster, NewMaster}).

note_backfill_phase_ended(BucketName, VBucket) ->
    submit_cast({backfill_phase_ended, BucketName, VBucket}).

note_wait_index_updated_started(BucketName, Node, VBucket) ->
    submit_cast({wait_index_updated_started, BucketName, Node, VBucket}).

note_wait_index_updated_ended(BucketName, Node, VBucket) ->
    submit_cast({wait_index_updated_ended, BucketName, Node, VBucket}).

note_compaction_inhibited(BucketName, Node) ->
    submit_cast({compaction_inhibited, BucketName, Node}).

note_compaction_uninhibit_started(BucketName, Node) ->
    submit_cast({compaction_uninhibit_started, BucketName, Node}).

note_compaction_uninhibit_done(BucketName, Node) ->
    submit_cast({compaction_uninhibit_done, BucketName, Node}).

note_forced_inhibited_view_compaction(BucketName) ->
    submit_cast({forced_inhibited_view_compaction, BucketName, node()}).

note_dcp_replicator_start(Bucket, ConnName, ProducerNode, ConsumerConn, ProducerConn) ->
    Pid = self(),
    submit_cast({dcp_replicator_start,
                 Bucket, ConnName, ProducerNode, ConsumerConn, ProducerConn, Pid}),
    master_activity_events_pids_watcher:observe_fate_of(
      Pid, {dcp_replicator_terminate,
            Bucket, ConnName, ProducerNode, ConsumerConn, ProducerConn}).

note_dcp_add_stream(Bucket, ConnName, VBucket, Opaque, Type, Side) ->
    submit_cast({dcp_add_stream, Bucket, ConnName, VBucket, Opaque, Type, Side, self()}).

note_dcp_close_stream(Bucket, ConnName, VBucket, Opaque, Side) ->
    submit_cast({dcp_close_stream, Bucket, ConnName, VBucket, Opaque, Side, self()}).

note_dcp_add_stream_response(Bucket, ConnName, VBucket, Opaque, Side, Status, Success) ->
    submit_cast({dcp_add_stream_response,
                 Bucket, ConnName, VBucket, Opaque, Side, Status, Success, self()}).

note_dcp_close_stream_response(Bucket, ConnName, VBucket, Opaque, Side, Status, Success) ->
    submit_cast({dcp_close_stream_response,
                 Bucket, ConnName, VBucket, Opaque, Side, Status, Success, self()}).

note_dcp_set_vbucket_state(Bucket, ConnName, VBucket, State) ->
    submit_cast({dcp_set_vbucket_state, Bucket, ConnName, VBucket, State, self()}).

note_set_service_map(Service, Nodes) ->
    submit_cast({set_service_map, Service, Nodes}).

note_autofailover_node_state_change(Node, PrevState, NewState, NewCounter) ->
    submit_cast({autofailover_node_state_change, Node, PrevState, NewState,
                 NewCounter}).

note_autofailover_done(Node, Reason) ->
    submit_cast({autofailover_done, Node, Reason}).

start_link_timestamper() ->
    {ok, ns_pubsub:subscribe_link(master_activity_events_ingress, fun timestamper_body/2, [])}.

timestamper_body({submit_custom_master_event, Thunk}, _Ignore) ->
    Event = Thunk(),
    timestamper_body({submit_master_event, Event}, []);
timestamper_body({submit_master_event, Event}, _Ignore) ->
    Master = mb_master:master_node(),
    case Master of
        undefined ->
            ?log_debug("sending master_activity_events event to trash can: ~p", [Event]),
            ok;
        _ when Master =:= node() ->
            timestamper_body(Event, []);
        _ ->
            try gen_event:notify({master_activity_events_ingress, Master}, Event)
            catch T:E ->
                    ?log_debug("Failed to send master activity event: ~p", [{T,E}])
            end
    end;
timestamper_body(Event, _Ignore) ->
    StampedEvent = erlang:list_to_tuple([os:timestamp() | erlang:tuple_to_list(Event)]),
    gen_event:notify(master_activity_events, StampedEvent),
    [].

stream_events(Callback, State) ->
    Ref = make_ref(),
    EofRef = make_ref(),
    Self = self(),
    Fun = fun (Arg, _Ignored) ->
                  Self ! {Ref, Arg},
                  ok
          end,
    LinkPid = ns_pubsub:subscribe_link(master_activity_events, Fun, []),
    try
        case stream_events_history_loop(master_activity_events_keeper:get_history(),
                                        Callback, State, EofRef, undefined) of
            {ok, NewState, LastTS} ->
                CallPredicate =
                    case LastTS of
                        undefined ->
                            fun (_) -> true end;
                        _ ->
                            fun (Event) ->
                                    EventTS = element(1, Event),
                                    timer:now_diff(EventTS, LastTS) > 0
                            end
                    end,
                stream_events_loop(Ref, LinkPid, Callback, NewState, EofRef, CallPredicate);
            {eof, RV} ->
                RV
        end
    after
        ns_pubsub:unsubscribe(LinkPid),
        stream_events_eat_leftover_messages(Ref)
    end.

event_to_formatted_iolist(Event) ->
    [iolist_to_binary([mochijson2:encode({struct, JSON}), "\n"])
     || JSON <- master_activity_events:event_to_jsons(Event)].

-spec format_some_history([[{atom(), any()}]]) -> iolist().
format_some_history(Events) ->
    Ref = make_ref(),
    Callback = fun (Event, Acc, _Dummy) ->
                       [event_to_formatted_iolist(Event) | Acc]
               end,
    {ok, FinalAcc, _} = stream_events_history_loop(Events, Callback, [], Ref, undefined),
    lists:reverse(FinalAcc).


stream_events_history_loop([], _Callback, State, _EofRef, LastTS) ->
    {ok, State, LastTS};
stream_events_history_loop([Event | HistoryRest], Callback, State, EofRef, _LastTS) ->
    EventTS = element(1, Event),
    case Callback(Event, State, EofRef) of
        {EofRef, RV} ->
            {eof, RV};
        NewState ->
            stream_events_history_loop(HistoryRest, Callback, NewState, EofRef, EventTS)
    end.

stream_events_eat_leftover_messages(Ref) ->
    receive
        {Ref, _} ->
            stream_events_eat_leftover_messages(Ref)
    after 0 ->
            ok
    end.

stream_events_loop(Ref, LinkPid, Callback, State, EofRef, CallPredicate) ->
    receive
        {'EXIT', LinkPid, _Reason} = LinkMsg ->
            ?log_error("Got master_activity_events subscriber link death signal: ~p", [LinkMsg]),
            LinkMsg;
        {Ref, Arg} ->
            case CallPredicate(Arg) of
                true ->
                    case Callback(Arg, State, EofRef) of
                        {EofRef, RV} ->
                            RV;
                        NewState ->
                            stream_events_loop(Ref, LinkPid, Callback, NewState, EofRef, CallPredicate)
                    end;
                false ->
                    stream_events_loop(Ref, LinkPid, Callback, State, EofRef, CallPredicate)
            end
    end.

%% note: spec just marking current dialyzer finding that empty list
%% cannot be passed here, so instead of trying to silence dializer on
%% empty list case (which is not used anyway) I'm doing this to warn
%% any potential future users that empty case needs to be added when
%% needed.
-spec format_simple_plist_as_json(nonempty_list()) -> nonempty_list().
format_simple_plist_as_json(PList) ->
    [PList0H | PList0T] = lists:keysort(1, PList),
    {_, PList1} = lists:foldl(fun ({K, _} = Pair, {PrevK, Acc}) ->
                                 case K =:= PrevK of
                                     true ->
                                         {PrevK, Acc};
                                     false ->
                                         {K, [Pair | Acc]}
                                 end
                         end, {element(1, PList0H), [PList0H]}, PList0T),
    [{Key, if is_list(Value) ->
                   iolist_to_binary(Value);
              is_binary(Value) ->
                   Value;
              is_atom(Value) ->
                   Value;
              is_number(Value) ->
                   Value;
              true -> iolist_to_binary(io_lib:format("~p", [Value]))
           end}
     || {Key, Value} <- PList1,
        Value =/= skip_this_pair_please].

format_mcd_pair({Host, Port}) ->
    iolist_to_binary([Host, $:, integer_to_list(Port)]).

node_to_host(undefined, _Config) ->
    <<"">>;
node_to_host(Node, Config) ->
    case ns_memcached:host_port(Node, Config) of
        {_, undefined} ->
            atom_to_binary(Node, latin1);
        HostPort ->
            format_mcd_pair(HostPort)
    end.

maybe_get_pids_node(Pid) when is_pid(Pid) ->
    erlang:node(Pid);
maybe_get_pids_node(_PerhapsBinary) ->
    skip_this_pair_please.

event_to_jsons({TS, vbucket_state_change, Bucket, Node, VBucketId, NewState}) ->
    [format_simple_plist_as_json([{type, vbucketStateChange},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, Bucket},
                                  {host, node_to_host(Node, ns_config:latest())},
                                  {vbucket, VBucketId},
                                  {state, NewState}])];

event_to_jsons({TS, set_ff_map, BucketName, undefined}) ->
    [format_simple_plist_as_json([{type, resetFastForwardMap},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName}])];

event_to_jsons({TS, SetMap, BucketName, Diff}) when SetMap =:= set_map orelse SetMap =:= set_ff_map ->
    Config = ns_config:get(),
    [begin
         Type = case SetMap of
                    set_map -> updateMap;
                    set_ff_map -> updateFastForwardMap
                end,
         format_simple_plist_as_json([{type, Type},
                                      {ts, misc:time_to_epoch_float(TS)},
                                      {bucket, BucketName},
                                      {vbucket, I}])
             ++ [{chainBefore, [node_to_host(N, Config) || N <- OldChain]},
                 {chainAfter, [node_to_host(N, Config) || N <- NewChain]}]
     end || {I, OldChain, NewChain} <- Diff];

event_to_jsons({TS, rebalance_start, Pid, KeepNodes, EjectNodes, FailedNodes, DeltaNodes}) ->
    Config = ns_config:get(),
    [format_simple_plist_as_json([{type, rebalanceStart},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {pid, Pid}])
     ++ [{keepNodes, [node_to_host(N, Config) || N <- KeepNodes]},
         {ejectNodes, [node_to_host(N, Config) || N <- EjectNodes]},
         {failedNodes, [node_to_host(N, Config) || N <- FailedNodes]},
         {deltaNodes, [node_to_host(N, Config) || N <- DeltaNodes]}]];
event_to_jsons({TS, rebalance_end, Pid, Reason}) ->
    [format_simple_plist_as_json([{type, rebalanceEnd},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {pid, Pid},
                                  {reason, iolist_to_binary(io_lib:format("~p", [Reason]))}])];

event_to_jsons({TS, vbucket_move_start, Pid, BucketName, Node, VBucketId, OldChain, NewChain}) ->
    Config = ns_config:get(),
    [format_simple_plist_as_json([{type, vbucketMoveStart},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {pid, Pid},
                                  {bucket, BucketName},
                                  {node, Node},
                                  {vbucket, VBucketId}])
     ++ [{chainBefore, [node_to_host(N, Config) || N <- OldChain]},
         {chainAfter, [node_to_host(N, Config) || N <- NewChain]}]];

event_to_jsons({TS, vbucket_mover_terminate, BucketName, VBucketId, Pid, Reason}) ->
    [format_simple_plist_as_json([{type, vbucketMoverTerminate},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {pid, Pid},
                                  {reason, Reason},
                                  {bucket, BucketName},
                                  {vbucket, VBucketId},
                                  {node, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, vbucket_move_done, BucketName, VBucketId}) ->
    [format_simple_plist_as_json([{type, vbucketMoveDone},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {vbucket, VBucketId}])];

event_to_jsons({TS, bucket_rebalance_started, BucketName, Pid}) ->
    [format_simple_plist_as_json([{type, bucketRebalanceStarted},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {pid, Pid},
                                  {node, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, bucket_rebalance_ended, BucketName, Pid}) ->
    [format_simple_plist_as_json([{type, bucketRebalanceEnded},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {pid, Pid},
                                  {node, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, bucket_failover_started, BucketName, Node, Pid}) ->
    [format_simple_plist_as_json([{type, bucketFailoverStarted},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {host, node_to_host(Node, ns_config:latest())},
                                  {pid, Pid},
                                  {node, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, bucket_failover_ended, BucketName, Node, Pid}) ->
    [format_simple_plist_as_json([{type, bucketFailoverEnded},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {host, node_to_host(Node, ns_config:latest())},
                                  {pid, Pid},
                                  {node, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, failover, Node}) ->
    [format_simple_plist_as_json([{type, failover},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {host, node_to_host(Node, ns_config:latest())}])];

event_to_jsons({TS, became_master, Node}) ->
    [format_simple_plist_as_json([{type, becameMaster},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {node, Node},
                                  {host, node_to_host(Node, ns_config:latest())}])];
event_to_jsons({TS, became_master}) ->
    event_to_jsons({TS, became_master, 'nonode@unknown'});

event_to_jsons({TS, create_bucket, BucketName, BucketType, NewConfig}) ->
    SanitizedConfig = lists:keydelete(sasl_password, 1, NewConfig),
    [format_simple_plist_as_json([{type, createBucket},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {bucketType, BucketType}])
                                 ++ [{params, {struct, format_simple_plist_as_json(SanitizedConfig)}}]];

event_to_jsons({TS, delete_bucket, BucketName}) ->
    [format_simple_plist_as_json([{type, deleteBucket},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName}])];

event_to_jsons({TS, name_changed, NewName}) ->
    [format_simple_plist_as_json([{type, nameChanged},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {node, NewName},
                                  {host, node_to_host(NewName, ns_config:get())}])];

event_to_jsons({TS, indexing_initated, BucketName, Node, VBucket}) ->
    [format_simple_plist_as_json([{type, indexingInitiated},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {node, node_to_host(Node, ns_config:get())},
                                  {bucket, BucketName},
                                  {vbucket, VBucket}])];

event_to_jsons({TS, backfill_phase_ended, BucketName, VBucket}) ->
    [format_simple_plist_as_json([{type, backfillPhaseEnded},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {vbucket, VBucket}])];

event_to_jsons({TS, wait_index_updated_started, BucketName, Node, VBucket}) ->
    [format_simple_plist_as_json([{type, waitIndexUpdatedStarted},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {vbucket, VBucket},
                                  {node, node_to_host(Node, ns_config:latest())}])];

event_to_jsons({TS, wait_index_updated_ended, BucketName, Node, VBucket}) ->
    [format_simple_plist_as_json([{type, waitIndexUpdatedEnded},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {vbucket, VBucket},
                                  {node, node_to_host(Node, ns_config:latest())}])];

event_to_jsons({TS, compaction_inhibited, BucketName, Node}) ->
    [format_simple_plist_as_json([{type, compactionInhibited},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {node, node_to_host(Node, ns_config:latest())}])];

event_to_jsons({TS, compaction_uninhibit_started, BucketName, Node}) ->
    [format_simple_plist_as_json([{type, compactionUninhibitStarted},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {node, node_to_host(Node, ns_config:latest())}])];

event_to_jsons({TS, compaction_uninhibit_done, BucketName, Node}) ->
    [format_simple_plist_as_json([{type, compactionUninhibitDone},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {node, node_to_host(Node, ns_config:latest())}])];

event_to_jsons({TS, forced_inhibited_view_compaction, BucketName, Node}) ->
    [format_simple_plist_as_json([{type, forcedPreviouslyInhibitedViewCompaction},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {node, node_to_host(Node, ns_config:latest())}])];

event_to_jsons({TS, seqno_waiting_started, BucketName, VBucket, SeqNo, Nodes}) ->
    Config = ns_config:get(),
    [format_simple_plist_as_json([{type, seqnoWaitingStarted},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {vbucket, VBucket},
                                  {seqno, SeqNo},
                                  {node, node_to_host(N, Config)}])
     || N <- Nodes];

event_to_jsons({TS, seqno_waiting_ended, BucketName, VBucket, SeqNo, Nodes}) ->
    Config = ns_config:get(),
    [format_simple_plist_as_json([{type, seqnoWaitingEnded},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {vbucket, VBucket},
                                  {seqno, SeqNo},
                                  {node, node_to_host(N, Config)}])
     || N <- Nodes];

event_to_jsons({TS, takeover_started, BucketName, VBucket, OldMaster, NewMaster}) ->
    [format_simple_plist_as_json([{type, takeoverStarted},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {vbucket, VBucket},
                                  {oldMaster, node_to_host(OldMaster, ns_config:latest())},
                                  {node, node_to_host(NewMaster, ns_config:latest())}])];

event_to_jsons({TS, takeover_ended, BucketName, VBucket, OldMaster, NewMaster}) ->
    [format_simple_plist_as_json([{type, takeoverEnded},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, BucketName},
                                  {vbucket, VBucket},
                                  {oldMaster, node_to_host(OldMaster, ns_config:latest())},
                                  {node, node_to_host(NewMaster, ns_config:latest())}])];

event_to_jsons({TS, dcp_replicator_start,
                Bucket, ConnName, ProducerNode, ConsumerConn, ProducerConn, Pid}) ->
    [format_simple_plist_as_json([{type, dcpReplicatorStart},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, Bucket},
                                  {connectionName, ConnName},
                                  {pid, Pid},
                                  {consumerConn, ConsumerConn},
                                  {producerConn, ProducerConn},
                                  {producerNode, ProducerNode},
                                  {consumerNode, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, dcp_replicator_terminate,
                Bucket, ConnName, ProducerNode, ConsumerConn, ProducerConn, Pid,
                Reason}) ->
    [format_simple_plist_as_json([{type, dcpReplicatorTerminate},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, Bucket},
                                  {connectionName, ConnName},
                                  {pid, Pid},
                                  {consumerConn, ConsumerConn},
                                  {producerConn, ProducerConn},
                                  {reason, Reason},
                                  {producerNode, ProducerNode},
                                  {consumerNode, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, dcp_add_stream, Bucket, ConnName, VBucket, Opaque, Type, Side, Pid}) ->
    [format_simple_plist_as_json([{type, dcpAddStream},
                                  {side, Side},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, Bucket},
                                  {connectionName, ConnName},
                                  {vbucket, VBucket},
                                  {opaque, Opaque},
                                  {streamType, Type},
                                  {pid, Pid},
                                  {node, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, dcp_close_stream, Bucket, ConnName, VBucket, Opaque, Side, Pid}) ->
    [format_simple_plist_as_json([{type, dcpCloseStream},
                                  {side, Side},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, Bucket},
                                  {connectionName, ConnName},
                                  {vbucket, VBucket},
                                  {opaque, Opaque},
                                  {pid, Pid},
                                  {node, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, DcpCloseAddResponse,
                Bucket, ConnName, VBucket, Opaque, Side, Status, Success, Pid})
  when DcpCloseAddResponse =:= dcp_add_stream_response;
       DcpCloseAddResponse =:= dcp_close_stream_response ->

    Type =
        case DcpCloseAddResponse of
            dcp_add_stream_response ->
                dcpAddStreamResponse;
            dcp_close_stream_response ->
                dcpCloseStreamResponse
        end,

    HumanStatus = mc_client_binary:map_status(Status),

    [format_simple_plist_as_json([{type, Type},
                                  {side, Side},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, Bucket},
                                  {connectionName, ConnName},
                                  {vbucket, VBucket},
                                  {opaque, Opaque},
                                  {status, HumanStatus},
                                  {rawStatus, Status},
                                  {success, Success},
                                  {pid, Pid},
                                  {node, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, dcp_set_vbucket_state, Bucket, ConnName, VBucket, State, Pid}) ->
    [format_simple_plist_as_json([{type, dcpSetVbucketState},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {bucket, Bucket},
                                  {connectionName, ConnName},
                                  {vbucket, VBucket},
                                  {state, State},
                                  {pid, Pid},
                                  {node, maybe_get_pids_node(Pid)}])];

event_to_jsons({TS, set_service_map, Service, Nodes}) ->
    [[{nodes, Nodes} |
      format_simple_plist_as_json([{type, setServiceMap},
                                   {ts, misc:time_to_epoch_int(TS)},
                                   {service, Service}])]];

event_to_jsons({TS, autofailover_node_state_change, Node, PrevState,
                NewState, NewCounter}) ->
    [format_simple_plist_as_json([{type, autofailoverNodeStateChange},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {node, Node},
                                  {prevState, PrevState},
                                  {newState, NewState},
                                  {newCounter, NewCounter}])];

event_to_jsons({TS, autofailover_done, Node, Reason}) ->
    [format_simple_plist_as_json([{type, autofailoverDone},
                                  {ts, misc:time_to_epoch_float(TS)},
                                  {node, Node},
                                  {reason, Reason}])];
event_to_jsons(Event) ->
    ?log_warning("Got unknown kind of event: ~p", [Event]),
    [].
