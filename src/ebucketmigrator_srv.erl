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
-module(ebucketmigrator_srv).

-behaviour(gen_server).

-include("ns_common.hrl").

-define(SERVER, ?MODULE).
-define(CONNECT_TIMEOUT, ns_config_ets_dup:get_timeout(ebucketmigrator_connect, 30000)).
% Microseconds because we use timer:now_diff
-define(UPSTREAM_TIMEOUT, ns_config_ets_dup:get_timeout(ebucketmigrator_upstream_us, 600000000)).
-define(TIMEOUT_CHECK_INTERVAL, 15000).
-define(TERMINATE_TIMEOUT, ns_config_ets_dup:get_timeout(ebucketmigrator_terminate, 30000)).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {bad_vbucket_count = 0 :: non_neg_integer(),
                upstream :: port(),
                downstream :: port(),
                upstream_sender :: pid(),
                upbuf = <<>> :: binary(),
                downbuf = <<>> :: binary(),
                vbuckets,
                last_sent_seqno = -1 :: integer(),
                takeover :: boolean(),
                takeover_done :: boolean(),
                takeover_msgs_seen = 0 :: non_neg_integer(),
                args,
                last_seen
               }).

%% external API
-export([start_link/3, start_link/4, start_vbucket_filter_change/1]).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

%%
%% gen_server callback implementation
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

continue_start_vbucket_filter_change({Pid, _} = From, State, NewDownstream) ->
    MRef = erlang:monitor(process, Pid),
    case confirm_sent_messages(State) of
        ok ->
            gen_tcp:close(State#state.downstream),
            gen_tcp:controlling_process(NewDownstream, Pid),
            gen_server:reply(From, {ok, NewDownstream}),
            started_vbucket_filter_loop(State, MRef);
        _ ->
            gen_tcp:close(NewDownstream),
            {stop, old_downstream_failed, old_downstream_failed, State}
    end.

started_vbucket_filter_loop(State, MRef) ->
    master_activity_events:note_vbucket_filter_change_started(),
    Reason = receive
                 {'EXIT', _From, Reason0} = ExitMsg ->
                     ?log_debug("Got exit signal in vbucket filter changing loop:~p", [ExitMsg]),
                     Reason0;
                 {'DOWN', MRef, _, _, Reason0} = DownMsg ->
                     ?log_error("Got DOWN from vbucket filter change txn owner:~p", [DownMsg]),
                     {vbucket_txn_abort, Reason0}
             end,
    {stop, Reason, State}.


handle_call(start_vbucket_filter_change, From, #state{args={_, Dst, Opts}} = State) ->
    Username = proplists:get_value(username, Opts),
    Password = proplists:get_value(password, Opts, ""),
    Bucket = proplists:get_value(bucket, Opts),
    try connect(Dst, Username, Password, Bucket) of
        NewDownstream ->
            continue_start_vbucket_filter_change(From, State, NewDownstream)
    catch T:E ->
            Stack = erlang:get_stacktrace(),
            Tuple = {T, E, Stack},
            ?log_info("Failed to establish new downstream connection:~n~p", [Tuple]),
            {reply, {failed, Tuple}, State}
    end;

handle_call(_Req, _From, State) ->
    {reply, unhandled, State}.


handle_cast(Msg, State) ->
    ?rebalance_warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


handle_info(retry_not_ready_vbuckets, _State) ->
    exit_retry_not_ready_vbuckets();
handle_info({tcp, Socket, Data}, #state{downstream=Downstream,
                                        upstream=Upstream} = State) ->
    %% Set up the socket to receive another message
    ok = inet:setopts(Socket, [{active, once}]),
    State1 = case Socket of
                 Downstream ->
                     process_data(Data, #state.downbuf,
                                  fun process_downstream/2, State);
                 Upstream ->
                     process_data(Data, #state.upbuf,
                                  fun process_upstream/2,
                                  State#state{last_seen=now()})
    end,
    {noreply, State1};
handle_info({tcp_closed, Socket}, #state{upstream=Socket} = State) ->
    case State#state.takeover of
        true ->
            N = sets:size(State#state.vbuckets),
            case State#state.takeover_msgs_seen of
                N ->
                    {stop, normal, State#state{takeover_done = true}};
                Msgs ->
                    {stop, {wrong_number_takeovers, Msgs, N}, State}
            end;
        false ->
            {stop, normal, State}
    end;
handle_info({tcp_closed, Socket}, #state{downstream=Socket} = State) ->
    {stop, downstream_closed, State};
handle_info(check_for_timeout, State) ->
    case timer:now_diff(now(), State#state.last_seen) > ?UPSTREAM_TIMEOUT of
        true ->
            {stop, timeout, State};
        false ->
            {noreply, State}
    end;
handle_info({'EXIT', Pid, Reason}, #state{upstream_sender = SenderPid} = State) when Pid =:= SenderPid ->
    ?rebalance_error("killing myself due to unexpected upstream sender exit with reason: ~p",
                     [Reason]),
    {stop, {unexpected_upstream_sender_exit, Reason}, State};
handle_info(Msg, State) ->
    ?rebalance_warning("Unexpected handle_info(~p, ~p)", [Msg, State]),
    {noreply, State}.


init({Src, Dst, Opts}=InitArgs) ->
    Username = proplists:get_value(username, Opts),
    Password = proplists:get_value(password, Opts, ""),
    Bucket = proplists:get_value(bucket, Opts),
    VBuckets = proplists:get_value(vbuckets, Opts, [0]),
    TakeOver = proplists:get_bool(takeover, Opts),
    TapSuffix = proplists:get_value(suffix, Opts),
    Name = case TakeOver of
               true -> "rebalance_" ++ TapSuffix;
               _ -> "replication_" ++ TapSuffix
           end,
    PassedDownstream = case proplists:get_value(passed_downstream_retriever, Opts) of
                           undefined ->
                               undefined;
                           DownstreamThunk ->
                               DownstreamThunk()
                       end,
    proc_lib:init_ack({ok, self()}),
    Downstream = case PassedDownstream of
                     undefined -> connect(Dst, Username, Password, Bucket);
                     _ -> PassedDownstream
                 end,
    %% Set all vbuckets to the replica state on the destination node.
    lists:foreach(
      fun (VBucket) ->
              ?log_info("Setting ~p vbucket ~p to state replica", [Dst, VBucket]),
              ok = mc_client_binary:set_vbucket(Downstream, VBucket, replica)
      end, VBuckets),
    Upstream = connect(Src, Username, Password, Bucket),
    {ok, CheckpointIdsDict} = mc_client_binary:get_open_checkpoint_ids(Upstream),
    ?rebalance_debug("CheckpointIdsDict:~n~p~n", [CheckpointIdsDict]),
    ReadyVBuckets = lists:filter(
                      fun (Vb) ->
                              case dict:find(Vb, CheckpointIdsDict) of
                                  {ok, X} when is_integer(X) andalso X > 0 -> true;
                                  _ -> false
                              end
                      end, VBuckets),
    if
        ReadyVBuckets =/= VBuckets ->
            false = TakeOver,
            NotReadyVBuckets = VBuckets -- ReadyVBuckets,
            master_activity_events:note_not_ready_vbuckets(self(), NotReadyVBuckets),
            (catch system_stats_collector:increment_counter(ebucketmigrator_not_ready_times, 1)),
            (catch system_stats_collector:increment_counter(ebucketmigrator_not_ready_vbuckets, length(NotReadyVBuckets))),
            ?rebalance_info("Some vbuckets were not yet ready to replicate from:~n~p~n",
                            [NotReadyVBuckets]),
            erlang:send_after(30000, self(), retry_not_ready_vbuckets);
        true ->
            ok
    end,
    case PassedDownstream =:= undefined of
        true ->
            ?log_debug("killing tap named: ~s", [Name]),
            (catch master_activity_events:note_deregister_tap_name(case Bucket of
                                                                       undefined -> Username;
                                                                       _ -> Bucket
                                                                   end, Src, Name)),
            ok = mc_client_binary:deregister_tap_client(Upstream, iolist_to_binary(Name));
        false ->
            ok
    end,
    Args = if
               ReadyVBuckets =:= [] ->
                   false = TakeOver,
                   %% don't send tap_connect if no buckets were ready
                   %% but still enter gen_server loop as normal
                   [{vbuckets, []},
                    {checkpoints, []},
                    {name, Name},
                    {takeover, false}];
               true ->
                   Checkpoints = lists:map(fun ({V, {ok, C}}) -> {V, C};
                                               ({V, _})       -> {V, 0}
                                           end,
                                           [{Vb, mc_client_binary:get_last_closed_checkpoint(Downstream, Vb)} || Vb <- ReadyVBuckets]),
                   Args0 = [{vbuckets, ReadyVBuckets},
                            {checkpoints, Checkpoints},
                            {name, Name},
                            {takeover, TakeOver}],
                   ?rebalance_info("Starting tap stream:~n~p~n~p", [Args0, InitArgs]),
                   {ok, quiet} = mc_client_binary:tap_connect(Upstream, Args0),
                   Args0
           end,
    ok = inet:setopts(Upstream, [{active, once}]),
    ok = inet:setopts(Downstream, [{active, once}]),

    Timeout = proplists:get_value(timeout, Opts, ?TIMEOUT_CHECK_INTERVAL),
    {ok, _TRef} = timer:send_interval(Timeout, check_for_timeout),

    UpstreamSender = spawn_link(erlang, apply, [fun upstream_sender_loop/1, [Upstream]]),
    ?rebalance_debug("upstream_sender pid: ~p", [UpstreamSender]),

    State = #state{
      upstream=Upstream,
      downstream=Downstream,
      upstream_sender = UpstreamSender,
      vbuckets=sets:from_list(ReadyVBuckets),
      last_seen=now(),
      takeover=TakeOver,
      takeover_done=false,
      args=InitArgs
     },
    erlang:process_flag(trap_exit, true),
    (catch master_activity_events:note_ebucketmigrator_start(self(), Src, Dst, [{bucket, Bucket},
                                                                                {username, Username}
                                                                                | Args])),
    gen_server:enter_loop(?MODULE, [], State).


upstream_sender_loop(Upstream) ->
    receive
        Data ->
            ok = gen_tcp:send(Upstream, Data)
    end,
    upstream_sender_loop(Upstream).

exit_retry_not_ready_vbuckets() ->
    ?rebalance_info("dying to check if some previously not yet ready vbuckets are ready to replicate from"),
    exit(normal).

terminate(_Reason, #state{upstream_sender=UpstreamSender} = State) ->
    timer:kill_after(?TERMINATE_TIMEOUT),
    gen_tcp:close(State#state.upstream),
    exit(UpstreamSender, kill),
    case State#state.takeover_done of
        true ->
            ?rebalance_info("Skipping close ack for successfull takover~n", []),
            ok;
        _ ->
            confirm_sent_messages(State)
    end.

read_tap_message(Sock) ->
    case gen_tcp:recv(Sock, ?HEADER_LEN) of
        {ok, <<_Magic:8, _Opcode:8, _KeyLen:16, _ExtLen:8, _DataType: 8,
               _VBucket:16, BodyLen:32, _Opaque:32, _CAS:64>> = Packet} ->
            case BodyLen of
                0 ->
                    {ok, Packet};
                _ ->
                    case gen_tcp:recv(Sock, BodyLen) of
                        {ok, Extra} ->
                            {ok, <<Packet/binary, Extra/binary>>};
                        X1 ->
                            X1
                    end
            end;
        X2 ->
            X2
    end.

do_confirm_sent_messages(Sock, Seqno) ->
    case read_tap_message(Sock) of
        {ok, Packet} ->
            <<_Magic:8, _Opcode:8, _KeyLen:16, _ExtLen:8, _DataType: 8,
              _VBucket:16, _BodyLen:32, Opaque:32, _CAS:64, _Rest/binary>> = Packet,
            case Opaque of
                Seqno ->
                    ?rebalance_info("Got close ack!~n", []),
                    ok;
                _ ->
                    do_confirm_sent_messages(Sock, Seqno)
            end;
        {error, _} = Crap ->
            ?rebalance_warning("Got error while trying to read close ack:~p~n",
                               [Crap]),
            Crap
    end.

confirm_sent_messages(State) ->
    Seqno = State#state.last_sent_seqno + 1,
    Sock = State#state.downstream,
    inet:setopts(Sock, [{active, false}, {nodelay, true}]),
    Msg = mc_binary:encode(req, #mc_header{opcode = ?TAP_OPAQUE, opaque = Seqno},
                           #mc_entry{data = <<4:16, ?TAP_FLAG_ACK:16, 1:8, 0:8, 0:8, 0:8, ?TAP_OPAQUE_CLOSE_TAP_STREAM:32>>}),
    case gen_tcp:send(Sock, Msg) of
        ok ->
            do_confirm_sent_messages(Sock, Seqno);
        X ->
            case X =/= {error, closed} of
                true ->
                    ?rebalance_error("Got error while trying to send close confirmation: ~p~n", [X]);
                false ->
                    ok
            end,
            X
    end.

%%
%% API
%%

start_link(Src, Dst, Opts) ->
    start_link(node(), Src, Dst, Opts).

%% Starts ebucketmigrator on the `Node'.
start_link(Node, Src, Dst, Opts) ->
    misc:start_link(Node, ?MODULE, init, [{Src, Dst, Opts}]).


-spec start_vbucket_filter_change(pid()) -> {ok, port()} | {failed, any()}.
start_vbucket_filter_change(Pid) ->
    gen_server:call(Pid, start_vbucket_filter_change, 30000).


%%
%% Internal functions
%%

connect({Host, Port}, Username, Password, Bucket) ->
    {ok, Sock} = gen_tcp:connect(Host, Port,
                                 [binary, {packet, raw}, {active, false},
                                  {keepalive, true},
                                  {recbuf, 10*1024*1024},
                                  {sndbuf, 10*1024*1024}],
                                 ?CONNECT_TIMEOUT),
    case Username of
        undefined ->
            ok;
        _ ->
            ok = mc_client_binary:auth(Sock, {<<"PLAIN">>,
                                              {list_to_binary(Username),
                                               list_to_binary(Password)}})
    end,
    case Bucket of
        undefined ->
            ok;
        _ ->
            ok = mc_client_binary:select_bucket(Sock, Bucket)
    end,
    Sock.


%% @doc Chop up a buffer into packets, calling the callback with each packet.
-spec process_data(binary(), fun((binary(), #state{}) -> {binary(), #state{}}),
                                #state{}) -> {binary(), #state{}}.
process_data(<<_Magic:8, Opcode:8, _KeyLen:16, _ExtLen:8, _DataType:8,
               _VBucket:16, BodyLen:32, _Opaque:32, _CAS:64, _Rest/binary>>
                 = Buffer, CB, State)
  when byte_size(Buffer) >= BodyLen + ?HEADER_LEN ->
    %% We have a complete command
    {Packet, NewBuffer} = split_binary(Buffer, BodyLen + ?HEADER_LEN),
    State1 =
        case Opcode of
            ?NOOP ->
                %% These aren't normal TAP packets; eating them here
                %% makes everything else easier.
                State;
            _ ->
                CB(Packet, State)
        end,
    process_data(NewBuffer, CB, State1);
process_data(Buffer, _CB, State) ->
    %% Incomplete
    {Buffer, State}.


%% @doc Append Data to the appropriate buffer, calling the given
%% callback for each packet.
-spec process_data(binary(), non_neg_integer(),
                   fun((binary(), #state{}) -> #state{}), #state{}) -> #state{}.
process_data(Data, Elem, CB, State) ->
    Buffer = element(Elem, State),
    {NewBuf, NewState} = process_data(<<Buffer/binary, Data/binary>>, CB, State),
    setelement(Elem, NewState, NewBuf).


%% @doc Process a packet from the downstream server.
-spec process_downstream(<<_:8,_:_*8>>, #state{}) ->
                                #state{}.
process_downstream(<<?RES_MAGIC:8, _/binary>> = Packet,
                   State) ->
    State#state.upstream_sender ! Packet,
    State.


%% @doc Process a packet from the upstream server.
-spec process_upstream(<<_:64,_:_*8>>, #state{}) ->
                              #state{}.
process_upstream(<<?REQ_MAGIC:8, Opcode:8, _KeyLen:16, _ExtLen:8, _DataType:8,
                   VBucket:16, _BodyLen:32, Opaque:32, _CAS:64, _EnginePriv:16,
                   _Flags:16, _TTL:8, _Res1:8, _Res2:8, _Res3:8, Rest/binary>> =
                     Packet,
                 #state{downstream=Downstream, vbuckets=VBuckets} = State) ->
    case Opcode of
        ?TAP_OPAQUE ->
            ok = gen_tcp:send(Downstream, Packet),
            case Rest of
                <<?TAP_OPAQUE_INITIAL_VBUCKET_STREAM:32>> ->
                    (catch system_stats_collector:increment_counter(ebucketmigrator_backfill_starts, 1)),
                    ?rebalance_info("Initial stream for vbucket ~p",
                                    [VBucket]);
                _ ->
                    ok
            end,
            State;
        _ ->
            State1 =
                case Opcode of
                    ?TAP_VBUCKET ->
                        case Rest of
                            <<?VB_STATE_ACTIVE:32>> ->
                                true = State#state.takeover,
                                %% VBucket has been transferred, count it
                                State#state{takeover_msgs_seen =
                                                State#state.takeover_msgs_seen
                                            + 1};
                            <<_:32>> -> % Make sure it's still a 32 bit value
                                State
                        end;
                    _ ->
                        State
                end,
            case sets:is_element(VBucket, VBuckets) of
                true ->
                    ok = gen_tcp:send(Downstream, Packet),
                    State1#state{last_sent_seqno = Opaque};
                false ->
                    %% Filter it out and count it
                    State1#state{bad_vbucket_count =
                                     State1#state.bad_vbucket_count + 1}
            end
    end.
