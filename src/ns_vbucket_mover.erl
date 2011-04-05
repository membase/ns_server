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
-module(ns_vbucket_mover).

-behavior(gen_server).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(MAX_MOVES_PER_NODE, 1).

%% API
-export([start_link/4, stop/1]).

%% gen_server callbacks
-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-type progress_callback() :: fun((dict()) -> any()).

-record(state, {bucket::nonempty_string(),
                initial_counts::dict(),
                max_per_node::pos_integer(),
                map::array(), target_map::array(),
                moves::dict(), movers::dict(),
                progress_callback::progress_callback()}).

%%
%% API
%%

%% @doc Start the mover.
-spec start_link(string(), map(), map(), progress_callback()) ->
                        {ok, pid()} | {error, any()}.
start_link(Bucket, OldMap, NewMap, ProgressCallback) ->
    gen_server:start_link(?MODULE, {Bucket, OldMap, NewMap, ProgressCallback},
                          []).


%% @doc Stop the in-progress moves.
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:call(Pid, stop).





%%
%% gen_server callbacks
%%

code_change(_OldVsn, _Extra, State) ->
    {ok, State}.


init({Bucket, OldMap, NewMap, ProgressCallback}) ->
    %% Dictionary mapping old node to vbucket and new node
    MoveDict = lists:foldl(fun ({_, [M1|_], [M1|_]}, D) -> D;
                               ({V, [M1|_], [M2|_]}, D) ->
                                   dict:append(M1, {V, M2}, D)
                           end, dict:new(),
                           lists:zip3(lists:seq(0, length(OldMap) - 1), OldMap,
                                      NewMap)),
    %% Update any replicas where the master hasn't been moved
    Map = [if hd(C1) == hd(C2) -> C2; true -> C1 end
           || {C1, C2} <- lists:zip(OldMap, NewMap)],
    Movers = dict:map(fun (_, _) -> 0 end, MoveDict),
    self() ! spawn_initial,
    process_flag(trap_exit, true),
    {ok, #state{bucket=Bucket,
                initial_counts=count_moves(MoveDict),
                max_per_node=?MAX_MOVES_PER_NODE,
                map = map_to_array(Map),
                target_map = map_to_array(NewMap),
                moves=MoveDict, movers=Movers,
                progress_callback=ProgressCallback}}.


handle_call(stop, _From, State) ->
    %% All the linked processes should exit when we do.
    {stop, normal, ok, State}.


handle_cast(unhandled, unhandled) ->
    unhandled.


%% We intentionally don't handle other exits so we'll die if one of
%% the movers fails.
handle_info(spawn_initial, State) ->
    spawn_workers(State);
handle_info({move_done, {Node, VBucket}},
            #state{movers=Movers, map=Map, target_map=TargetMap} = State) ->
    %% Free up a mover for this node
    Movers1 = dict:update(Node, fun (N) -> N - 1 end, Movers),
    %% Pull the new chain from the target map
    NewChain = array:get(VBucket, TargetMap),
    %% Update the current map
    Map1 = array:set(VBucket, NewChain, Map),
    spawn_workers(State#state{movers=Movers1, map=Map1});
handle_info({'EXIT', _, normal}, State) ->
    {noreply, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    ?log_error("~p exited with ~p", [Pid, Reason]),
    {stop, Reason, State};
handle_info(Info, State) ->
    ?log_info("Unhandled message ~p", [Info]),
    {noreply, State}.


terminate(_Reason, #state{bucket=Bucket, map=MapArray}) ->
    %% Save the current state of the map
    Map = array_to_map(MapArray),
    ?log_info("Setting final map to ~p", [Map]),
    ns_bucket:set_map(Bucket, Map),
    ok.


%%
%% Internal functions
%%

%% @private
%% @doc Convert a map array back to a map list.
-spec array_to_map(array()) ->
                          map().
array_to_map(Array) ->
    array:to_list(Array).


%% @doc Count of remaining moves per node.
-spec count_moves(dict()) -> dict().
count_moves(Moves) ->
    %% Number of moves FROM a given node.
    FromCount = dict:map(fun (_, M) -> length(M) end, Moves),
    %% Add moves TO each node.
    dict:fold(fun (_, M, D) ->
                      lists:foldl(
                        fun ({_, N}, E) ->
                                dict:update_counter(N, 1, E)
                        end, D, M)
              end, FromCount, Moves).


%% @private
%% @doc Convert a map, which is normally a list, into an array so that
%% we can randomly access the replication chains.
-spec map_to_array(map()) ->
                          array().
map_to_array(Map) ->
    array:fix(array:from_list(Map)).


%% @doc Report progress using the supplied progress callback.
-spec report_progress(#state{}) -> any().
report_progress(#state{initial_counts=Counts, moves=Moves,
                       progress_callback=Callback}) ->
    Remaining = count_moves(Moves),
    Progress = dict:map(fun (Node, R) ->
                                Total = dict:fetch(Node, Counts),
                                1.0 - R / Total
                        end, Remaining),
    Callback(Progress).


%% @doc Spawn workers up to the per-node maximum.
-spec spawn_workers(#state{}) -> {noreply, #state{}} | {stop, normal, #state{}}.
spawn_workers(#state{bucket=Bucket, moves=Moves, movers=Movers,
                     max_per_node=MaxPerNode} = State) ->
    report_progress(State),
    Parent = self(),
    {Movers1, Remaining} =
        dict:fold(
          fun (Node, RemainingMoves, {M, R}) ->
                  NumWorkers = dict:fetch(Node, Movers),
                  if NumWorkers < MaxPerNode ->
                          NewMovers = lists:sublist(RemainingMoves,
                                                    MaxPerNode - NumWorkers),
                          lists:foreach(
                            fun ({V, NewNode})
                                  when Node /= NewNode ->
                                    %% Will crash (on purpose) if we
                                    %% have no-op moves.
                                    spawn_link(
                                      Node,
                                      fun () ->
                                              process_flag(trap_exit, true),
                                              run_mover(Bucket, V, Node,
                                                        NewNode, 2),
                                              Parent ! {move_done, {Node, V}}
                                      end)
                            end, NewMovers),
                          M1 = dict:store(Node, length(NewMovers) + NumWorkers,
                                          M),
                          R1 = dict:store(Node, lists:nthtail(length(NewMovers),
                                                              RemainingMoves), R),
                          {M1, R1};
                     true ->
                          {M, R}
                  end
          end, {Movers, Moves}, Moves),
    State1 = State#state{movers=Movers1, moves=Remaining},
    Values = dict:fold(fun (_, V, L) -> [V|L] end, [], Movers1),
    case Values /= [] andalso lists:any(fun (V) -> V /= 0 end, Values) of
        true ->
            {noreply, State1};
        false ->
            {stop, normal, State1}
    end.


run_mover(Bucket, V, N1, N2, Tries) ->
    case {ns_memcached:get_vbucket(N1, Bucket, V),
          ns_memcached:get_vbucket(N2, Bucket, V)} of
        {{ok, active}, {memcached_error, not_my_vbucket, _}} ->
            %% Standard starting state
            ok = ns_memcached:set_vbucket(N2, Bucket, V, replica),
            {ok, _Pid} = ns_vbm_sup:spawn_mover(Bucket, V, N1, N2),
            wait_for_mover(Bucket, V, N1, N2, Tries);
        {{ok, dead}, {ok, active}} ->
            %% Standard ending state
            ok;
        {{memcached_error, not_my_vbucket, _}, {ok, active}} ->
            %% This generally shouldn't happen, but it's an OK final state.
            ?log_warning("Weird: vbucket ~p missing from source node ~p but "
                         "active on destination node ~p.", [V, N1, N2]),
            ok;
        {{ok, active}, {ok, S}} when S /= active ->
            %% This better have been a replica, a failed previous
            %% attempt to migrate, or loaded from a valid copy or this
            %% will result in inconsistent data!
            if S /= replica ->
                    ok = ns_memcached:set_vbucket(N2, Bucket, V, replica);
               true ->
                    ok
            end,
            {ok, _Pid} = ns_vbm_sup:spawn_mover(Bucket, V, N1, N2),
            wait_for_mover(Bucket, V, N1, N2, Tries);
        {{ok, dead}, {ok, pending}} ->
            %% This is a strange state to end up in - the source
            %% shouldn't close until the destination has acknowledged
            %% the last message, at which point the state should be
            %% active.
            ?log_warning("Weird: vbucket ~p in pending state on node ~p.",
                         [V, N2]),
            ok = ns_memcached:set_vbucket(N1, Bucket, V, active),
            ok = ns_memcached:set_vbucket(N2, Bucket, V, replica),
            {ok, _Pid} = ns_vbm_sup:spawn_mover(Bucket, V, N1, N2),
            wait_for_mover(Bucket, V, N1, N2, Tries)
    end.


wait_for_mover(Bucket, V, N1, N2, Tries) ->
    receive
        {'EXIT', _Pid, normal} ->
            case {ns_memcached:get_vbucket(N1, Bucket, V),
                  ns_memcached:get_vbucket(N2, Bucket, V)} of
                {{ok, dead}, {ok, active}} ->
                    ok;
                E ->
                    exit({wrong_state_after_transfer, E})
            end;
        {'EXIT', _Pid, stopped} ->
            exit(stopped);
        {'EXIT', _Pid, Reason} ->
            case Tries of
                0 ->
                    exit({mover_failed, Reason});
                _ ->
                    ?log_warning("Got unexpected exit reason from mover:~n~p",
                                 [Reason]),
                    run_mover(Bucket, V, N1, N2, Tries-1)
            end;
        Msg ->
            ?log_warning("Mover parent got unexpected message:~n"
                         "~p", [Msg]),
            wait_for_mover(Bucket, V, N1, N2, Tries)
    end.
