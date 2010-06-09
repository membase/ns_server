%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% This module lets you treat a memcached process as a gen_server.
%% Right now we have one of these registered per node, which stays
%% connected to the local memcached server as the admin user. All
%% communication with that memcached server is expected to pass
%% through distributed erlang, not using memcached prototocol over the
%% LAN.


-module(ns_memcached).

-behaviour(gen_server).

%% gen_server API
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {sock}).

%% external API
-export([create_bucket/3, delete_bucket/2, list_buckets/1, stats/2,
         stats/3, topkeys/2]).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

%% gen_server API implementation

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% gen_server callback implementation

init([]) ->
    % TODO: hostname and port need to come from the config
    Config = ns_config:get(),
    Username = ns_config:search_prop(Config, bucket_admin, user),
    Password = ns_config:search_prop(Config, bucket_admin, pass),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", 11212, [binary, {packet, 0}, {active, false}], 5000),
    ok = mc_client_binary:auth(Sock, {<<"PLAIN">>, {Username, Password}}),
    {ok, #state{sock=Sock}}.

handle_call(list_buckets, _From, State) ->
    Reply = mc_client_binary:list_buckets(State#state.sock),
    {reply, Reply, State};
handle_call({create_bucket, Bucket, Config}, _From, State) ->
    Reply = mc_client_binary:create_bucket(State#state.sock, Bucket, Config),
    {reply, Reply, State};
handle_call({delete_bucket, Bucket}, _From, State) ->
    Reply = mc_client_binary:delete_bucket(State#state.sock, Bucket),
    {reply, Reply, State};
handle_call({stats, Bucket, Key}, _From, State) ->
    Reply = do_in_bucket(State#state.sock, Bucket,
                         fun () ->
                                 mc_client_binary:stats(State#state.sock, Key)
                         end),
    {reply, Reply, State};
handle_call({topkeys, Bucket}, _From, State) ->
    Reply = do_in_bucket(State#state.sock, Bucket,
                         fun () ->
                                 mc_client_binary:topkeys(State#state.sock)
                         end),
    {reply, Reply, State};
handle_call(Request, From, State) ->
    error_logger:error_msg("~p:handle_call(~p, ~p, ~p)~n",
                           [?MODULE, Request, From, State]),
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(Msg, State) ->
    error_logger:error_msg("~p:handle_cast(~p, ~p)~n",
                           [?MODULE, Msg, State]),
    {noreply, State}.

handle_info(Msg, State) ->
    error_logger:error_msg("~p:handle_info(~p, ~p)~n",
                           [?MODULE, Msg, State]),
    {noreply, State}.

terminate(Reason, State) ->
    error_logger:error_msg("~p:terminate(~p, ~p)~n",
                           [?MODULE, Reason, State]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% External API

create_bucket(Node, Bucket, Config) ->
    gen_server:call({?MODULE, Node}, {create_bucket, Bucket, Config}).

delete_bucket(Node, Bucket) ->
    gen_server:call({?MODULE, Node}, {delete_bucket, Bucket}).

list_buckets(Node) ->
    gen_server:call({?MODULE, Node}, list_buckets).

stats(Node, Bucket) ->
    gen_server:call({?MODULE, Node}, {stats, Bucket, ""}).

stats(Node, Bucket, Key) ->
    gen_server:call({?MODULE, Node}, {stats, Bucket, Key}).

topkeys(Node, Bucket) ->
    gen_server:call({?MODULE, Node}, {topkeys, Bucket}).


%% Internal functions

do_in_bucket(Sock, Bucket, Fun) ->
    case mc_client_binary:select_bucket(Sock, Bucket) of
        ok ->
            Fun();
        R ->
            R
    end.
