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
-module(leader_lease_acquirer).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("cut.hrl").
-include("ns_common.hrl").

-define(SERVER, ?MODULE).

-type worker() :: {pid(), reference()}.
-record(state, { uuid    :: binary(),
                 nodes   :: sets:set(node()),
                 workers :: [{node(), worker()}],

                 leader_activities_pid :: pid()
               }).

%% API
start_link() ->
    leader_utils:ignore_if_new_orchestraction_disabled(
      fun () ->
          proc_lib:start_link(?MODULE, init, [[]])
      end).

%% gen_server callbacks
init([]) ->
    register(?SERVER, self()),
    proc_lib:init_ack({ok, self()}),

    case cluster_compat_mode:is_cluster_vulcan() of
        true ->
            ok;
        false ->
            ?log_debug("Delaying start since cluster "
                       "is not fully upgraded to vulcan yet."),
            wait_cluster_is_vulcan()
    end,
    enter_loop().

enter_loop() ->
    process_flag(priority, high),
    process_flag(trap_exit, true),

    Self = self(),
    ns_pubsub:subscribe_link(ns_node_disco_events,
                             case _ of
                                 {ns_node_disco_events, _Old, New} ->
                                     Self ! {new_nodes, New};
                                 _Other ->
                                     ok
                             end),

    %% Generally, we are started after the leader_activities, so the name
    %% should already be there. It's only when leader_activities dies
    %% abnormally that we need to wait here. Hopefully, it shouldn't take it
    %% long to restart, hence the short timeout.
    ok = misc:wait_for_local_name(leader_activities, 1000),

    {ok, Pid} = leader_activities:register_acquirer(Self),
    erlang:monitor(process, Pid),

    State = #state{uuid    = couch_uuids:random(),
                   nodes   = sets:new(),
                   workers = [],

                   leader_activities_pid = Pid},

    Nodes = ns_node_disco:nodes_actual(),
    gen_server:enter_loop(?MODULE, [],
                          handle_new_nodes(Nodes, State), {local, ?SERVER}).


handle_call(Request, _From, State) ->
    ?log_error("Received unexpected call ~p when state is~n~p",
               [Request, State]),
    {reply, nack, State}.

handle_cast(Msg, State) ->
    ?log_error("Received unexpected cast ~p when state is~n~p", [Msg, State]),
    {noreply, State}.

handle_info({new_nodes, Nodes}, State) ->
    {noreply, handle_new_nodes(Nodes, State)};
handle_info({'DOWN', MRef, process, Pid, Reason}, State) ->
    {noreply, handle_down(MRef, Pid, Reason, State)};
handle_info(Info, State) ->
    ?log_error("Received unexpected message ~p when state is~n~p",
               [Info, State]),
    {noreply, State}.

terminate(Reason, State) ->
    handle_terminate(Reason, State).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
handle_new_nodes(NewNodes0, #state{nodes = OldNodes} = State) ->
    NewNodes = sets:from_list(NewNodes0),
    Added    = sets:subtract(NewNodes, OldNodes),
    Removed  = sets:subtract(OldNodes, NewNodes),
    NewState = State#state{nodes = NewNodes},

    handle_added_nodes(Added, handle_removed_nodes(Removed, NewState)).

handle_added_nodes(Nodes, State) ->
    spawn_many_workers(Nodes, State).

handle_removed_nodes(Nodes, State) ->
    shutdown_many_workers(Nodes, State).

handle_down(_MRef, Pid, Reason, #state{leader_activities_pid = Pid}) ->
    ?log_info("Leader activities process ~p terminated with reason ~p",
              [Pid, Reason]),
    exit({leader_activities_died, Pid, Reason});
handle_down(MRef, Pid, Reason, State) ->
    Worker = {Pid, MRef},

    ?log_debug("Received DOWN message ~p", [{MRef, Pid, Reason}]),

    {ok, {Node, Worker}, NewState} = take_worker(Worker, State),
    ?log_error("Worker ~p for node ~p terminated unexpectedly (reason ~p)",
               [Worker, Node, Reason]),

    cleanup_after_worker(Node),
    spawn_worker(Node, NewState).

handle_terminate(Reason, State) ->
    case misc:is_shutdown(Reason) of
        true ->
            ok;
        false ->
            ?log_warning("Terminating abnormally (reason ~p):~n~p",
                         [Reason, State])
    end,

    shutdown_all_workers(State),
    abolish_all_leases(State),
    ok.

abolish_all_leases(#state{nodes = Nodes, uuid  = UUID}) ->
    leader_lease_agent:abolish_leases(sets:to_list(Nodes), node(), UUID).

spawn_many_workers(Nodes, State) ->
    NewWorkers = [{N, spawn_worker(N, State)} || N <- sets:to_list(Nodes)],
    misc:update_field(#state.workers, State, NewWorkers ++ _).

spawn_worker(Node, State) ->
    leader_lease_acquire_worker:spawn_monitor(Node, State#state.uuid).

shutdown_all_workers(State) ->
    shutdown_many_workers(State#state.nodes, State).

shutdown_many_workers(Nodes, State) ->
    misc:update_field(#state.workers, State,
                      lists:filter(fun ({N, Worker}) ->
                                           case sets:is_element(N, Nodes) of
                                               true ->
                                                   shutdown_worker(N, Worker),
                                                   false;
                                               false ->
                                                   true
                                           end
                                   end, _)).

shutdown_worker(Node, {Pid, MRef}) ->
    erlang:demonitor(MRef, [flush]),
    async:abort(Pid),

    cleanup_after_worker(Node).

cleanup_after_worker(Node) ->
    %% make sure that if we owned the lease, we report it being lost
    ok = leader_activities:lease_lost(self(), Node).

take_worker(Worker, #state{workers = Workers} = State) ->
    case lists:keytake(Worker, 2, Workers) of
        {value, NodeWorker, RestWorkers} ->
            {ok, NodeWorker, State#state{workers = RestWorkers}};
        false ->
            not_found
    end.

wait_cluster_is_vulcan() ->
    Self = self(),
    Pid  = ns_pubsub:subscribe_link(
             ns_config_events,
             case _ of
                 {cluster_compat_version, _} = Event ->
                     Self ! Event;
                 _ ->
                     ok
             end),

    wait_cluster_is_vulcan_loop(cluster_compat_mode:get_compat_version()),
    ns_pubsub:unsubscribe(Pid),

    ?flush({cluster_compat_version, _}).

wait_cluster_is_vulcan_loop(Version) ->
    case cluster_compat_mode:is_version_vulcan(Version) of
        true ->
            ?log_debug("Cluster upgraded to vulcan. Starting."),
            ok;
        false ->
            receive
                {cluster_compat_version, NewVersion} ->
                    wait_cluster_is_vulcan_loop(NewVersion)
            end
    end.
