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
%% This module lets you treat a memcached process as a gen_server.
%% Right now we have one of these registered per node, which stays
%% connected to the local memcached server as the admin user. All
%% communication with that memcached server is expected to pass
%% through distributed erlang, not using memcached prototocol over the
%% LAN.
%%
-module(ns_memcached).

-behaviour(gen_server).

%% gen_server API
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {sock}).

%% external API
-export([connected/0, connected/1,
         create_bucket/2, create_bucket/3,
         delete_bucket/1, delete_bucket/2,
         delete_vbucket/2, delete_vbucket/3,
         host_port_str/0, host_port_str/1,
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
    self() ! connect,
    {ok, #state{}}.

handle_call(connected, _From, State) ->
    Reply = case State#state.sock of
                undefined ->
                    false;
                _ ->
                    true
            end,
    {reply, Reply, State};
handle_call({create_bucket, _Bucket, _Config}, _From, State) ->
    Reply = unimplemented,
    {reply, Reply, State};
handle_call({delete_bucket, _Bucket}, _From, State) ->
    Reply = unimplemented,
    {reply, Reply, State};
handle_call({delete_vbucket, Bucket, VBucket}, _From, State) ->
    Sock = connect(State),
    Reply = do_in_bucket(Sock, Bucket,
                        fun() ->
                                mc_client_binary:delete_vbucket(
                                  Sock, VBucket)
                        end),
    {reply, Reply, State#state{sock=Sock}};
handle_call(list_buckets, _From, State) ->
    Reply = {ok, ["default"]},
    {reply, Reply, State};
handle_call({set_vbucket_state, Bucket, VBucket, VBState}, _From, State) ->
    Sock = connect(State),
    Reply = do_in_bucket(Sock, Bucket,
                         fun() ->
                                 mc_client_binary:set_vbucket_state(
                                   Sock, VBucket,
                                   atom_to_list(VBState))
                         end),
    {reply, Reply, State#state{sock=Sock}};
handle_call({stats, Bucket, Key}, _From, State) ->
    Sock = connect(State),
    Reply = do_in_bucket(Sock, Bucket,
                         fun () ->
                                 mc_client_binary:stats(Sock, Key)
                         end),
    {reply, Reply, State#state{sock=Sock}};
handle_call(Request, From, State) ->
    error_logger:error_msg("~p:handle_call(~p, ~p, ~p)~n",
                           [?MODULE, Request, From, State]),
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(Msg, State) ->
    error_logger:error_msg("~p:handle_cast(~p, ~p)~n",
                           [?MODULE, Msg, State]),
    {noreply, State}.

handle_info(connect, State) ->
    {noreply, State#state{sock=connect(State)}};
handle_info(Msg, State) ->
    error_logger:error_msg("~p:handle_info(~p, ~p)~n",
                           [?MODULE, Msg, State]),
    {noreply, State}.

terminate(Reason, State) ->
    error_logger:error_msg("~p:terminate(~p, ~p)~n",
                           [?MODULE, Reason, State]),
    timer:sleep(2000),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% External API
connect(State) ->
    case State#state.sock of
        undefined ->
            Config = ns_config:get(),
            Port = ns_config:search_node_prop(Config, memcached, port),
            error_logger:info_msg("ns_memcached connecting to memcached on port ~p~n", [Port]),
            {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, 0}, {active, false}], 5000),
            Sock;
        Sock ->
            Sock
    end.

connected() ->
    connected(node()).

connected(Node) ->
    call(Node, connected).

create_bucket(Bucket, Config) ->
    create_bucket(node(), Bucket, Config).

create_bucket(Node, Bucket, Config) ->
    call(Node, {create_bucket, Bucket, Config}).

delete_bucket(Bucket) ->
    delete_bucket(node(), Bucket).

delete_bucket(Node, Bucket) ->
    call(Node, {delete_bucket, Bucket}).

delete_vbucket(Bucket, VBucket) ->
    delete_vbucket(node(), Bucket, VBucket).

delete_vbucket(Node, Bucket, VBucket) ->
    call(Node, {delete_vbucket, Bucket, VBucket}).

host_port_str() ->
    host_port_str(node()).

host_port_str(Node) ->
    Config = ns_config:get(),
    Port = ns_config:search_node_prop(Node, Config, memcached, port),
    {_Name, Host} = misc:node_name_host(Node),
    Host ++ ":" ++ integer_to_list(Port).

list_buckets() ->
    list_buckets(node()).

list_buckets(Node) ->
    call(Node, list_buckets).

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
    call(Node, {set_vbucket_state, Bucket, VBucket, VBState}).

stats(Bucket) ->
    stats(node(), Bucket).

stats(Bucket, Key) when is_list(Bucket) ->
    stats(node(), Bucket, Key);
stats(Node, Bucket) ->
    call(Node, {stats, Bucket, ""}).

stats(Node, Bucket, Key) ->
    call(Node, {stats, Bucket, Key}).

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
call(Node, Call) ->
    gen_server:call({?MODULE, Node}, Call).

do_in_bucket(_Sock, Bucket, Fun) ->
    %% TODO: real multi-tenancy
    case Bucket of
        "default" ->
            Fun();
        _ ->
            {memcached_error, {mc_status_key_enoent, []}}
    end.
    %% case mc_client_binary:select_bucket(Sock, Bucket) of
    %%     ok ->
    %%         Fun();
    %%     R ->
    %%         R
    %% end.

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
