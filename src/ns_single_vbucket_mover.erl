%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(ns_single_vbucket_mover).

-export([spawn_mover/5, mover/6]).

-include("ns_common.hrl").

spawn_mover(Node, Bucket, VBucket,
            OldChain, NewChain) ->
    Parent = self(),
    spawn_link(ns_single_vbucket_mover, mover,
               [Parent, Node, Bucket, VBucket, OldChain, NewChain]).

mover(Parent, Node, Bucket, VBucket,
      OldChain, [NewNode|_] = NewChain) ->
    process_flag(trap_exit, true),
    %% We do a no-op here rather than filtering these out so that the
    %% replication update will still work properly.
    if
        Node =:= undefined ->
            %% this handles case of missing vbucket (like after failing over
            %% more nodes then replica count)
            ok;
        Node /= NewNode ->
            run_mover(Bucket, VBucket, Node, NewNode, 2);
        true ->
            ok
    end,
    Parent ! {move_done, {Node, VBucket, OldChain, NewChain}}.

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
            ?rebalance_warning("Weird: vbucket ~p missing from source node ~p but "
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
            ?rebalance_warning("Weird: vbucket ~p in pending state on node ~p.",
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
                    exit({wrong_state_after_transfer, E, V})
            end;
        {'EXIT', _Pid, stopped} ->
            exit(stopped);
        {'EXIT', _Pid, Reason} ->
            case Tries of
                0 ->
                    exit({mover_failed, Reason});
                _ ->
                    ?rebalance_warning("Got unexpected exit reason from mover:~n~p",
                                       [Reason]),
                    run_mover(Bucket, V, N1, N2, Tries-1)
            end;
        Msg ->
            ?rebalance_warning("Mover parent got unexpected message:~n"
                               "~p", [Msg]),
            wait_for_mover(Bucket, V, N1, N2, Tries)
    end.
