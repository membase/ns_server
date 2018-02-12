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
-module(leader_lease_agent).

-behaviour(gen_server2).

-export([start_link/0]).

-export([get_current_lease/0, get_current_lease/1,
         acquire_lease/5, abolish_leases/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("cut.hrl").
-include("ns_common.hrl").

-define(SERVER, ?MODULE).

-type lease_ts() :: integer().
-type lease_state() :: active | expiring.

-record(lease_holder, { uuid :: binary(),
                        node :: node() }).

-record(lease, { holder  :: #lease_holder{},
                 expires :: lease_ts(),
                 timer   :: misc:timer(),
                 state   :: lease_state() }).

-record(state, { lease :: undefined | #lease{} }).

start_link() ->
    gen_server2:start_link({local, ?SERVER}, ?MODULE, [], []).

get_current_lease() ->
    get_current_lease(node()).

get_current_lease(Node) ->
    gen_server2:call({?SERVER, Node}, get_current_lease).

acquire_lease(WorkerNode, Node, UUID, Period, Timeout) ->
    try
        gen_server2:call({?SERVER, WorkerNode},
                         {acquire_lease, Node, UUID, Period}, Timeout)
    catch
        {exit, {timeout, _}} ->
            {error, timeout}
    end.

abolish_leases(WorkerNodes, Node, UUID) ->
    gen_server2:abcast(WorkerNodes, ?SERVER, {abolish_lease, Node, UUID}).

%% gen_server callbacks
init([]) ->
    process_flag(priority, high),
    process_flag(trap_exit, true),

    {ok, _} = leader_activities:register_agent(self()),
    {ok, maybe_recover_persisted_lease(#state{})}.

handle_call({acquire_lease, Node, UUID, Period}, From, State) ->
    Caller = #lease_holder{node = Node, uuid = UUID},
    {noreply, handle_acquire_lease(Caller, Period, From, State)};
handle_call(get_current_lease, From, State) ->
    {noreply, handle_get_current_lease(From, State)};
handle_call(Request, From, State) ->
    ?log_warning("Unexpected call ~p from ~p when the state is:~n~p",
                 [Request, From, State]),
    {reply, nack, State}.

handle_cast({abolish_lease, Node, UUID}, State) ->
    Caller = #lease_holder{node = Node, uuid = UUID},
    {noreply, handle_abolish_lease(Caller, State)};
handle_cast(Msg, State) ->
    ?log_warning("Unexpected cast ~p when the state is:~n~p",
                 [Msg, State]),
    {noreply, State}.

handle_info({lease_expired, Holder}, State) ->
    {noreply, handle_lease_expired(Holder, State)};
handle_info(Info, State) ->
    ?log_warning("Unexpected message ~p when the state is:~n~p",
                 [Info, State]),
    {noreply, State}.

terminate(_Reason, #state{lease = undefined}) ->
    ok;
terminate(Reason, #state{lease = Lease}) ->
    handle_terminate(Reason, Lease).

%% internal functions
handle_acquire_lease(Caller, Period, From, State) ->
    {Reply, NewState} = do_handle_acquire_lease(Caller, Period, State),
    gen_server2:reply(From, Reply),
    NewState.

do_handle_acquire_lease(Caller, Period, #state{lease = undefined} = State) ->
    ?log_debug("Granting lease to ~p for ~bms", [Caller, Period]),
    grant_lease(Caller, Period, State);
do_handle_acquire_lease(Caller, Period, #state{lease = Lease} = State) ->
    case Lease#lease.holder =:= Caller of
        true ->
            case Lease#lease.state of
                active ->
                    extend_lease(Period, State);
                expiring ->
                    Reply = {error, lease_lost},
                    {Reply, State}
            end;
        false ->
            Reply = {error, {already_acquired, build_lease_props(Lease)}},
            {Reply, State}
    end.

grant_lease(Caller, Period, #state{lease = Lease} = State) ->
    true = (Lease =:= undefined),

    %% this is not supposed to take long, so doing this in main process
    notify_local_lease_granted(self(), Caller),

    do_grant_lease(Caller, Period, State).

do_grant_lease(Caller, Period, State) ->
    Timer   = misc:create_timer(Period, {lease_expired, Caller}),
    Now     = time_compat:monotonic_time(millisecond),
    Expires = Now + Period,

    NewLease = #lease{holder  = Caller,
                      expires = Expires,
                      timer   = Timer,
                      state   = active},

    Reply = {ok, build_lease_props(Now, NewLease)},
    NewState = State#state{lease = NewLease},
    persist_lease(NewState),

    {Reply, NewState}.

extend_lease(Period, #state{lease = Lease} = State)
  when Lease =/= undefined ->
    cancel_timer(Lease),
    do_grant_lease(Lease#lease.holder, Period, State).

cancel_timer(Lease) ->
    misc:update_field(#lease.timer, Lease, misc:cancel_timer(_)).

handle_get_current_lease(From, #state{lease = Lease} = State) ->
    Reply = case Lease of
                undefined ->
                    {error, no_lease};
                _ ->
                    {ok, build_lease_props(Lease)}
            end,

    gen_server2:reply(From, Reply),

    State.

handle_abolish_lease(Caller, #state{lease = Lease} = State) ->
    ?log_debug("Received abolish lease request from ~p when lease is ~p",
               [Caller, Lease]),

    case can_abolish_lease(Caller, Lease) of
        true ->
            ?log_debug("Expiring abolished lease"),

            %% Passing lease holder instead of Caller here due to possible
            %% node rename. See can_abolish_lease for details.
            start_expire_lease(Lease#lease.holder,
                               State#state{lease = cancel_timer(Lease)});
        false ->
            ?log_debug("Ignoring stale abolish request"),
            State
    end.

can_abolish_lease(_Caller, undefined) ->
    false;
can_abolish_lease(Caller, #lease{state  = State,
                                 holder = Holder}) ->
    %% This is not exactly clean, but we only compare the UUIDs here to deal
    %% with node renames. We restart leader related processes on rename, but
    %% only after node name has changed. So an attempt to abolish the lease
    %% will fail.
    %%
    %% We could of course use node UUIDs instead of node names, but that would
    %% complicate debugging quite significantly.
    State =:= active andalso
        Holder#lease_holder.uuid =:= Caller#lease_holder.uuid.

handle_lease_expired(Holder, State) ->
    ?log_debug("Lease held by ~p expired. Starting expirer.", [Holder]),
    start_expire_lease(Holder, State).

start_expire_lease(Holder, #state{lease = Lease} = State) ->
    true = (Lease#lease.holder =:= Holder),
    true = (Lease#lease.state =:= active),

    Self = self(),
    gen_server2:async_job(?cut(notify_local_lease_expired(Self, Holder)),
                          handle_expire_done(Holder, _, _)),

    NewLease = Lease#lease{state = expiring},
    State#state{lease = NewLease}.

handle_expire_done(Holder, Reply, #state{lease = Lease} = State) ->
    ok       = Reply,
    true     = (Lease#lease.holder =:= Holder),
    expiring = Lease#lease.state,

    remove_persisted_lease(),

    {noreply, State#state{lease = undefined}}.

handle_terminate(Reason, #lease{state = active} = Lease) ->
    ?log_warning("Terminating with reason ~p when we have a lease granted:~n~p",
                 [Reason, Lease]),
    persist_lease(Lease);
handle_terminate(Reason, #lease{state = expiring} = Lease) ->
    ?log_warning("Terminating with reason ~p while lease ~p is still expiring",
                 [Reason, Lease]),

    %% Even though we haven't finished expiring the lease, it's safe to remove
    %% the persisted lease: the leader_activites process will cleanup after
    %% us. If we get restarted, we'll first have to register with
    %% leader_activities again, so we won't be able to grant a lease before
    %% all old activities are terminated.
    remove_persisted_lease().

build_lease_props(Lease) ->
    build_lease_props(time_compat:monotonic_time(millisecond), Lease).

build_lease_props(Now, #lease{holder = Holder} = Lease) ->
    [{node,      Holder#lease_holder.node},
     {uuid,      Holder#lease_holder.uuid},
     {time_left, time_left(Now, Lease)},
     {status,    Lease#lease.state}].

time_left(Now, #lease{expires = Expires}) ->
    %% Sometimes the expiration message may be a bit late, or maybe we're busy
    %% doing other things. Return zero in those cases. It essentially means
    %% that the lease is about to expire.
    max(0, Expires - Now).

dump_lease(Lease) ->
    misc:dump_term(build_lease_props(Lease)).

parse_lease_props(Dump) ->
    misc:parse_term(Dump).

lease_path() ->
    path_config:component_path(data, "leader_lease").

persist_lease(#state{lease = Lease}) ->
    true = (Lease =/= undefined),
    persist_lease(Lease);
persist_lease(#lease{} = Lease) ->
    misc:create_marker(lease_path(), [dump_lease(Lease), $\n]).

remove_persisted_lease() ->
    misc:remove_marker(lease_path()).

load_lease_props() ->
    try
        do_load_lease_props()
    catch
        T:E ->
            ?log_error("Can't read the lease because "
                       "of ~p. Going to ignore.", [{T, E}]),
            not_found
    end.

do_load_lease_props() ->
    case misc:take_marker(lease_path()) of
        {ok, Data} ->
            {ok, parse_lease_props(Data)};
        false ->
            not_found
    end.

maybe_recover_persisted_lease(State) ->
    case load_lease_props() of
        {ok, Props} ->
            ?log_warning("Found persisted lease ~p", [Props]),
            recover_lease_from_props(Props, State);
        not_found ->
            State
    end.

recover_lease_from_props(Props, State) ->
    Node     = misc:expect_prop_value(node, Props),
    UUID     = misc:expect_prop_value(uuid, Props),
    TimeLeft = misc:expect_prop_value(time_left, Props),

    Holder = #lease_holder{node = Node,
                           uuid = UUID},

    {_, NewState} = grant_lease(Holder, TimeLeft, State),
    NewState.

unpack_lease_holder(Holder) ->
    {Holder#lease_holder.node,
     Holder#lease_holder.uuid}.

notify_local_lease_granted(Pid, Holder) ->
    ok = leader_activities:local_lease_granted(Pid,
                                               unpack_lease_holder(Holder)).

notify_local_lease_expired(Pid, Holder) ->
    ok = leader_activities:local_lease_expired(Pid,
                                               unpack_lease_holder(Holder)).
