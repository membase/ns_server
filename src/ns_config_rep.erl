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

-define(PULL_TIMEOUT, 10000).
-define(SELF_PULL_TIMEOUT, 30000).

% How to launch the thing.
-export([start_link/0]).

% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% API
-export([push/0, initiate_changes_push/1, synchronize/0, pull_and_push/1]).

-record(state, {}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    % Start with startup config sync.
    error_logger:info_msg("~p init pulling~n", [?MODULE]),
    do_pull(),
    error_logger:info_msg("~p init pushing~n", [?MODULE]),
    do_push(),
    % Have ns_config reannounce its config for any synchronization that
    % may have occurred.
    error_logger:info_msg("~p init reannouncing~n", [?MODULE]),
    ns_config:reannounce(),
    % Schedule some random config syncs.
    schedule_config_sync(),
    ok = ns_node_disco_rep_events:add_sup_handler(),
    {ok, #state{}}.

handle_call(synchronize, _From, State) ->
    {reply, ok, State};
handle_call(Msg, _From, State) ->
    error_logger:info_msg("Unhandled ~p call: ~p~n", [?MODULE, Msg]),
    {reply, error, State}.

handle_cast(_Msg, State)       -> {noreply, State}.

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
    error_logger:info_msg("Pushing config~n"),
    do_push(accumulate_kv_pushes(List)),
    error_logger:info_msg("Pushing config done~n"),
    {noreply, State};
handle_info({pull_and_push, Nodes}, State) ->
    error_logger:info_msg("Replicating config to/from: ~p", [Nodes]),
    FinalNodes = accumulate_pull_and_push(Nodes),
    do_pull(FinalNodes, length(FinalNodes)),
    RawKVList = ns_config:get_remote(node(), ?SELF_PULL_TIMEOUT),
    do_push(RawKVList, FinalNodes),
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
    error_logger:info_msg("Unhandled ~p msg: ~p~n", [?MODULE, Msg]),
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
    gen_server:call(?MODULE, synchronize).

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
    do_push(ns_config:get_remote(node(), ?SELF_PULL_TIMEOUT)).

do_push(RawKVList) ->
    do_push(RawKVList, ns_node_disco:nodes_actual_other()).

do_push(RawKVList, OtherNodes) ->
    misc:parallel_map(fun(Node) -> ns_config:merge_remote(Node, RawKVList) end,
                      OtherNodes, 2000).

do_pull()  -> do_pull(5).
do_pull(N) -> do_pull(misc:shuffle(ns_node_disco:nodes_actual_other()), N).

do_pull([], _N)    -> ok;
do_pull(_Nodes, 0) -> error;
do_pull([Node | Rest], N) ->
    error_logger:info_msg("Pulling config from: ~p~n", [Node]),
    case (catch ns_config:get_remote(Node, ?PULL_TIMEOUT)) of
        {'EXIT', _, _} -> do_pull(Rest, N - 1);
        {'EXIT', _}    -> do_pull(Rest, N - 1);
        RemoteKVList   -> ns_config:merge(RemoteKVList),
                          ok
    end.
