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
-export([create_bucket/2, create_bucket/3,
         delete_bucket/1, delete_bucket/2,
         list_buckets/0, list_buckets/1,
         list_vbuckets/1, list_vbuckets/2,
         list_vbuckets_multi/2,
         set_vbucket_state/3, set_vbucket_state/4,
         stats/1, stats/2, stats/3,
         stats_multi/2, stats_multi/3,
         topkeys/1, topkeys/2]).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

%% gen_server API implementation

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% gen_server callback implementation

init([]) ->
    Config = ns_config:get(),
    Username = ns_config:search_prop(Config, memcached, admin_user),
    Password = ns_config:search_prop(Config, memcached, admin_pass),
    Port = ns_config:search_prop(Config, memcached, port),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, 0}, {active, false}], 5000),
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
handle_call({set_vbucket_state, Bucket, VBucket, VBState}, _From, State) ->
    Reply = do_in_bucket(State#state.sock, Bucket,
                         fun() ->
                                 mc_client_binary:set_vbucket_state(State#state.sock, VBucket,
                                                                    atom_to_list(VBState))
                         end),
    {reply, Reply, State};
handle_call({stats, Bucket, Key}, _From, State) ->
    Reply = do_in_bucket(State#state.sock, Bucket,
                         fun () ->
                                 mc_client_binary:stats(State#state.sock, Key)
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

create_bucket(Bucket, Config) ->
    create_bucket(node(), Bucket, Config).

create_bucket(Node, Bucket, Config) ->
    gen_server:call({?MODULE, Node}, {create_bucket, Bucket, Config}).

delete_bucket(Bucket) ->
    delete_bucket(node(), Bucket).

delete_bucket(Node, Bucket) ->
    gen_server:call({?MODULE, Node}, {delete_bucket, Bucket}).

list_buckets() ->
    list_buckets(node()).

list_buckets(Node) ->
    gen_server:call({?MODULE, Node}, list_buckets).

list_vbuckets(Bucket) ->
    list_vbuckets(node(), Bucket).

list_vbuckets(Node, Bucket) ->
    case stats(Node, Bucket, "vbucket") of
        {ok, Stats} ->
            parse_vbuckets(Stats);
        Response -> Response
    end.

list_vbuckets_multi(Nodes, Bucket) ->
    process_multi(fun parse_vbuckets/1, stats_multi(Nodes, Bucket, "vbucket")).

set_vbucket_state(Bucket, VBucket, VBState) ->
    set_vbucket_state(node(), Bucket, VBucket, VBState).

set_vbucket_state(Node, Bucket, VBucket, VBState) ->
    gen_server:call({?MODULE, Node}, {set_vbucket_state, Bucket, VBucket, VBState}).

stats(Bucket) ->
    stats(node(), Bucket).

stats(Bucket, Key) when is_list(Bucket) ->
    stats(node(), Bucket, Key);
stats(Node, Bucket) ->
    gen_server:call({?MODULE, Node}, {stats, Bucket, ""}).

stats(Node, Bucket, Key) ->
    gen_server:call({?MODULE, Node}, {stats, Bucket, Key}).

stats_multi(Nodes, Bucket) ->
    gen_server:multi_call(Nodes, ?MODULE, {stats, Bucket, ""}).

stats_multi(Nodes, Bucket, Key) ->
    gen_server:multi_call(Nodes, ?MODULE, {stats, Bucket, Key}).

topkeys(Bucket) ->
    topkeys(node(), Bucket).

topkeys(Node, Bucket) ->
    case stats(Node, Bucket, "topkeys") of
        {ok, Stats} ->
            {ok, parse_topkeys(Stats)};
        Response -> Response
    end.

%% Internal functions

do_in_bucket(Sock, Bucket, Fun) ->
    case mc_client_binary:select_bucket(Sock, Bucket) of
        ok ->
            Fun();
        R ->
            R
    end.

map_vbucket_state("active") -> active;
map_vbucket_state("replica") -> replica;
map_vbucket_state("pending") -> pending;
map_vbucket_state("dead") -> dead.

parse_topkey_value(Value) ->
    Tokens = string:tokens(Value, ","),
    lists:map(fun (S) ->
                      [K, V] = string:tokens(S, "="),
                      [list_to_atom(K), list_to_integer(V)]
              end,
              Tokens).

parse_topkeys(Topkeys) ->
    lists:map(fun ([Key, ValueString]) ->
                      [Key, parse_topkey_value(ValueString)]
              end, Topkeys).

parse_vbucket_name("vb_" ++ Key) ->
    list_to_integer(Key);
parse_vbucket_name(Key) ->
    {unrecognized_vbucket, Key}.

parse_vbuckets(Stats) ->
    {ok, lists:map(fun ([Key, Value]) ->
                           {parse_vbucket_name(Key), map_vbucket_state(Value)}
                   end, Stats)}.

process_multi(Fun, {Replies, BadNodes}) ->
    ProcessedReplies = lists:map(fun ({Node, {ok, Reply}}) ->
                                         {Node, Fun(Reply)};
                                     ({Node, Response}) ->
                                         {Node, Response}
                                 end, Replies),
    {ProcessedReplies, BadNodes}.
