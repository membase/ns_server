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
-define(START_VBUCKET_FILTER_CHANGE_TIMEOUT, ns_config:get_timeout_fast(ebucketmigrator_start_vbucket_filter_change, 120000)).
% Microseconds because we use timer:now_diff
-define(UPSTREAM_TIMEOUT, ns_config:get_timeout_fast(ebucketmigrator_upstream_us, 600000000)).
-define(TIMEOUT_CHECK_INTERVAL, 15000).
-define(TERMINATE_TIMEOUT, ns_config:get_timeout_fast(ebucketmigrator_terminate, 110000)).
-define(HIBERNATE_TIMEOUT, 10000).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-type vb_filter_change_state() :: not_started | started | half_completed | completed.

-record(had_backfill, {value :: boolean() | undefined,
                       backfill_opaque :: undefined | non_neg_integer(),
                       waiters = [] :: list()}).

-record(state, {upstream :: port(),
                upstream_aux :: port(),
                downstream :: port(),
                downstream_aux :: port(),
                upstream_sender :: pid(),
                upbuf = <<>> :: binary(),
                downbuf = <<>> :: binary(),
                vbuckets,
                last_sent_seqno = -1 :: integer(),
                takeover :: boolean(),
                takeover_done :: boolean(),
                takeover_msgs_seen = 0 :: non_neg_integer(),
                last_seen :: erlang:timestamp(),

                vb_filter_change_state = not_started :: vb_filter_change_state(),
                vb_filter_change_owner = undefined :: {pid(), any()} | undefined,

                tap_name :: binary(),
                pid :: pid(),          % our own pid for informational purposes

                %% from perspective of ns_server we define backfill as
                %% tap stream that is resetting (i.e. deleting and
                %% recreating) it's only vbucket. In practice when
                %% there's multiple vbuckets we'll always set it to
                %% false.
                had_backfill = #had_backfill{} :: #had_backfill{},
                backfill_end_waiter :: undefined | completed | {pid(), _},
                no_ready_vbuckets :: boolean()
               }).

%% external API
-export([start_link/1, start_link/2,
         build_args/7, add_args_option/3, get_args_option/2,
         start_vbucket_filter_change/2,
         set_controlling_process/2,
         had_backfill/2,
         wait_backfill_complete/1]).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

%%
%% gen_server callback implementation
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

queue_data(State, Element, Data) ->
    OldBuffer = erlang:element(Element, State),
    erlang:setelement(Element, State, <<OldBuffer/binary, Data/binary>>).

handle_leftover_message({tcp, Socket, Data},
                        #state{downstream=Downstream,
                               upstream=Upstream} = State) ->
    queue_data(State, case Socket of
                          Downstream ->
                              #state.downbuf;
                          Upstream ->
                              #state.upbuf
                      end, Data);
handle_leftover_message(Msg, State) ->
    handle_leftover_message_common(Msg, State).

handle_leftover_message_common({tcp_closed, Socket}, State) ->
    erlang:exit({connect_close_during_vbucket_filter_change,
                 case State#state.downstream =:= Socket of
                     true -> downstream;
                     false -> upstream
                 end});
handle_leftover_message_common({check_for_timeout, _}, State) ->
    ?log_debug("Ignoring check_for_timeout "
               "in the middle of vbucket filter change"),
    State;
handle_leftover_message_common(retry_not_ready_vbuckets, State) ->
    ?log_debug("Ignoring retry_not_ready_vbuckets "
               "in the middle of vbucket filter change"),
    State;
handle_leftover_message_common({system, _, _}, State) ->
    ?log_debug("Got erlang system message that I'll drop on the floor. "
               "I'll be dead soon anyways."),
    State;
handle_leftover_message_common({'EXIT', _Pid, Reason} = ExitMsg, _State) ->
    case Reason =:= normal orelse Reason =:= shutdown of
        true ->
            ok;
        false ->
            ?log_error("Killing myself due to exit message: ~p", [ExitMsg])
    end,
    erlang:exit(Reason);
handle_leftover_message_common(Msg, _State) ->
    ?log_error("Got unexpected message ~p", [Msg]),
    erlang:exit({unexpected_message, Msg}).

eat_leftover_messages(State) ->
    fold_messages(
      fun handle_leftover_message/2, State,
      fun () ->
              receive
                  Msg ->
                      {ok, Msg}
              after 0 ->
                      stop
              end
      end).

fold_messages(Fn, Acc, Producer) ->
    case Producer() of
        {ok, Msg} ->
            fold_messages(Fn, Fn(Msg, Acc), Producer);
        stop ->
            Acc
    end.

complete_native_vb_filter_change(#state{downstream=Downstream,
                                        upstream=Upstream,
                                        vb_filter_change_state=ChangeState,
                                        vb_filter_change_owner=Owner} = State) ->
    completed = ChangeState,
    true = Owner =/= undefined,

    inc_counter(native_vbucket_filter_changes),

    %% ok so first lets disable socket's active flags
    ok = inet:setopts(Downstream, [{active, false}]),
    ok = inet:setopts(Upstream, [{active, false}]),

    ?log_debug("Proceeding with reading unread binaries"),
    %% now we need to process pending messages
    State2 = eat_leftover_messages(State),
    State3 = confirm_downstream(State2),
    reply_and_die(State3).

complete_old_vb_filter_change(#state{downstream=Downstream,
                                     upstream=Upstream,
                                     upstream_sender=UpstreamSender} = State) ->
    inc_counter(non_native_vbucket_filter_changes),
    (catch master_activity_events:note_vbucket_filter_change_old()),

    erlang:unlink(UpstreamSender),
    exit(UpstreamSender, shutdown),
    ok = gen_tcp:close(Upstream),
    ?log_debug("Closed upstream connection"),

    ok = inet:setopts(Downstream, [{active, false}]),

    State2 = confirm_downstream(State),

    State3 = State2#state{upstream=undefined,
                          upbuf= <<>>,
                          downbuf= <<>>},
    reply_and_die(State3).

confirm_downstream(State) ->
    ?log_debug("Going to confirm reception downstream messages"),
    {ok, ConfirmTRef} = timer2:kill_after(?TERMINATE_TIMEOUT),
    {ok, NewState} = confirm_sent_messages(State),
    timer2:cancel(ConfirmTRef),
    ?log_debug("Confirmed upstream messages are feeded to kernel"),
    NewState.

reply_and_die(#state{vb_filter_change_owner=Owner} = State) ->
    true = Owner =/= undefined,
    {OwnerPid, _} = Owner,

    ok = set_controlling_process(State, OwnerPid),

    ?log_debug("Passed old state to caller"),
    gen_server:reply(Owner, {ok, State}),

    ?log_debug("Sent out state. Preparing to die"),

    erlang:hibernate(erlang, apply,
                     [fun process_last_messages/1, [State]]).

do_process_last_messages(Msg, State) ->
    case Msg of
        {tcp, _, _} ->
            State;
        _ ->
            handle_leftover_message_common(Msg, State)
    end.

process_last_messages(State) ->
    fold_messages(
      fun do_process_last_messages/2, State,
      fun () ->
              receive
                  Msg ->
                      {ok, Msg}
              after 30000 ->
                      %% we don't expect this to happen
                      ?log_error("Waited for termination signal for too long. "
                                 "Giving up."),
                      erlang:exit({error, ebucketmigrator_termination_timeout})
              end
      end).

handle_call({start_vbucket_filter_change, _}, {Pid, _} = _From,
            #state{vb_filter_change_state=VBFilterChangeState} = State)
  when VBFilterChangeState =/= not_started ->
    ?log_error("Got start_vbucket_filter_change request "
               "from ~p in state `~p`. Refusing.", [Pid, VBFilterChangeState]),
    {reply, refused, State};
handle_call({start_vbucket_filter_change, VBuckets}, From,
            #state{upstream_aux=UpstreamAux,
                   downstream_aux=DownstreamAux,
                   tap_name=TapName,
                   vbuckets=CurrentVBucketsSet} = State) ->
    VBucketsSet = sets:from_list(VBuckets),
    NewVBucketsSet = sets:subtract(VBucketsSet, CurrentVBucketsSet),
    NewVBuckets = sets:to_list(NewVBucketsSet),

    ?log_info("Starting new-style vbucket "
              "filter change on stream `~s`", [TapName]),

    State1 = State#state{vb_filter_change_state=started,
                         vb_filter_change_owner=From},

    NotReady =
        try mc_client_binary:get_zero_open_checkpoint_vbuckets(UpstreamAux,
                                                               NewVBuckets)
        catch error:{badmatch, {error, closed}} ->
                ?log_warning("Detected dead upstream connection"),
                erlang:exit(upstream_conn_is_down)
        end,

    if
        State#state.no_ready_vbuckets ->
            %% NOTE: we unregistered tap name when we discovered we
            %% can't do anything and decided to not establish tap
            %% connection. Thus new-style vbucket filter change cannot
            %% even be used.
            ?log_warning("Have no currently replicated vbuckets. TAP name is dead thus using old style vbucket filter change"),
            complete_old_vb_filter_change(State1);
        NotReady =:= [] ->
            Checkpoints =
                mc_binary:mass_get_last_closed_checkpoint(DownstreamAux,
                                                          VBuckets, 60000),

            ?log_info("Changing vbucket filter on tap stream `~s`:~n~p",
                      [TapName, Checkpoints]),
            R = mc_client_binary:change_vbucket_filter(UpstreamAux,
                                                       TapName, Checkpoints),

            case R of
                ok ->
                    (catch master_activity_events:note_vbucket_filter_change_native(
                             TapName, Checkpoints)),

                    ?log_info("Successfully changed vbucket "
                              "filter on tap stream `~s`.", [TapName]),
                    {noreply, State1};
                Other ->
                    ?log_warning("Failed to change vbucket filter on upstream: ~p. "
                                 "Falling back to old behaviour", [Other]),
                    complete_old_vb_filter_change(State1)
            end;
        true ->
            %% We don't expect this case (though it can still happen). And by
            %% the time new ebucketmigrator starts some of the vbuckets may
            %% have already become ready. It will complicate the logic there
            %% significantly so let's just use old vbucket filter change
            %% approach.
            ?log_warning("Some of new vbuckets are not ready to replicate from. "
                         "Will not use native vbucket filter change. "
                         "Not ready vbuckets:~n~p", [NotReady]),
            complete_old_vb_filter_change(State1)
    end;
handle_call(had_backfill, From, #state{had_backfill = HadBF} = State) ->
    #had_backfill{value = Value,
                  backfill_opaque = BFOpaque} = HadBF,
    case Value =/= undefined andalso BFOpaque =:= undefined of
        true ->
            {reply, Value, State, ?HIBERNATE_TIMEOUT};
        false ->
            OldWaiters = HadBF#had_backfill.waiters,
            NewBF = HadBF#had_backfill{waiters = [From | OldWaiters]},
            ?rebalance_debug("Suspended had_backfill waiter~n~p", [NewBF]),
            {noreply, State#state{had_backfill = NewBF}, ?HIBERNATE_TIMEOUT}
    end;
handle_call(wait_backfill_complete, From, #state{had_backfill = HadBF,
                                                 backfill_end_waiter = CurrentWaiter} = State) ->
    case HadBF#had_backfill.value of
        true ->
            case CurrentWaiter of
                completed ->
                    {reply, ok, State, ?HIBERNATE_TIMEOUT};
                undefined ->
                    {noreply, State#state{backfill_end_waiter = From}};
                _ ->
                    {reply, already_waiting, State}
            end;
        _ ->
            {reply, not_backfilling, State, ?HIBERNATE_TIMEOUT}
    end;
handle_call(_Req, _From, State) ->
    {reply, unhandled, State, ?HIBERNATE_TIMEOUT}.


handle_cast(Msg, State) ->
    ?rebalance_warning("Unhandled cast: ~p", [Msg]),
    {noreply, State, ?HIBERNATE_TIMEOUT}.


handle_info(retry_not_ready_vbuckets, _State) ->
    exit_retry_not_ready_vbuckets();
handle_info(upstream_silenced, State) ->
    {state_is_half_complete, half_completed} = {state_is_half_complete, State#state.vb_filter_change_state},
    ?log_info("Got reply from upstream silencing request. "
              "Completing state transition to a new ebucketmigrator."),
    complete_native_vb_filter_change(State#state{vb_filter_change_state = completed});
handle_info({tcp, Socket, Data},
            #state{downstream=Downstream,
                   upstream=Upstream} = State) ->
    %% Set up the socket to receive another message
    ok = inet:setopts(Socket, [{active, once}]),
    State1 = case Socket of
                 Downstream ->
                     case State#state.vb_filter_change_state =:= half_completed of
                         true ->
                             %% half completed state is when we cannot
                             %% send anything upstream, we're keeping
                             %% it in our buffer instead. This is
                             %% related to same deadlock that caused
                             %% us to introduce
                             %% upstream_sender. I.e. git log (with or
                             %% without 'pickaxe' option), and git
                             %% blame will tell you that story.
                             #state{downbuf = Downbuf} = State,
                             State#state{downbuf = <<Downbuf/binary, Data/binary>>};
                         _ ->
                             process_data(Data, #state.downbuf,
                                          fun process_downstream/2, State)
                     end;
                 Upstream ->
                     RV = process_data(Data, #state.upbuf,
                                       fun process_upstream/2,
                                       State#state{last_seen=now()}),

                     %% memcached normally sends us up 10 items, we
                     %% want this better than nothing network
                     %% efficiency. On the other hand Naggle's
                     %% algorithm will kill performance. So lets ask kernel
                     %% to send queued stuff even if Naggle is against.
                     ok = inet:setopts(Downstream, [{nodelay, true}]),
                     ok = inet:setopts(Downstream, [{nodelay, false}]),

                     RV
    end,

    {state_is_not_completed, true} = {state_is_not_completed, State1#state.vb_filter_change_state =/= completed},

    {noreply, State1, ?HIBERNATE_TIMEOUT};
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
handle_info({check_for_timeout, Timeout} = Msg, State) ->
    erlang:send_after(Timeout, self(), Msg),

    case timer:now_diff(now(), State#state.last_seen) > ?UPSTREAM_TIMEOUT of
        true ->
            {stop, timeout, State};
        false ->
            {noreply, State, ?HIBERNATE_TIMEOUT}
    end;
handle_info({'EXIT', _Pid, _Reason} = ExitSignal, State) ->
    ?rebalance_error("killing myself due to exit signal: ~p", [ExitSignal]),
    {stop, {got_exit, ExitSignal}, State};
handle_info(timeout, #state{had_backfill = HadBF,
                            backfill_end_waiter = CurrentWaiter,
                            upstream_sender = UpstreamSender} = State) ->
    Timeout = case HadBF#had_backfill.value of
                  true ->
                      case CurrentWaiter of
                          completed ->
                              hibernate;
                          _ ->
                              ?HIBERNATE_TIMEOUT
                      end;
                  _ ->
                      hibernate
              end,
    case Timeout of
        hibernate ->
            UpstreamSender ! hibernate;
        _ ->
            ok
    end,
    {noreply, State, Timeout};
handle_info(Msg, State) ->
    ?rebalance_warning("Unexpected handle_info(~p, ~p)", [Msg, State]),
    {noreply, State, ?HIBERNATE_TIMEOUT}.


init({Src, Dst, Opts}=InitArgs) ->
    Bucketname = proplists:get_value(username, Opts),
    {Username, Password} = case proplists:get_value(password, Opts, "") of
                               get_from_config ->
                                   ns_bucket:credentials(Bucketname);
                               P ->
                                   {Bucketname, P}
                           end,
    Bucket = proplists:get_value(bucket, Opts),
    VBuckets = proplists:get_value(vbuckets, Opts, [0]),
    TakeOver = proplists:get_bool(takeover, Opts),
    TapSuffix = proplists:get_value(suffix, Opts),

    OldState =
        case proplists:get_value(old_state_retriever, Opts) of
            undefined ->
                undefined;
            Thunk ->
                Thunk()
        end,

    case OldState of
        undefined ->
            ok;
        _ ->
            %% State may contain big binaries in {up,down}buf's. So let's not
            %% log them.
            CutState = OldState#state{upbuf= <<"cut off">>,
                                      downbuf= <<"cut off">>,
                                      vbuckets=[]},
            ?log_debug("Got old ebucketmigrator state from ~p:~n~p.",
                       [CutState#state.pid, CutState])
    end,

    TapName = case OldState of
                  undefined ->
                      tap_name(TakeOver, TapSuffix);
                  _ ->
                      OldState#state.tap_name
              end,

    proc_lib:init_ack({ok, self()}),

    {UpstreamAux, DownstreamAux} =
        case OldState of
            undefined ->
                {mc_replication:connect(Src, Username, Password, Bucket),
                 mc_replication:connect(Dst, Username, Password, Bucket)};
            _ ->
                {OldState#state.upstream_aux,
                 OldState#state.downstream_aux}
        end,

    %% Set all vbuckets to the replica state on the destination node.
    VBucketsToChangeState =
        case proplists:get_bool(set_to_pending_state, Opts) of
            true ->
                VBuckets;
            _ ->
                if
                    OldState =/= undefined orelse length(VBuckets) > 8 ->
                        {ok, AllReplicaVBuckets} =
                            mc_binary:quick_stats(
                              DownstreamAux, <<"vbucket">>,
                              fun (<<"vb_", K/binary>>, <<"replica">>, Acc) ->
                                      [list_to_integer(binary_to_list(K)) | Acc];
                                  (_, _, Acc) -> Acc
                              end, []),
                        VBuckets -- AllReplicaVBuckets;
                    true ->
                        VBuckets
                end
        end,

    VBucketStateToSet = case proplists:get_bool(set_to_pending_state, Opts) of
                            true -> pending;
                            _ -> replica
                        end,

    [begin
         ?log_info("Setting ~p vbucket ~p to state replica", [Dst, VBucket]),
         ok = mc_client_binary:set_vbucket(DownstreamAux, VBucket, VBucketStateToSet)
     end || VBucket <- VBucketsToChangeState],

    NotReadyVBuckets = mc_client_binary:get_zero_open_checkpoint_vbuckets(UpstreamAux, VBuckets),
    ReadyVBuckets = VBuckets -- NotReadyVBuckets,

    if
        NotReadyVBuckets =/= [] ->
            false = TakeOver,
            master_activity_events:note_not_ready_vbuckets(self(), NotReadyVBuckets),
            inc_counter(ebucketmigrator_not_ready_times),
            inc_counter(ebucketmigrator_not_ready_vbuckets,
                        length(NotReadyVBuckets)),
            ?rebalance_info("Some vbuckets were not yet ready to replicate from:~n~p~n",
                            [NotReadyVBuckets]),

            case proplists:get_value(on_not_ready_vbuckets, Opts) of
                undefined ->
                    erlang:send_after(30000, self(), retry_not_ready_vbuckets);
                Action ->
                    Action()
            end;
        true ->
            ok
    end,

    true = not(TakeOver andalso (ReadyVBuckets =:= [])),

    case OldState =:= undefined orelse ReadyVBuckets =:= [] of
        true ->
            ok = kill_tapname(UpstreamAux, TapName, Bucket, Src, Username);
        _ ->
            ok
    end,

    {Upstream, Args} =
        case OldState =:= undefined orelse
            OldState#state.upstream =:= undefined of
            true ->
                Upstream0 = mc_replication:connect(Src, Username, Password, Bucket),
                %% TCP_NODELAY on upstream socket seems
                %% beneficial. Only ack/nack is getting sent here.
                ok = inet:setopts(Upstream0, [{nodelay, true}]),

                case ReadyVBuckets =/= [] of
                    true ->
                        %% if there's no old state or upstream is
                        %% undefined in it then we promote we'll just
                        %% create a new upstream connection
                        Checkpoints =
                            mc_binary:mass_get_last_closed_checkpoint(DownstreamAux,
                                                                      ReadyVBuckets, 60000),

                        Args0 = [{vbuckets, ReadyVBuckets},
                                 {checkpoints, Checkpoints},
                                 {name, TapName},
                                 {takeover, TakeOver}],

                        ?rebalance_info("Starting tap stream:~n~p~n~p",
                                        [Args0, InitArgs]),
                        {ok, quiet} = mc_client_binary:tap_connect(Upstream0, Args0),
                        {Upstream0, Args0};
                    false ->
                        ?rebalance_info("Doing nothing due to no vbuckets ready"),
                        {Upstream0, [{fake, true}]}
                end;
            false ->
                Args0 = [{vbuckets, ReadyVBuckets},
                         {name, TapName},
                         {takeover, TakeOver}],

                %% just use old upstream
                (catch
                     master_activity_events:note_ebucketmigrator_upstream_reused(
                       self(), OldState#state.pid, TapName)),

                ?log_debug("Reusing old upstream:~n~p", [Args0]),
                {OldState#state.upstream, Args0}
        end,

    Downstream =
        case OldState of
            undefined ->
                mc_replication:connect(Dst, Username, Password, Bucket);
            _ ->
                OldState#state.downstream
        end,

    ok = inet:setopts(Upstream, [{active, once}]),
    ok = inet:setopts(Downstream, [{active, once}]),

    Timeout = proplists:get_value(timeout, Opts, ?TIMEOUT_CHECK_INTERVAL),
    erlang:send_after(Timeout, self(), {check_for_timeout, Timeout}),

    UpstreamSender = spawn_link(erlang, apply, [fun upstream_sender_loop/1, [Upstream]]),
    ?rebalance_debug("upstream_sender pid: ~p", [UpstreamSender]),

    {UpstreamBuffer, DownstreamBuffer} =
        case OldState of
            undefined ->
                {<<>>, <<>>};
            _ ->
                {OldState#state.upbuf,
                 OldState#state.downbuf}
        end,

    State = #state{
      upstream=Upstream,
      upstream_aux=UpstreamAux,
      downstream=Downstream,
      downstream_aux=DownstreamAux,
      upstream_sender=UpstreamSender,
      vbuckets=sets:from_list(ReadyVBuckets),
      last_seen=now(),
      takeover=TakeOver,
      takeover_done=false,
      upbuf=UpstreamBuffer,
      downbuf=DownstreamBuffer,
      tap_name=TapName,
      pid=self(),
      had_backfill = case VBuckets of
                         [_] ->
                             #had_backfill{};
                         [_,_|_] ->
                             #had_backfill{value = false}
                     end,
      no_ready_vbuckets = (ReadyVBuckets =:= [])
     },

    State1 = process_data(<<>>, #state.downbuf, fun process_downstream/2, State),
    State2 = process_data(<<>>, #state.upbuf, fun process_upstream/2, State1),

    erlang:process_flag(trap_exit, true),
    (catch master_activity_events:note_ebucketmigrator_start(self(), Src, Dst, [{bucket, Bucket},
                                                                                {username, Username}
                                                                                | Args])),

    case proplists:get_value(note_tap_stats, Opts) of
        undefined ->
            ok;
        NoteTapTag ->
            do_note_tap_stats(State, NoteTapTag)
    end,

    gen_server:enter_loop(?MODULE, [], State2, ?HIBERNATE_TIMEOUT).

-define(TAP_STATS_ATTEMPTS, 5).
do_note_tap_stats(State, NoteTapTag) ->
    ?rebalance_debug("Handling note_tap_stats"),
    do_note_tap_stats(State, NoteTapTag, ?TAP_STATS_ATTEMPTS).

do_note_tap_stats(_State, _NoteTapTag, 0) ->
    ?rebalance_warning("Failed to get tap stats after ~p attempts", [?TAP_STATS_ATTEMPTS]);
do_note_tap_stats(#state{upstream_aux = Aux,
                         vbuckets = VBs,
                         tap_name = TapName} = State,
                  NoteTapTag, Tries) ->
    VB = hd(sets:to_list(VBs)),
    case (catch mc_client_binary:get_tap_docs_estimate(Aux, VB, TapName)) of
        {ok, {Estimate, _, Status}} ->
            case Status =:= <<"backfilling">> orelse
                Status =:= <<"backfill completed">> of
                true ->
                    %% ok, tap stream exists
                    (catch master_activity_events:note_tap_stats(NoteTapTag, Estimate, self(), TapName));
                false ->
                    %% tap stream does not exist yet; let's try to wait for a bit
                    timer:sleep(10),
                    ?rebalance_debug("Tap stream still didn't exist. Will try to again in a moment"),
                    do_note_tap_stats(State, NoteTapTag, Tries-1)
            end;
        Error ->
            ?rebalance_warning("Failed to get tap docs estimate: ~p~n~p", [Error, erlang:get_stacktrace()])
    end.

upstream_sender_loop(Upstream) ->
    receive
        hibernate ->
            erlang:hibernate(erlang, apply, [fun upstream_sender_loop/1, [Upstream]]);
        {silence_upstream_new_style, Pid} ->
            Pid ! upstream_silenced,
            erlang:hibernate(erlang, exit, [silenced]);
        Data ->
            ok = gen_tcp:send(Upstream, Data)
    end,
    upstream_sender_loop(Upstream).

exit_retry_not_ready_vbuckets() ->
    ?rebalance_info("dying to check if some previously not yet ready vbuckets are ready to replicate from"),
    exit(normal).

terminate(Reason, #state{upstream_sender=UpstreamSender} = State) ->
    ?rebalance_debug("Dying with reason: ~p", [Reason]),
    timer2:kill_after(?TERMINATE_TIMEOUT),
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
    case prim_inet:recv(Sock, ?HEADER_LEN) of
        {ok, <<_Magic:8, _Opcode:8, _KeyLen:16, _ExtLen:8, _DataType: 8,
               _VBucket:16, BodyLen:32, _Opaque:32, _CAS:64>> = Packet} ->
            case BodyLen of
                0 ->
                    {ok, Packet};
                _ ->
                    case prim_inet:recv(Sock, BodyLen) of
                        {ok, Extra} ->
                            {ok, <<Packet/binary, Extra/binary>>};
                        X1 ->
                            X1
                    end
            end;
        X2 ->
            X2
    end.

do_confirm_sent_messages(Sock, Seqno, State) ->
    case read_tap_message(Sock) of
        {ok, Packet} ->
            <<_Magic:8, _Opcode:8, _KeyLen:16, _ExtLen:8, _DataType: 8,
              _VBucket:16, _BodyLen:32, Opaque:32, _CAS:64, _Rest/binary>> = Packet,
            case Opaque of
                Seqno ->
                    ?rebalance_info("Got close ack!~n", []),
                    {ok, State};
                _ ->
                    NewState = queue_data(State, #state.downbuf, Packet),
                    do_confirm_sent_messages(Sock, Seqno, NewState)
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
    Parent = self(),
    proc_lib:spawn_link(
      fun () ->
              ?log_debug("Sending opaque message to confirm downstream reception"),
              case gen_tcp:send(Sock, Msg) of
                  {error, Error} ->
                      ?log_info("Failed to send opaque message. Socket closed with error: ~p", [Error]);
                  ok ->
                      ?log_debug("Opaque message was succesfully sent")
              end,
              erlang:unlink(Parent)
      end),
    ?log_debug("Going to wait for reception of opaque message ack"),
    do_confirm_sent_messages(Sock, Seqno, State).

%%
%% API
%%

start_link(Args) ->
    start_link(node(), Args).

%% Starts ebucketmigrator on the `Node'.
start_link(Node, Args) ->
    misc:start_link(Node, ?MODULE, init, [Args]).

-spec build_args(ForNode::node(),
                 Bucket::bucket_name(),
                 SrcNode::node(),
                 DstNode::node(),
                 VBuckets::[vbucket_id(),...],
                 TakeOver::boolean(),
                 SetPendingState::boolean()) ->
                        {{nonempty_string(), pos_integer() | undefined},
                         {nonempty_string(), pos_integer() | undefined},
                         [any(),...]}.
build_args(ForNode, Bucket, SrcNode, DstNode, VBuckets, TakeOver, SetPendingState) ->
    {User, Pass} = get_bucket_credentials(ForNode, Bucket),
    Suffix = case TakeOver of
                 true ->
                     [VBucket] = VBuckets,
                     integer_to_list(VBucket);
                 false ->
                     %% We want to reuse names for replication.
                     atom_to_list(DstNode)
             end,
    {ns_memcached:host_port(SrcNode), ns_memcached:host_port(DstNode),
     [{username, User},
      {password, Pass},
      {vbuckets, VBuckets},
      {set_to_pending_state, SetPendingState},
      {takeover, TakeOver},
      {suffix, Suffix}]}.

add_args_option({Src, Dst, Options}, OptionName, OptionValue) ->
    NewOptions = [{OptionName, OptionValue} | lists:keydelete(OptionName, 1, Options)],
    {Src, Dst, NewOptions}.

get_args_option({_Src, _Dst, Options}, OptionName) ->
    proplists:get_value(OptionName, Options).

get_bucket_credentials(Node, Bucket) ->
    case cluster_compat_mode:is_node_compatible(Node, [2, 2, 0]) of
        false ->
            ns_bucket:credentials(Bucket);
        true ->
            {Bucket, get_from_config}
    end.

-spec start_vbucket_filter_change(pid(), [{node(), node(), list()}]) ->
                                         {ok, port()} | {failed, any()}.
start_vbucket_filter_change(Pid, Args) ->
    gen_server:call(Pid, {start_vbucket_filter_change, Args}, ?START_VBUCKET_FILTER_CHANGE_TIMEOUT).

-spec set_controlling_process(#state{}, pid()) -> ok.
set_controlling_process(#state{upstream=Upstream,
                               upstream_aux=UpstreamAux,
                               downstream=Downstream,
                               downstream_aux=DownstreamAux} = _State, Pid) ->
    lists:foreach(
      fun (undefined) ->
              ok;
          (Conn) ->
              gen_tcp:controlling_process(Conn, Pid)
      end, [Upstream, UpstreamAux, Downstream, DownstreamAux]).

%% returns true iff this migrator is for single vbucket and had
%% completely reset/overwritten it's destination. It'll block until
%% ebucketmigrator knows whether backfill happened or not, but we
%% don't expect this to block for long as tap producer will likely
%% send either indication of backfill (initial stream opaque message)
%% or or indication of no backfill (checkpoint start message) pretty
%% much immediately.
had_backfill(Pid, Timeout) ->
    gen_server:call(Pid, had_backfill, Timeout).

wait_backfill_complete(Pid) ->
    gen_server:call(Pid, wait_backfill_complete, infinity).

%%
%% Internal functions
%%

%% @doc Append Data to the appropriate buffer, calling the given
%% callback for each packet.
-spec process_data(binary(), non_neg_integer(),
                   fun((binary(), #state{}) -> #state{}), #state{}) -> #state{}.
process_data(Data, Elem, CB, State) ->
    mc_replication:process_data(Data, Elem,
                                fun (<<_Magic:8, ?NOOP:8, _Rest/binary>>, StateCB) ->
                                        %% These aren't normal TAP packets; eating them here
                                        %% makes everything else easier.
                                        {ok, StateCB};
                                    (Packet, StateCB) ->
                                        CB(Packet, StateCB)
                                end, State).

%% @doc Process a packet from the downstream server.
-spec process_downstream(<<_:8,_:_*8>>, #state{}) ->
                                {ok, #state{}}.
process_downstream(<<?RES_MAGIC:8, _Opcode:8, _KeyLen:16, _ExtLen:8, _DataType:8,
                     _VBucket:16, _BodyLen:32, Opaque:32, _CAS:64, _Rest/binary>> = Packet,
                   State) ->
    State#state.upstream_sender ! Packet,
    #had_backfill{value = BFValue,
                  waiters = Waiters,
                  backfill_opaque = BFOpaque} = HadBF = State#state.had_backfill,
    case BFOpaque =:= Opaque of
        true ->
            [gen_server:reply(From, BFValue)
             || From <- Waiters],
            case Waiters of
                [] -> ok;
                _ ->
                    ?rebalance_debug("Replied had_backfill: ~p to ~p", [BFValue, Waiters])
            end,
            NewBF = HadBF#had_backfill{waiters = [],
                                       backfill_opaque = undefined},
            {ok, State#state{had_backfill = NewBF}};
        false ->
            {ok, State}
    end.

mark_takeover_seen(State) ->
    true = State#state.takeover,
    0 = State#state.takeover_msgs_seen,
    State#state{takeover_msgs_seen = 1}.

mark_backfillness(#state{had_backfill = HadBF} = State,
                  Value) when is_boolean(Value) ->
    NewBF = HadBF#had_backfill{value = Value,
                               backfill_opaque = State#state.last_sent_seqno},
    State#state{had_backfill = NewBF}.

%% @doc Process a packet from the upstream server.
-spec process_upstream(<<_:64,_:_*8>>, #state{}) ->
                              {ok | stop, #state{}}.
process_upstream(<<?REQ_MAGIC:8, Opcode:8, _KeyLen:16, _ExtLen:8, _DataType:8,
                   VBucket:16, _BodyLen:32, Opaque:32, _CAS:64, _EnginePriv:16,
                   _Flags:16, _TTL:8, _Res1:8, _Res2:8, _Res3:8, Rest/binary>> =
                     Packet,
                 #state{downstream=Downstream,
                        vb_filter_change_state = VBFilterChangeState} = State0) ->
    ok = prim_inet:send(Downstream, Packet),
    State2 = State0#state{last_sent_seqno = Opaque},
    case Opcode of
        ?TAP_OPAQUE ->
            case Rest of
                <<?TAP_OPAQUE_INITIAL_VBUCKET_STREAM:32>> ->
                    (catch system_stats_collector:increment_counter(ebucketmigrator_backfill_starts, 1)),
                    ?rebalance_info("Initial stream for vbucket ~p", [VBucket]),
                    case State2#state.had_backfill#had_backfill.value =:= undefined of
                        true ->
                            {ok, mark_backfillness(State2, true)};
                        false ->
                            {ok, State2}
                    end;
                <<?TAP_OPAQUE_VB_FILTER_CHANGE_COMPLETE:32>> ->
                    started = VBFilterChangeState,
                    NewState = State2#state{vb_filter_change_state=half_completed},
                    ?log_info("Got vbucket filter change completion message. Silencing upstream sender"),
                    NewState#state.upstream_sender ! {silence_upstream_new_style, self()},
                    {stop, NewState};
                <<?TAP_OPAQUE_CLOSE_BACKFILL:32>> ->
                    ?log_debug("seen backfill-close message"),
                    case State2#state.backfill_end_waiter of
                        undefined ->
                            ok;
                        completed ->
                            ok;
                        WaiterPid ->
                            gen_server:reply(WaiterPid, ok)
                    end,
                    {ok, State2#state{backfill_end_waiter = completed}};
                _Other ->
                    {ok, State2}
            end;
        ?TAP_CHECKPOINT_START ->
            %% start of checkpoint if evidence of no backfill
            NewState = case State2#state.had_backfill#had_backfill.value =:= undefined of
                           true ->
                               (catch system_stats_collector:increment_counter(ebucketmigrator_nobackfill_single_vbucket_starts, 1)),
                               ?rebalance_info("TAP stream is not doing backfill"),
                               mark_backfillness(State2, false);
                           false ->
                               State2
                       end,
            case NewState#state.backfill_end_waiter of
                undefined ->
                    ok;
                completed ->
                    ok;
                WaiterPid ->
                    gen_server:reply(WaiterPid, ok)
            end,
            {ok, NewState#state{backfill_end_waiter = completed}};
        ?TAP_VBUCKET ->
            case Rest of
                <<?VB_STATE_ACTIVE:32>> ->
                    {ok, mark_takeover_seen(State2)};
                <<_:32>> -> % Make sure it's still a 32 bit value
                    {ok, State2}
            end;
        _ ->
            {ok, State2}
    end.

inc_counter(Counter) ->
    inc_counter(Counter, 1).

inc_counter(Counter, V) ->
    catch system_stats_collector:increment_counter(Counter, V).

-spec tap_name(boolean(), string()) -> binary().
tap_name(TakeOver, Suffix) ->
    case TakeOver of
        true ->
            iolist_to_binary(["rebalance_", Suffix]);
        _ ->
            iolist_to_binary(["replication_", Suffix])
    end.

kill_tapname(Sock, TapName, Bucket, Src, Username) ->
    ?log_debug("killing tap named: ~s", [TapName]),

    Bucket1 =
        case Bucket of
            undefined -> Username;
            _ -> Bucket
        end,

    (catch master_activity_events:note_deregister_tap_name(Bucket1, Src, TapName)),
    ok = mc_client_binary:deregister_tap_client(Sock, TapName),

    ok.
