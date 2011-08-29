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
-export([start_link/0]).

% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% API
-export([push/0, initiate_changes_push/1, synchronize/0, pull_and_push/1]).

-record(state, {merger}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    % Start with startup config sync.
    ?log_info("init pulling~n", []),
    do_pull(),
    ?log_info("init pushing~n", []),
    do_push(),
    % Have ns_config reannounce its config for any synchronization that
    % may have occurred.
    ?log_info("init reannouncing~n", []),
    ns_config:reannounce(),
    % Schedule some random config syncs.
    schedule_config_sync(),
    ok = ns_node_disco_rep_events:add_sup_handler(),
    MergerPid = spawn_link(fun merger_loop/0),
    (catch erlang:unregister(ns_config_rep_merger)),
    erlang:register(ns_config_rep_merger, MergerPid),
    {ok, #state{merger = MergerPid}}.

merger_loop() ->
    receive
        X ->
            {merge_compressed, Blob} = X,
            KVList = binary_to_term(zlib:uncompress(Blob)),
            do_merge(KVList),
            case erlang:process_info(self(), message_queue_len) of
                {message_queue_len, Y} when Y > ?MERGING_EMERGENCY_THRESHOLD ->
                    ?log_info("Queue size emergency state reached. Will kill myself and resync", []),
                    exit(emergency_kill);
                {message_queue_len, _} -> ok
            end
    end,
    merger_loop().

handle_call(synchronize, _From, State) ->
    {reply, ok, State};
handle_call(Msg, _From, State) ->
    ?log_info("Unhandled call: ~p", [Msg]),
    {reply, error, State}.

handle_cast({merge_compressed, _Blob} = Msg, State) ->
    State#state.merger ! Msg,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

stack_while(Body, Ref, Tail) ->
    case Body(Ref) of
        Ref ->
            Tail;
        V -> stack_while(Body, Ref, [V|Tail])
    end.

accumulate_kv_pushes(List) ->
    ListOfLists =
        stack_while(fun (Ref) ->
                            receive
                                {push, X} -> lists:sort(X)
                            after 0 -> Ref
                            end
                    end, erlang:make_ref(), [lists:sort(List)]),
    lists:foldl(fun (CurList, OrdDict) ->
                        orddict:merge(fun (_K, _V1, V2) ->
                                              V2
                                      end,
                                      CurList, OrdDict)
                end, hd(ListOfLists), tl(ListOfLists)).

accumulate_kv_pushes_test() ->
    receive
        {push, _} -> exit(bad)
    after 0 -> ok
    end,
    KV1 = [{a, 1}, {b, 2}],
    KV2 = [{a, 2}, {c, 3}],

    self() ! {push, KV1},
    self() ! {push, KV2},
    ?assertEqual([{a,2},{b,2},{c,3}],
                 accumulate_kv_pushes([])),
    receive
        {push, _} -> exit(bad)
    after 0 -> ok
    end,

    self() ! {push, KV2},
    self() ! {push, KV1},
    ?assertEqual([{a,1},{b,2},{c,3}],
                 accumulate_kv_pushes([])),
    receive
        {push, _} -> exit(bad)
    after 0 -> ok
    end,

    self() ! {push, KV2},
    ?assertEqual([{a,2},{b,2},{c,3}],
                 accumulate_kv_pushes(KV1)).

accumulate_pull_and_push(Nodes) ->
    ListOfLists =
        stack_while(fun (Ref) ->
                            receive
                                {pull_and_push, X} -> lists:sort(X)
                            after 0 ->
                                    Ref
                            end
                    end, erlang:make_ref(), [lists:sort(Nodes)]),
    lists:umerge(ListOfLists).

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

handle_info({push, List}, State) ->
    ?log_info("Pushing config"),
    do_push(accumulate_kv_pushes(List)),
    ?log_info("Pushing config done"),
    {noreply, State};
handle_info({pull_and_push, Nodes}, State) ->
    ?log_info("Replicating config to/from:~n~p", [Nodes]),
    FinalNodes = accumulate_pull_and_push(Nodes),
    do_pull(FinalNodes, length(FinalNodes)),
    RawKVList = ns_config:get_kv_list(?SELF_PULL_TIMEOUT),
    do_push(RawKVList, FinalNodes),
    ?log_info("config pull_and_push done.~n", []),
    {noreply, State};
handle_info(push, State) ->
    misc:flush(push),
    do_push(),
    {noreply, State};
handle_info(sync_random, State) ->
    schedule_config_sync(),
    do_pull(1),
    {noreply, State};
handle_info(Msg, State) ->
    ?log_info("Unhandled msg: ~p", [Msg]),
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

initiate_changes_push(List) ->
    ?MODULE ! {push, List}.

% awaits completion of all previous requests
synchronize() ->
    gen_server:call(?MODULE, synchronize, ?SYNCHRONIZE_TIMEOUT).

pull_and_push([]) -> ok;
pull_and_push(Nodes) ->
    ?MODULE ! {pull_and_push, Nodes}.

%
% Privates
%

schedule_config_sync() ->
    Frequency = 5000 + trunc(random:uniform() * 55000),
    timer:send_after(Frequency, self(), sync_random).

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
    LocalKVList = ns_config:get_kv_list(),
    NewKVList = ns_config:merge_kv_pairs(RemoteKVList, LocalKVList),
    case NewKVList =:= LocalKVList of
        true ->
            ok;
        _ ->
            case ns_config:cas_config(NewKVList, LocalKVList) of
                true ->
                    ok;
                _ ->
                    ?log_warning("config cas failed. Retrying", []),
                    do_merge(RemoteKVList)
            end
    end.

get_remote(Node, Timeout) ->
    hd(misc:parallel_map(fun (_) ->
                                 Blob = gen_server:call({ns_config_remote, Node},
                                                        get_compressed,
                                                        Timeout),
                                 binary_to_term(zlib:uncompress(Blob))
                         end, [Node], Timeout)).
