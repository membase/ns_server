% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved

%
% ns_config_rep is a server responsible for all things configuration
% synch related.
%

-module(ns_config_rep).

-behaviour(gen_server).

% How to launch the thing.
-export([start_link/0]).

% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% API
-export([push/0, push/1, pull/1, pull/0]).

-record(state, {}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    % Start with startup config sync.
    error_logger:info_msg("~p init pulling~n", [?MODULE]),
    do_pull(),
    error_logger:info_msg("~p init pushing~n", [?MODULE]),
    do_push(),
    % Have ns_config reannouce its config for any synchronization that
    % may have occurred.
    error_logger:info_msg("~p init reannouncing~n", [?MODULE]),
    ns_config:reannounce(),
    % Schedule some random config syncs.
    schedule_config_sync(),
    ok = ns_node_disco_rep_events:add_handler(),
    {ok, #state{}}.

handle_call({push, List}, _From, State) ->
    error_logger:info_msg("Pushing config~n"),
    do_push(List),
    error_logger:info_msg("Pushing config done~n"),
    {reply, ok, State};
handle_call(Msg, _From, State) ->
    error_logger:info_msg("Unhandled ~p call: ~p~n", [?MODULE, Msg]),
    {reply, error, State}.

handle_cast(push, State) ->
    do_push(),
    {noreply, State};
handle_cast({pull, Nodes}, State) ->
    error_logger:info_msg("Pulling config~n"),
    do_pull(Nodes, 5),
    error_logger:info_msg("Pulling config done~n"),
    {noreply, State};
handle_cast(Msg, State) ->
    error_logger:info_msg("Unhandled ~p cast: ~p~n", [?MODULE, Msg]),
    {noreply, State}.

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
    gen_server:cast(?MODULE, push).

push(List) ->
    gen_server:call(?MODULE, {push, List}).

pull() ->
    pull(nodes()).

pull(Nodes) ->
    gen_server:cast(?MODULE, {pull, Nodes}).

%
% Privates
%

schedule_config_sync() ->
    Frequency = 5000 + trunc(random:uniform() * 55000),
    timer:send_after(Frequency, self(), sync_random).

do_push() ->
    do_push(ns_config:get_remote(node())).

do_push(RawKVList) ->
    do_push(RawKVList, ns_node_disco:nodes_actual_other()).

do_push(RawKVList, OtherNodes) ->
    misc:pmap(fun(Node) -> ns_config:set_remote(Node, RawKVList) end,
              OtherNodes, length(OtherNodes), 2000).

do_pull()  -> do_pull(5).
do_pull(N) -> do_pull(misc:shuffle(ns_node_disco:nodes_actual_other()), N).

do_pull([], _N)    -> ok;
do_pull(_Nodes, 0) -> error;
do_pull([Node | Rest], N) ->
    error_logger:info_msg("Pulling config from: ~p~n", [Node]),
    case (catch ns_config:get_remote(Node)) of
        {'EXIT', _, _} -> do_pull(Rest, N - 1);
        {'EXIT', _}    -> do_pull(Rest, N - 1);
        RemoteKVList   -> ns_config:set(RemoteKVList),
                          ok
    end.
