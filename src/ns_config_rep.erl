%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% ns_config_rep is a server responsible for all things configuration
%% synch related.
%%
%% NOTE: that this code tries to merge similar replication requests
%% before trying to perform them. That's beneficial because due to
%% some nodes going down some replications might take very long
%% time. Which will cause our mailbox to grow with easily mergable
%% requests.
%%
-module(ns_config_rep).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").

-define(PULL_TIMEOUT, 10000).
-define(SELF_PULL_TIMEOUT, 30000).
-define(SYNCHRONIZE_TIMEOUT, 30000).

-define(MERGING_EMERGENCY_THRESHOLD, 2000).

% How to launch the thing.
-export([start_link/0, start_link_merger/0]).

% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% API
-export([push/0,
         synchronize_local/0, synchronize_remote/0, synchronize_remote/1,
         pull_and_push/1]).

-record(state, {}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_link_merger() ->
    proc_lib:start_link(erlang, apply, [fun merger_init/0, []]).

init([]) ->
    Self = self(),
    ns_pubsub:subscribe_link(ns_config_events_local,
                             fun (Keys) ->
                                     Self ! {push_keys, Keys}
                             end),
    % Start with startup config sync.
    ?log_debug("init pulling~n", []),
    do_pull(),
    ?log_debug("init pushing~n", []),
    do_push(),
    % Have ns_config reannounce its config for any synchronization that
    % may have occurred.
    ?log_debug("init reannouncing~n", []),
    ns_config:reannounce(),
    % Schedule some random config syncs.
    schedule_config_sync(),
    ok = ns_node_disco_rep_events:add_sup_handler(),
    {ok, #state{}}.

merger_init() ->
    erlang:register(ns_config_rep_merger, self()),
    proc_lib:init_ack({ok, self()}),
    merger_loop().

merger_loop() ->
    EnterTime = os:timestamp(),
    receive
        {merge_compressed, Blob} ->
            WakeTime = os:timestamp(),
            KVList = binary_to_term(zlib:uncompress(Blob)),
            system_stats_collector:increment_counter(total_config_merger_sleep_time, timer:now_diff(WakeTime, EnterTime)),
            do_merge(KVList),
            system_stats_collector:increment_counter(total_config_merger_run_time, timer:now_diff(os:timestamp(), WakeTime)),
            system_stats_collector:increment_counter(total_config_merger_runs, 1),
            {message_queue_len, QL} = erlang:process_info(self(), message_queue_len),
            system_stats_collector:set_counter(config_merger_queue_len, QL),
            case QL > ?MERGING_EMERGENCY_THRESHOLD of
                true ->
                    ?log_warning("Queue size emergency state reached. "
                                 "Will kill myself and resync"),
                    exit(emergency_kill);
                false -> ok
            end;
        {'$gen_call', From, sync} ->
            gen_server:reply(From, sync_done)
    end,
    merger_loop().

handle_call(synchronize, _From, State) ->
    {reply, ok, State};
handle_call(synchronize_everything, {Pid, _Tag} = _From,
            State) ->
    RemoteNode = node(Pid),
    ?log_debug("Got full synchronization request from ~p", [RemoteNode]),

    StartTS = os:timestamp(),
    sync_done = gen_server:call(ns_config_rep_merger, sync, ?SYNCHRONIZE_TIMEOUT),
    EndTS = os:timestamp(),
    Diff = timer:now_diff(EndTS, StartTS),
    ?log_debug("Fully synchronized config in ~p us", [Diff]),

    {reply, ok, State};
handle_call(Msg, _From, State) ->
    ?log_warning("Unhandled call: ~p", [Msg]),
    {reply, error, State}.

handle_cast({merge_compressed, _Blob} = Msg, State) ->
    ns_config_rep_merger ! Msg,
    {noreply, State};
handle_cast(Msg, State) ->
    ?log_error("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

accumulate_X(Acc, X) ->
    receive
        {X, Value} ->
            accumulate_X(lists:umerge(lists:sort(Value), Acc), X)
    after 0 ->
            Acc
    end.

accumulate_pull_and_push(Nodes) ->
    accumulate_X(lists:sort(Nodes), pull_and_push).

accumulate_pull_and_push_test() ->
    receive
        {pull_and_push, _} -> exit(bad)
    after 0 -> ok
    end,

    L1 = [a,b],
    L2 = [b,c,e],
    L3 = [a,d],
    self() ! {pull_and_push, L2},
    self() ! {pull_and_push, L3},
    ?assertEqual([a,b,c,d,e],
                 accumulate_pull_and_push(L1)),
    receive
        {pull_and_push, _} -> exit(bad)
    after 0 -> ok
    end.

accumulate_push_keys(InitialKeys) ->
    accumulate_X(lists:sort(InitialKeys), push_keys).

accumulate_push_keys_and_get_config(_Keys0, 0) ->
    system_stats_collector:increment_counter(ns_config_rep_push_keys_retries_exceeded, 1),
    ale:warn(?USER_LOGGER, "Exceeded retries count trying to get consistent keys/values for config replication. This is minor bug. Everything is safe, but please file bug and attach logs", []),
    KVs = lists:sort(ns_config:get_kv_list()),
    Keys = [K || {K, _} <- KVs],
    do_push_keys(Keys, KVs);
accumulate_push_keys_and_get_config(Keys0, RetriesLeft) ->
    Keys = accumulate_push_keys(Keys0),
    AllConfigKV = ns_config:get_kv_list(),
    %% the following ensures that all queued ns_config_events_local
    %% events are processed (and thus we've {push_keys, ...} in our
    %% mailbox if there were any local config mutations
    gen_event:which_handlers(ns_config_events_local),
    receive
        {push_keys, _} = Msg ->
            %% ok, yet another change is detected, we need to retry so
            %% that AllConfigKV is consistent with list of changed
            %% keys we have
            system_stats_collector:increment_counter(ns_config_rep_push_keys_retries, 1),
            system_stats_collector:increment_counter(ns_config_rep_push_keys_total_retries_left, RetriesLeft),
            %% ordering of these messages is irrelevant so we can
            %% resend and retry
            self() ! Msg,
            accumulate_push_keys_and_get_config(Keys, RetriesLeft-1)
    after 0 ->
            %% we know that AllConfigKV has exactly changes we've seen
            %% with {push_keys, ...}. I.e. there's no way config
            %% could've changed by local mutation before us getting it
            %% and us not detecting it here. Also we can see that
            %% we're reading values after we've seen keys.
            %%
            %% NOTE however that non-local mutation (i.e. incoming
            %% config replication) may have overriden some local
            %% mutations. And it's possible for us to see final value
            %% rather than produced by local mutation. It seems to be
            %% possible only when there's config conflict btw.
            %%
            %% So worst case seems to be that our node accidently
            %% replicates some value mutated on other node without
            %% replicating other change(s) by that other
            %% node. I.e. some third node may see partial config
            %% mutations of other node via config replication from
            %% this node. Given that we don't normally cause config
            %% conflicts and that in some foreseeble future we're
            %% going to make our config replication even less
            %% conflict-prone I think it should be ok. I.e. local
            %% mutation that is overwritten by conflicting incoming
            %% change is already bug.
            do_push_keys(Keys, AllConfigKV)
    end.

handle_info({push_keys, Keys0}, State) ->
    accumulate_push_keys_and_get_config(Keys0, 10),
    {noreply, State};
handle_info({pull_and_push, Nodes}, State) ->
    ?log_info("Replicating config to/from:~n~p", [Nodes]),
    FinalNodes = accumulate_pull_and_push(Nodes),
    do_pull(FinalNodes, length(FinalNodes)),
    RawKVList = ns_config:get_kv_list(?SELF_PULL_TIMEOUT),
    do_push(RawKVList, FinalNodes),
    ?log_debug("config pull_and_push done.~n", []),
    {noreply, State};
handle_info(push, State) ->
    misc:flush(push),
    do_push(),
    {noreply, State};
handle_info(sync_random, State) ->
    schedule_config_sync(),
    do_pull(1),
    {noreply, State};
handle_info({'EXIT', _From, Reason} = Msg, _State) ->
    ?log_warning("Got exit message. Exiting: ~p", [Msg]),
    {stop, Reason};
handle_info(Msg, State) ->
    ?log_debug("Unhandled msg: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%
% API methods
%

push() ->
    ?MODULE ! push.

% awaits completion of all previous requests
synchronize_local() ->
    gen_server:call(?MODULE, synchronize, ?SYNCHRONIZE_TIMEOUT).

synchronize_remote() ->
    synchronize_remote(ns_node_disco:nodes_actual_other()).

synchronize_remote(Nodes) ->
    ok = synchronize_local(),
    {Replies, BadNodes0} =
        gen_server:multi_call(Nodes, ?MODULE,
                              synchronize_everything, ?SYNCHRONIZE_TIMEOUT),

    BadNodes = [{N, down} || N <- BadNodes0],

    AllBadNodes =
        lists:foldl(
          fun ({Node, Reply}, Acc) ->
                  case Reply of
                      ok ->                     % new node
                          Acc;
                      error ->
                          %% must be an old node; see default clause of
                          %% handle_call
                          Acc;
                      _Other ->
                          [{Node, Reply} | Acc]
                  end
          end, BadNodes, Replies),

    case AllBadNodes of
        [] ->
            ok;
        _ ->
            ?log_error("Failed to synchronize config to some nodes: ~n~p",
                       [AllBadNodes]),
            {error, AllBadNodes}
    end.

pull_and_push([]) -> ok;
pull_and_push(Nodes) ->
    ?MODULE ! {pull_and_push, Nodes}.

%
% Privates
%

schedule_config_sync() ->
    Frequency = 5000 + trunc(random:uniform() * 55000),
    timer2:send_after(Frequency, self(), sync_random).

extract_kvs([], _KVs, Acc) ->
    Acc;
extract_kvs([K | Ks] = AllKs, [{CK,_} = KV | KVs], Acc) ->
    case K =:= CK of
        true ->
            extract_kvs(Ks, KVs, [KV | Acc]);
        _ ->
            %% we expect K to be present in kvs
            true = (K > CK),
            extract_kvs(AllKs, KVs, Acc)
    end.

do_push_keys(Keys, AllKVs) ->
    ?log_debug("Replicating some config keys (~p..)", [lists:sublist(Keys, 64)]),
    KVsToPush = extract_kvs(Keys, lists:sort(AllKVs), []),
    do_push(KVsToPush).

do_push() ->
    do_push(ns_config:get_kv_list(?SELF_PULL_TIMEOUT)).

do_push(RawKVList) ->
    do_push(RawKVList, ns_node_disco:nodes_actual_other()).

do_push(RawKVList, OtherNodes) ->
    Blob = zlib:compress(term_to_binary(RawKVList)),
    misc:parallel_map(fun(Node) ->
                              gen_server:cast({ns_config_rep, Node},
                                              {merge_compressed, Blob})
                      end,
                      OtherNodes, 2000).

do_pull()  -> do_pull(5).
do_pull(N) -> do_pull(misc:shuffle(ns_node_disco:nodes_actual_other()), N).

do_pull([], _N)    -> ok;
do_pull(_Nodes, 0) -> error;
do_pull([Node | Rest], N) ->
    ?log_info("Pulling config from: ~p~n", [Node]),
    case (catch get_remote(Node, ?PULL_TIMEOUT)) of
        {'EXIT', _, _} -> do_pull(Rest, N - 1);
        {'EXIT', _}    -> do_pull(Rest, N - 1);
        RemoteKVList   -> do_merge(RemoteKVList),
                          ok
    end.

do_merge(RemoteKVList) ->
    Config = ns_config:get(),
    LocalKVList = ns_config:get_kv_list_with_config(Config),
    UUID = ns_config:uuid(Config),
    Cluster30 = cluster_compat_mode:is_cluster_30(),
    NewKVList = ns_config:merge_kv_pairs(RemoteKVList, LocalKVList, UUID, Cluster30),
    case NewKVList =:= LocalKVList of
        true ->
            ok;
        _ ->
            case ns_config:cas_remote_config(NewKVList, LocalKVList) of
                true ->
                    ok;
                _ ->
                    ?log_warning("config cas failed. Retrying", []),
                    do_merge(RemoteKVList)
            end
    end.

get_remote(Node, Timeout) ->
    hd(misc:parallel_map(fun (_) ->
                                 Blob = ns_config_replica:get_compressed(
                                          ns_config_remote,
                                          Node, Timeout),
                                 binary_to_term(zlib:uncompress(Blob))
                         end, [Node], Timeout)).
