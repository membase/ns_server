%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

-module(ns_cluster).

-behaviour(gen_server).

-export([start_link/0, init/1, handle_cast/2, handle_call/3, handle_info/2,
         terminate/2, code_change/3]).

%% API
-export([join/2, leave/1, leave/0]).

-record(state, {child, action}).

%% gen_server handlers
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    {ok, Pid} = ns_server_sup:start_link(),
    {ok, #state{child=Pid, action=undefined}}.

handle_call(Request, _From, State) ->
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast({join, RemoteNode, NewCookie}, State = #state{child=Pid, action=undefined}) ->
    error_logger:info_msg("ns_cluster: joining cluster.~n"),
    ns_config:set(nodes_wanted, [node(), RemoteNode]),
    ns_config:set(otp, [{cookie, NewCookie}]),
    true = exit(Pid, shutdown),
    {noreply, State#state{action={join, RemoteNode, NewCookie}}};

handle_cast(leave, State = #state{child=Pid, action=undefined}) ->
    ns_log:log(?MODULE, 0001, "leaving cluster"),
    NewCookie = ns_node_disco:cookie_gen(),
    true = erlang:set_cookie(node(), NewCookie),
    lists:foreach(fun erlang:disconnect_node/1, nodes()),
    ns_config:set(nodes_wanted, [node()]),
    ns_config:set(otp, [{cookie, NewCookie}]),
    true = exit(Pid, shutdown),
    {noreply, State#state{action=leave}};

handle_cast(Msg, State) ->
    error_logger:info_msg("ns_cluster: got unexpected cast ~p in state ~p~n",
                              [Msg, State]),
    {noreply, State}.

handle_info({'EXIT', Pid, shutdown},
            #state{child=Pid, action={join, RemoteNode, NewCookie}}) ->
    error_logger:info_msg("ns_cluster: joining cluster. Child has exited.~n"),
    true = erlang:set_cookie(node(), NewCookie),
    true = erlang:set_cookie(RemoteNode, NewCookie),
    {ok, State} = init([]),
    {noreply, State};
handle_info({'EXIT', Pid, shutdown},
            #state{child=Pid, action=leave}) ->
    error_logger:info_msg("ns_cluster: leaving cluster~n"),
    {ok, State} = init([]),
    {noreply, State};
handle_info({'EXIT', _Pid, Reason}, State) ->
    error_logger:error_report("ns_cluster: got exit ~p in state ~p.~n",
                              [Reason, State]),
    {stop, Reason, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) -> ok.

%% API
join(RemoteNode, NewCookie) ->
    gen_server:cast(?MODULE, {join, RemoteNode, NewCookie}).

% Should be invoked on a node that remains in the cluster,
% where the leaving RemoteNode is passed in as an argument.
%
leave(RemoteNode) ->
    Result = (catch(rpc:call(RemoteNode, ?MODULE, leave, [], 500))),
    error_logger:info_msg("ns_cluster: result of calling leave on ~p: ~p~n",
                          [RemoteNode, Result]),
    NewWanted = lists:subtract(ns_node_disco:nodes_wanted(), [RemoteNode]),
    ns_config:set(nodes_wanted, NewWanted),
    % TODO: Do we need to reset our cluster's cookie, so that the
    % removed remote node, which might be down and not have received
    % our leave command, and which therefore still knows our cluster's
    % cookie, cannot re-join?
    erlang:disconnect_node(RemoteNode),
    ok.

leave() ->
    error_logger:info_msg("ns_cluster: we've been asked to leave the cluster.~n"),
    gen_server:cast(?MODULE, leave).

