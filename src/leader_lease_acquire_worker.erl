%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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
-module(leader_lease_acquire_worker).

-include("cut.hrl").
-include("ns_common.hrl").

-export([spawn_monitor/2]).

-define(LEASE_TIME, get_param(lease_time, 15000)).
-define(LEASE_GRACE_TIME, get_param(lease_grace_time, 5000)).

-record(state, { parent :: pid(),
                 target :: node(),
                 uuid   :: binary(),

                 rto           :: rto:rto(),
                 retry_backoff :: backoff:backoff(),

                 have_lease    :: boolean(),
                 acquire_timer :: misc:timer(acquire),
                 revoke_timer  :: misc:timer(revoke) }).

spawn_monitor(TargetNode, UUID) ->
    Parent = self(),
    async:perform(?cut(init(Parent, TargetNode, UUID))).

init(Parent, TargetNode, UUID) ->
    process_flag(priority, high),

    Rto = rto:new([{window,         get_param(window, 600 * 1000)},
                   {backoff,        get_param(backoff, 2)},
                   {min_timeout,    get_param(min_timeout, 2000)},
                   {max_timeout,    get_param(max_timeout, ?LEASE_TIME)},
                   {var_multiplier, get_param(var_multiplier, 4)}]),

    RetryBackoff =
        backoff:new([{initial,    get_param(retry_initial, 500)},
                     {threshold,  get_param(retry_threshold, ?LEASE_TIME)},
                     {multiplier, get_param(retry_backoff, 2)}]),

    State = #state{parent = Parent,
                   target = TargetNode,
                   uuid   = UUID,

                   rto           = Rto,
                   retry_backoff = RetryBackoff,

                   have_lease    = false,
                   acquire_timer = misc:create_timer(acquire),
                   revoke_timer  = misc:create_timer(revoke)},

    loop(acquire_now(State)).

loop(State) ->
    receive
        acquire ->
            loop(handle_acquire_lease(State));
        revoke ->
            loop(handle_revoke_lease(State));
        {Ref, _} when is_reference(Ref) ->
            %% this is late gen_server call response, so just skipping
            loop(State);
        Msg ->
            ?log_warning("Received unexpected message ~p when state is~n~p",
                         [Msg, State]),
            loop(State)
    end.

%% To simplify the code elsewhere, we may try to "revoke" the lease when we
%% actually are not holding it. In such a case, we simply schedule another
%% attempt to acquire the lease.
handle_revoke_lease(#state{have_lease = false} = State) ->
    retry_acquire(State);
handle_revoke_lease(State) ->
    ok = leader_activities:lease_lost(parent(State), target_node(State)),
    retry_acquire(State#state{have_lease = false}).

handle_acquire_lease(#state{target = TargetNode,
                            uuid   = UUID} = State) ->
    Start   = time_compat:monotonic_time(),
    Timeout = get_acquire_timeout(State),

    try leader_lease_agent:acquire_lease(TargetNode,
                                         node(), UUID, ?LEASE_TIME,
                                         Timeout) of
        {ok, LeaseProps} ->
            handle_lease_acquired(Start, LeaseProps, State);
        {error, timeout} ->
            handle_acquire_timeout(Timeout, State);
        {error, lease_lost} ->
            handle_lease_lost(Start, State);
        {error, {already_acquired, LeaseProps}} ->
            handle_lease_already_acquired(Start, LeaseProps, State);
        Other ->
            handle_unexpected_response(Other, State)
    catch
        T:E ->
            handle_exception({T, E}, State)
    end.

handle_acquire_timeout(Timeout, State) ->
    ?log_warning("Timeout while trying to acquire lease from ~p. "
                 "Timeout was ~bms", [target_node(State), Timeout]),

    functools:chain(State,
                    [backoff_rto(_),

                     %% Since we timed out, it most likely doesn't make sense
                     %% to wait much before retrying, so we just reset the
                     %% timeout to the lowest value.
                     reset_retry(_),

                     %% The way we pick the timeout pretty much ensures that
                     %% we don't have time to retry. So we backoff to try to
                     %% avoid this in future and also revoking the lease.
                     revoke_now(_)]).

handle_lease_acquired(StartTime, LeaseProps, State) ->
    Now        = time_compat:monotonic_time(),
    TimePassed = misc:convert_time_unit(Now - StartTime, millisecond),

    maybe_notify_lease_acquired(State),

    {_, TimeLeft0} = lists:keyfind(time_left, 1, LeaseProps),

    TimeLeft    = max(0, TimeLeft0 - TimePassed - ?LEASE_GRACE_TIME),
    ExtendAfter = get_extend_timeout(StartTime, TimeLeft, State),

    NewState = State#state{have_lease = true},
    functools:chain(NewState,
                    [reset_retry(_),
                     update_rtt(StartTime, _),
                     acquire_after(ExtendAfter, _),
                     revoke_after(TimeLeft, _)]).

handle_lease_already_acquired(StartTime, LeaseProps, State) ->
    {node, Node}          = lists:keyfind(node, 1, LeaseProps),
    {uuid, UUID}          = lists:keyfind(uuid, 1, LeaseProps),
    {time_left, TimeLeft} = lists:keyfind(time_left, 1, LeaseProps),

    ?log_warning("Failed to acquire lease from ~p "
                 "because its already taken by ~p (valid for ~bms)",
                 [target_node(State), {Node, UUID}, TimeLeft]),

    functools:chain(State,
                    [update_rtt(StartTime, _),
                     reset_retry(_),

                     %% Being pessimistic here and assuming that our
                     %% communication to the remote node was instantaneous.
                     acquire_after(TimeLeft, _)]).

handle_unexpected_response(Resp, State) ->
    ?log_warning("Received unexpected "
                 "response ~p from node ~p", [Resp, target_node(State)]),

    %% Well, don't have much else to do.
    revoke_now(backoff_retry(State)).

handle_exception(Exception, State) ->
    ?log_warning("Failed to acquire lease from ~p: ~p",
                 [target_node(State), Exception]),

    revoke_now(backoff_retry(State)).

handle_lease_lost(StartTime, State) ->
    ?log_warning("Node ~p told us that we lost its lease", [target_node(State)]),

    %% this is supposed to be a very short condition, so we don't backoff here
    %% and even update the round trip time
    revoke_now(update_rtt(StartTime, State)).

get_param(Name, Default) ->
    ns_config:read_key_fast({?MODULE, Name}, Default).

%% Since acquire_lease internally is just a gen_server call, we can be sure
%% that our message either reaches the worker process on target node or we get
%% an exception as a result of the distribution connection between the nodes
%% being closed. So we want to pick the timeout as long as possible, but so
%% that we can process the revocation in a timely way.
get_acquire_timeout(#state{have_lease = false}) ->
    %% Well, if that's not enough, we probably won't be able to keep the lease
    %% anyway.
    ?LEASE_TIME;
get_acquire_timeout(#state{revoke_timer = RevokeTimer}) ->
    TimeLeft = misc:read_timer(RevokeTimer),
    true = is_integer(TimeLeft),

    TimeLeft.

get_extend_timeout(StartTime, TimeLeft, #state{rto = Rto}) ->
    RtoTimeout = rto:get_timeout(Rto),

    %% Just so that we don't sit in a busy loop.
    MinExtendTimeout = get_min_extend_timeout(StartTime),

    %% The buffer we leave for ourselves consists of two parts:
    %%
    %%   - Retransmission timeout.
    %%   - The time passed since we started the acquire call.
    %%
    %% The former is our idea of how much time we need for acquire to succeed
    %% at most. The latter is our actual round trip time for this call. So
    %% it's quite pessimistic (which is good here) since it's not very likely
    %% that all this time was spent on the way back from the target node.
    Timeout = TimeLeft - RtoTimeout,

    max(MinExtendTimeout, Timeout).

get_min_extend_timeout(StartTime) ->
    Now        = time_compat:monotonic_time(),
    SinceStart = misc:convert_time_unit(Now - StartTime, millisecond),

    max(0, get_param(min_extend_timeout, 100) - SinceStart).

update_rtt(Start, State) ->
    Now  = time_compat:monotonic_time(),
    Diff = misc:convert_time_unit(Start - Now, millisecond),

    misc:update_field(#state.rto, State, rto:note_success(Diff, _)).

backoff_rto(State) ->
    misc:update_field(#state.rto, State, rto:note_failure(_)).

get_retry_timeout(State) ->
    backoff:get_timeout(State#state.retry_backoff).

backoff_retry(State) ->
    misc:update_field(#state.retry_backoff, State, backoff:next(_)).

reset_retry(State) ->
    misc:update_field(#state.retry_backoff, State, backoff:reset(_)).

acquire_now(State) ->
    acquire_after(0, State).

acquire_after(Timeout, State) ->
    misc:update_field(#state.acquire_timer, State, misc:arm_timer(Timeout, _)).

revoke_now(State) ->
    revoke_after(0, State).

revoke_after(Timeout, State) ->
    misc:update_field(#state.revoke_timer, State, misc:arm_timer(Timeout, _)).

target_node(#state{target = Node}) ->
    Node.

parent(#state{parent = Parent}) ->
    Parent.

retry_acquire(State) ->
    acquire_after(get_retry_timeout(State), State).

maybe_notify_lease_acquired(#state{have_lease = true}) ->
    %% We already owned the lease, so we won't notify our parent.
    ok;
maybe_notify_lease_acquired(State) ->
    ok = leader_activities:lease_acquired(parent(State), target_node(State)).
