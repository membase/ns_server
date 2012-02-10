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

-include("ns_common.hrl").

-define(CHECK_INTERVAL, 10000).
-define(CHECK_WARMUP_INTERVAL, 500).
-define(VBUCKET_POLL_INTERVAL, 100).
-define(TIMEOUT, 30000).
-define(CONNECTED_TIMEOUT, 5000).
%% half-second is definitely 'slow' for any definition of slow
-define(SLOW_CALL_THRESHOLD_MICROS, 500000).

%% gen_server API
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {
          timer::any(),
          status::atom(),
          start_time::tuple(),
          bucket::nonempty_string(),
          sock::port(),
          type::atom()
         }).

%% external API
-export([active_buckets/0,
         backfilling/1,
         backfilling/2,
         connected/2,
         connected/3,
         connected_buckets/0,
         connected_buckets/1,
         delete_vbucket/2, delete_vbucket/3,
         get_vbucket/3,
         host_port/1,
         host_port_str/1,
         list_vbuckets/1, list_vbuckets/2,
         list_vbuckets_prevstate/2,
         list_vbuckets_multi/2,
         set_vbucket/3, set_vbucket/4,
         server/2,
         stats/1, stats/2, stats/3,
         topkeys/1,
         raw_stats/5,
         sync_bucket_config/1,
         deregister_tap_client/2,
         flush/1,
         set/4,
         ready_nodes/4,
         sync/4, add/4, get/3, delete/3, delete/4,
         get_meta/3,
         set_with_meta/5, set_with_meta/6, set_with_meta/8,
         add_with_meta/5, add_with_meta/7,
         delete_with_meta/5, delete_with_meta/4]).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

%%
%% gen_server API implementation
%%

start_link(Bucket) ->
    %% Use proc_lib so that start_link doesn't fail if we can't
    %% connect.
    gen_server:start_link(?MODULE, Bucket, []).


%%
%% gen_server callback implementation
%%

init({Bucket, Type}) ->

    Sock = connect(),

    Timer = case Type of
        stats ->
            {ok, Tmp} = timer:send_interval(?CHECK_WARMUP_INTERVAL, check_started),
            ensure_bucket(Sock, Bucket),
            Tmp;
        _ ->
            ok = mc_client_binary:select_bucket(Sock, Bucket)
    end,

    register(server(Bucket, Type), self()),

    % this trap_exit is necessary for terminate callback to work
    process_flag(trap_exit, true),

    case Type of
        stats -> gen_event:notify(buckets_events, {started, Bucket});
        _ -> ok
    end,

    {ok, #state{
       timer=Timer,
       status=init,
       start_time=now(),
       sock=Sock,
       bucket=Bucket,
       type=Type}
    }.

handle_call(Msg, From, #state{type=stats} = State) ->
    StartTS = os:timestamp(),
    try
        do_handle_call(Msg, From, State)
    after
        EndTS = os:timestamp(),
        Diff = timer:now_diff(EndTS, StartTS),
        if
            Diff > ?SLOW_CALL_THRESHOLD_MICROS ->
                ?log_error("call ~p took too long: ~p us", [Msg, Diff]);
            true ->
                ok
        end
    end;
handle_call(Msg, From, State) ->
    do_handle_call(Msg, From, State).

do_handle_call({raw_stats, SubStat, StatsFun, StatsFunState}, _From, State) ->
    try mc_client_binary:stats(State#state.sock, SubStat, StatsFun, StatsFunState) of
        Reply ->
            {reply, Reply, State}
    catch T:E ->
            {reply, {exception, {T, E}}, State}
    end;
do_handle_call(backfilling, _From, State) ->
    End = <<":pending_backfill">>,
    ES = byte_size(End),
    {ok, Reply} = mc_client_binary:stats(
                    State#state.sock, <<"tap">>,
                    fun (<<"eq_tapq:", K/binary>>, <<"true">>, Acc) ->
                            S = byte_size(K) - ES,
                            case K of
                                <<_:S/binary, End/binary>> ->
                                    true;
                                _ ->
                                    Acc
                            end;
                        (_, _, Acc) ->
                            Acc
                    end, false),
    {reply, Reply, State};
do_handle_call({delete_vbucket, VBucket}, _From, #state{sock=Sock} = State) ->
    case mc_client_binary:delete_vbucket(Sock, VBucket) of
        ok ->
            {reply, ok, State};
        {memcached_error, einval, _} ->
            ok = mc_client_binary:set_vbucket(Sock, VBucket,
                                              dead),
            Reply = mc_client_binary:delete_vbucket(Sock, VBucket),
            {reply, Reply, State}
    end;
do_handle_call({get_vbucket, VBucket}, _From, State) ->
    Reply = mc_client_binary:get_vbucket(State#state.sock, VBucket),
    {reply, Reply, State};
do_handle_call(list_buckets, _From, State) ->
    Reply = mc_client_binary:list_buckets(State#state.sock),
    {reply, Reply, State};
do_handle_call(list_vbuckets_prevstate, _From, State) ->
    Reply = mc_client_binary:stats(
              State#state.sock, <<"prev-vbucket">>,
              fun (<<"vb_", K/binary>>, V, Acc) ->
                      [{list_to_integer(binary_to_list(K)),
                        binary_to_existing_atom(V, latin1)} | Acc]
              end, []),
    {reply, Reply, State};
do_handle_call(list_vbuckets, _From, State) ->
    Reply = mc_client_binary:stats(
              State#state.sock, <<"vbucket">>,
              fun (<<"vb_", K/binary>>, V, Acc) ->
                      [{list_to_integer(binary_to_list(K)),
                        binary_to_existing_atom(V, latin1)} | Acc]
              end, []),
    {reply, Reply, State};
do_handle_call(connected, _From, #state{status=Status} = State) ->
    {reply, Status =:= connected, State};
do_handle_call(flush, _From, State) ->
    Reply = mc_client_binary:flush(State#state.sock),
    {reply, Reply, State};

do_handle_call({delete, Key, VBucket, CAS}, _From, State) ->
    Reply = mc_client_binary:cmd(?DELETE, State#state.sock, undefined, undefined,
                                 {#mc_header{vbucket = VBucket},
                                  #mc_entry{key = Key, cas = CAS}}),
    {reply, Reply, State};

do_handle_call({delete_with_meta, Key, VBucket, Meta, CAS}, _From, State) ->
    Reply = mc_client_binary:delete_with_meta(State#state.sock,
                                              Key, VBucket, Meta, CAS),
    {reply, Reply, State};

do_handle_call({set, Key, VBucket, Val}, _From, State) ->
    Reply = mc_client_binary:cmd(?SET, State#state.sock, undefined, undefined,
                                 {#mc_header{vbucket = VBucket},
                                  #mc_entry{key = Key, data = Val}}),
    {reply, Reply, State};

do_handle_call({set_with_meta, Key, VBucket, Value, Meta, CAS, Flags, Expiration},
            _From, State) ->
    Reply = mc_client_binary:set_with_meta(State#state.sock, Key, VBucket,
                                           Value, Meta, CAS, Flags, Expiration),
    {reply, Reply, State};

do_handle_call({add, Key, VBucket, Val}, _From, State) ->
    Reply = mc_client_binary:cmd(?ADD, State#state.sock, undefined, undefined,
                                 {#mc_header{vbucket = VBucket},
                                  #mc_entry{key = Key, data = Val}}),
    {reply, Reply, State};

do_handle_call({add_with_meta, Key, VBucket, Value, Meta, Flags, Expiration},
            _From, State) ->
    Reply = mc_client_binary:add_with_meta(State#state.sock, Key, VBucket,
                                           Value, Meta, Flags, Expiration),
    {reply, Reply, State};

do_handle_call({get, Key, VBucket}, _From, State) ->
    Reply = mc_client_binary:cmd(?GET, State#state.sock, undefined, undefined,
                                 {#mc_header{vbucket = VBucket},
                                  #mc_entry{key = Key}}),
    {reply, Reply, State};

do_handle_call({get_meta, Key, VBucket}, _From, State) ->
    Reply = mc_client_binary:get_meta(State#state.sock, Key, VBucket),
    {reply, Reply, State};

do_handle_call({sync, Key, VBucket, CAS}, _From, State) ->
    {reply, mc_client_binary:sync(State#state.sock, VBucket, Key, CAS), State};

do_handle_call({set_flush_param, Key, Value}, _From, State) ->
    Reply = mc_client_binary:set_flush_param(State#state.sock, Key, Value),
    {reply, Reply, State};
do_handle_call({set_vbucket, VBucket, VBState}, _From,
            #state{sock=Sock} = State) ->
    %% This happens asynchronously, so there's no guarantee the
    %% vbucket will be in the requested state when it returns.
    Reply = mc_client_binary:set_vbucket(Sock, VBucket, VBState),
    {reply, Reply, State};
do_handle_call({stats, Key}, _From, State) ->
    Reply = mc_client_binary:stats(
              State#state.sock, Key,
              fun (K, V, Acc) ->
                      [{K, V} | Acc]
              end, []),
    {reply, Reply, State};
do_handle_call(topkeys, _From, State) ->
    Reply = mc_client_binary:stats(
              State#state.sock, <<"topkeys">>,
              fun (K, V, Acc) ->
                      VString = binary_to_list(V),
                      Tokens = string:tokens(VString, ","),
                      [{binary_to_list(K),
                        lists:map(fun (S) ->
                                          [Key, Value] = string:tokens(S, "="),
                                          {list_to_atom(Key),
                                           list_to_integer(Value)}
                                  end,
                                  Tokens)} | Acc]
              end,
              []),
    {reply, Reply, State};
do_handle_call(sync_bucket_config, _From, State) ->
    handle_info(check_config, State),
    {reply, ok, State};
do_handle_call({deregister_tap_client, TapName}, _From, State) ->
    mc_client_binary:deregister_tap_client(State#state.sock, TapName),
    {reply, ok, State};
do_handle_call(_, _From, State) ->
    {reply, unhandled, State}.


handle_cast(_, State) ->
    {noreply, State}.


handle_info(check_started, #state{status=connected} = State) ->
    {noreply, State};
handle_info(check_started, #state{timer=Timer, start_time=Start,
                                  sock=Sock, bucket=Bucket} = State) ->
    case has_started(Sock) of
        true ->
            {ok, cancel} = timer:cancel(Timer),
            ?user_log(1, "Bucket ~p loaded on node ~p in ~p seconds.",
                      [Bucket, node(), timer:now_diff(now(), Start) div 1000000]),
            gen_event:notify(buckets_events, {loaded, Bucket}),
            timer:send_interval(?CHECK_INTERVAL, check_config),
            {noreply, State#state{status=connected}};
        false ->
            {noreply, State}
    end;
handle_info(check_config, State) ->
    misc:flush(check_config),
    ensure_bucket(State#state.sock, State#state.bucket),
    {noreply, State};
handle_info({'EXIT', _, Reason} = Msg, State) ->
    ?log_info("Got ~p. Exiting.", [Msg]),
    {stop, Reason, State};
handle_info(Msg, State) ->
    ?log_info("handle_info(~p, ~p)", [Msg, State]),
    {noreply, State}.


terminate(_Reason, #state{bucket=Bucket, sock=Sock, type=data}) ->
    unregister(server(Bucket, data)),
    ok = gen_tcp:close(Sock);

terminate(Reason, #state{bucket=Bucket, sock=Sock, type=stats}) ->
    %% Unregister so nothing else tries to talk to us
    unregister(server(Bucket, stats)),
    Deleting = try ns_bucket:get_bucket(Bucket) of
                   not_present -> true;
                   {ok, _} -> false
               catch T:E ->
                       ?log_error("Failed to reach ns_bucket:get_bucket(~p). ~p:~p~n~p~n",
                                  [Bucket,T,E,erlang:get_stacktrace()]),
                       false
               end orelse try ns_config:search(i_am_a_dead_man) of
                              {value, true} -> true;
                              _ -> false
                          catch T1:E1 ->
                                  ?log_error("Failed to reach ns_config. ~p:~p~n~p~n",
                                             [T1,E1,erlang:get_stacktrace()]),
                                  false
                          end,
    if
        Reason == normal; Reason == shutdown ->
            ?user_log(2, "Shutting down bucket ~p on ~p for ~s",
                      [Bucket, node(), case Deleting of
                                           true -> "deletion";
                                           false -> "server shutdown"
                                       end]),
            try
                ok = mc_client_binary:delete_bucket(Sock, Bucket, [{force, Deleting}]),
                case Deleting of
                    true -> ns_storage_conf:delete_databases(Bucket);
                    _ -> ok
                end
            catch
                E2:R2 ->
                    ?log_error("Failed to delete bucket ~p: ~p",
                               [Bucket, {E2, R2}])
            end;
        true ->
            ?user_log(4,
                      "Control connection to memcached on ~p disconnected: ~p",
                      [node(), Reason])
    end,
    gen_event:notify(buckets_events, {stopped, Bucket, Deleting, Reason}),
    ok = gen_tcp:close(Sock),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%
%% API
%%

-spec active_buckets() -> [bucket_name()].
active_buckets() ->
    [Bucket || ?MODULE_STRING "-" ++ Bucket <-
        [atom_to_list(Name) || Name <- registered()], not is_data(Bucket)].

is_data("$data-" ++ _Name) ->
    true;
is_data(_) ->
    false.

-spec connected(node(), bucket_name(), integer() | infinity) -> boolean().
connected(Node, Bucket, Timeout) ->
    Address = {server(Bucket, stats), Node},
    try
        gen_server:call(Address, connected, Timeout)
    catch
        _:_ ->
            false
    end.

-spec connected(node(), bucket_name()) -> boolean().
connected(Node, Bucket) ->
    connected(Node, Bucket, ?CONNECTED_TIMEOUT).

-spec ready_nodes([node()], bucket_name(), up | connected, pos_integer() | infinity | default) -> [node()].
ready_nodes(Nodes, Bucket, Type, default) ->
    ready_nodes(Nodes, Bucket, Type, ?CONNECTED_TIMEOUT);
ready_nodes(Nodes, Bucket, Type, Timeout) ->
    UpNodes = ordsets:intersection(ordsets:from_list(Nodes),
                                   ordsets:from_list([node() | nodes()])),
    {Replies, _BadNodes} = gen_server:multi_call(UpNodes, server(Bucket, stats),
                                                 connected, Timeout),
    case Type of
        up ->
            [N || {N, _} <- Replies];
        connected ->
            [N || {N, true} <- Replies]
    end.

connected_buckets() ->
    connected_buckets(?CONNECTED_TIMEOUT).

connected_buckets(Timeout) ->
    lists:filter(fun (N) ->
                         connected(node(), N, Timeout)
                 end, active_buckets()).

%% @doc Send flush command to specified bucket
-spec flush(bucket_name()) -> ok.
flush(Bucket) ->
    gen_server:call({server(Bucket, stats), node()}, flush, ?TIMEOUT).


%% @doc send an add command to memcached instance
-spec add(bucket_name(), binary(), integer(), binary()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}.
add(Bucket, Key, VBucket, Value) ->
    gen_server:call({server(Bucket, data), node()},
                    {add, Key, VBucket, Value}, ?TIMEOUT).


-spec add_with_meta(bucket_name(), binary(),
                    integer(), binary(), any(), integer(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}} | mc_error() | {error, invalid_meta}.
add_with_meta(Bucket, Key, VBucket, Value, Meta, Flags, Expiration) ->
    gen_server:call({server(Bucket, data), node()},
                    {add_with_meta,
                     Key, VBucket, Value, Meta, Flags, Expiration}, ?TIMEOUT).

add_with_meta(Bucket, Key, VBucket, Value, Meta) ->
    add_with_meta(Bucket, Key, VBucket, Value, Meta, 0, 0).


%% @doc send an add command to memcached instance
-spec get(bucket_name(), binary(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}.
get(Bucket, Key, VBucket) ->
    gen_server:call({server(Bucket, data), node()}, {get, Key, VBucket}, ?TIMEOUT).


%% @doc send an get metadata command to memcached
-spec get_meta(bucket_name(), binary(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}
    | {memcached_error, key_enoent, integer()}
    | mc_error().
get_meta(Bucket, Key, VBucket) ->
    gen_server:call({server(Bucket, data), node()},
                    {get_meta, Key, VBucket}, ?TIMEOUT).


%% @doc send a set command to memcached instance
-spec delete(bucket_name(), binary(), integer(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}.
delete(Bucket, Key, VBucket, CAS) ->
    gen_server:call({server(Bucket, data), node()},
                    {delete, Key, VBucket, CAS}, ?TIMEOUT).


delete(Bucket, Key, VBucket) ->
    delete(Bucket, Key, VBucket, 0).


-spec delete_with_meta(bucket_name(), binary(), integer(), any(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}} | mc_error() | {error, invalid_meta}.
delete_with_meta(Bucket, Key, VBucket, Meta, CAS) ->
    gen_server:call({server(Bucket, data), node()},
                    {delete_with_meta, Key, VBucket, Meta, CAS}, ?TIMEOUT).


delete_with_meta(Bucket, Key, VBucket, Meta) ->
    delete_with_meta(Bucket, Key, VBucket, Meta, 0).


%% @doc send a set command to memcached instance
-spec set(bucket_name(), binary(), integer(), binary()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}.
set(Bucket, Key, VBucket, Value) ->
    gen_server:call({server(Bucket, data), node()},
                    {set, Key, VBucket, Value}, ?TIMEOUT).


-spec set_with_meta(bucket_name(), binary(), integer(), binary(), term(),
                    integer(), integer(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}} | mc_error() | {error, invalid_meta}.
set_with_meta(Bucket, Key, VBucket, Value, Meta, CAS, Flags, Expiration) ->
    gen_server:call({server(Bucket, data), node()},
                    {set_with_meta,
                     Key, VBucket, Value, Meta, CAS, Flags, Expiration},
                    ?TIMEOUT).

set_with_meta(Bucket, Key, VBucket, Value, Meta) ->
    set_with_meta(Bucket, Key, VBucket, Value, Meta, 0, 0, 0).

set_with_meta(Bucket, Key, VBucket, Value, Meta, CAS) ->
    set_with_meta(Bucket, Key, VBucket, Value, Meta, CAS, 0, 0).


%% @doc send a sync command to memcached instance
-spec sync(bucket_name(), binary(), integer(), integer()) ->
    {ok, #mc_header{}, #mc_entry{}, any()}.
sync(Bucket, Key, VBucket, CAS) ->
    gen_server:call({server(Bucket, data), node()},
                    {sync, Key, VBucket, CAS}, ?TIMEOUT * 2).


%% @doc Returns true if backfill is running on this node for the given bucket.
-spec backfilling(bucket_name()) ->
                         boolean().
backfilling(Bucket) ->
    backfilling(node(), Bucket).

%% @doc Returns true if backfill is running on the given node for the given
%% bucket.
-spec backfilling(node(), bucket_name()) ->
                         boolean().
backfilling(Node, Bucket) ->
    gen_server:call({server(Bucket, stats), Node}, backfilling, ?TIMEOUT).

%% @doc Delete a vbucket. Will set the vbucket to dead state if it
%% isn't already, blocking until it successfully does so.
-spec delete_vbucket(bucket_name(), vbucket_id()) ->
                            ok | mc_error().
delete_vbucket(Bucket, VBucket) ->
    gen_server:call(server(Bucket, stats), {delete_vbucket, VBucket}, ?TIMEOUT).


-spec delete_vbucket(node(), bucket_name(), vbucket_id()) ->
                            ok | mc_error().
delete_vbucket(Node, Bucket, VBucket) ->
    gen_server:call({server(Bucket, stats), Node}, {delete_vbucket, VBucket},
                    ?TIMEOUT).


-spec get_vbucket(node(), bucket_name(), vbucket_id()) ->
                         {ok, vbucket_state()} | mc_error().
get_vbucket(Node, Bucket, VBucket) ->
    gen_server:call({server(Bucket, stats), Node}, {get_vbucket, VBucket}, ?TIMEOUT).


-spec host_port(node()) ->
                           {nonempty_string(), pos_integer()}.
host_port(Node) ->
    Config = ns_config:get(),
    Port = ns_config:search_node_prop(Node, Config, memcached, port),
    {_Name, Host} = misc:node_name_host(Node),
    {Host, Port}.

-spec host_port_str(node()) ->
                           nonempty_string().
host_port_str(Node) ->
    {Host, Port} = host_port(Node),
    Host ++ ":" ++ integer_to_list(Port).


-spec list_vbuckets(bucket_name()) ->
    {ok, [{vbucket_id(), vbucket_state()}]} | mc_error().
list_vbuckets(Bucket) ->
    list_vbuckets(node(), Bucket).


-spec list_vbuckets(node(), bucket_name()) ->
    {ok, [{vbucket_id(), vbucket_state()}]} | mc_error().
list_vbuckets(Node, Bucket) ->
    gen_server:call({server(Bucket, stats), Node}, list_vbuckets, ?TIMEOUT).

-spec list_vbuckets_prevstate(node(), bucket_name()) ->
    {ok, [{vbucket_id(), vbucket_state()}]} | mc_error().
list_vbuckets_prevstate(Node, Bucket) ->
    gen_server:call({server(Bucket, stats), Node}, list_vbuckets_prevstate, ?TIMEOUT).


-spec list_vbuckets_multi([node()], bucket_name()) ->
                                 {[{node(), {ok, [{vbucket_id(),
                                                   vbucket_state()}]}}],
                                  [node()]}.
list_vbuckets_multi(Nodes, Bucket) ->
    UpNodes = [node()|nodes()],
    {LiveNodes, DeadNodes} = lists:partition(
                               fun (Node) ->
                                       lists:member(Node, UpNodes)
                               end, Nodes),
    {Replies, Zombies} =
        gen_server:multi_call(LiveNodes, server(Bucket, stats), list_vbuckets,
                              ?TIMEOUT),
    {Replies, Zombies ++ DeadNodes}.


-spec set_vbucket(bucket_name(), vbucket_id(), vbucket_state()) ->
                         ok | mc_error().
set_vbucket(Bucket, VBucket, VBState) ->
    gen_server:call(server(Bucket, stats), {set_vbucket, VBucket, VBState}, ?TIMEOUT).


-spec set_vbucket(node(), bucket_name(), vbucket_id(), vbucket_state()) ->
                         ok | mc_error().
set_vbucket(Node, Bucket, VBucket, VBState) ->
    gen_server:call({server(Bucket, stats), Node}, {set_vbucket, VBucket, VBState},
                    ?TIMEOUT).


-spec stats(bucket_name()) ->
                   {ok, [{binary(), binary()}]} | mc_error().
stats(Bucket) ->
    stats(Bucket, <<>>).


-spec stats(bucket_name(), binary() | string()) ->
                   {ok, [{binary(), binary()}]} | mc_error().
stats(Bucket, Key) ->
    gen_server:call(server(Bucket, stats), {stats, Key}, ?TIMEOUT).


-spec stats(node(), bucket_name(), binary()) ->
                   {ok, [{binary(), binary()}]} | mc_error().
stats(Node, Bucket, Key) ->
    gen_server:call({server(Bucket, stats), Node}, {stats, Key}, ?TIMEOUT).

sync_bucket_config(Bucket) ->
    gen_server:call(server(Bucket, stats), sync_bucket_config, ?TIMEOUT).

-spec deregister_tap_client(Bucket::bucket_name(),
                            TapName::binary()) -> ok.
deregister_tap_client(Bucket, TapName) ->
    gen_server:call(server(Bucket, stats), {deregister_tap_client, TapName}).


-spec topkeys(bucket_name()) ->
                     {ok, [{nonempty_string(), [{atom(), integer()}]}]} |
                     mc_error().
topkeys(Bucket) ->
    gen_server:call(server(Bucket, stats), topkeys, ?TIMEOUT).


-spec raw_stats(node(), bucket_name(), binary(), fun(), any()) -> {ok, any()} | {exception, any()} | {error, any()}.
raw_stats(Node, Bucket, SubStats, Fn, FnState) ->
    gen_server:call({ns_memcached:server(Bucket, stats), Node},
                    {raw_stats, SubStats, Fn, FnState}).


%%
%% Internal functions
%%

connect() ->
    Config = ns_config:get(),
    Port = ns_config:search_node_prop(Config, memcached, port),
    User = ns_config:search_node_prop(Config, memcached, admin_user),
    Pass = ns_config:search_node_prop(Config, memcached, admin_pass),
    try
        {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, 0},
                                                         {active, false}]),
        ok = mc_client_binary:auth(S, {<<"PLAIN">>,
                                       {list_to_binary(User),
                                        list_to_binary(Pass)}}),
        S of
        Sock -> Sock
    catch
        E:R ->
            ?log_warning("Unable to connect: ~p, retrying.", [{E, R}]),
            timer:sleep(1000), % Avoid reconnecting too fast.
            connect()
    end.


ensure_bucket(Sock, Bucket) ->
    try ns_bucket:config_string(Bucket) of
        {Engine, ConfigString, BucketType, ExtraParams} ->
            case mc_client_binary:select_bucket(Sock, Bucket) of
                ok ->
                    ensure_bucket_config(Sock, Bucket, BucketType, ExtraParams);
                {memcached_error, key_enoent, _} ->
                    case mc_client_binary:create_bucket(Sock, Bucket, Engine,
                                                        ConfigString) of
                        ok ->
                            ?log_info("Created bucket ~p with config string ~p",
                                      [Bucket, ConfigString]),
                            ok = mc_client_binary:select_bucket(Sock, Bucket);
                        {memcached_error, key_eexists, <<"Bucket exists: stopping">>} ->
                            %% Waiting for an old bucket with this name to shut down
                            ?log_info("Waiting for ~p to finish shutting down before we start it.",
                                      [Bucket]),
                            timer:sleep(1000),
                            ensure_bucket(Sock, Bucket);
                        Error ->
                            {error, {bucket_create_error, Error}}
                    end;
                Error ->
                    {error, {bucket_select_error, Error}}
            end
    catch
        E:R ->
            ?log_error("Unable to get config for bucket ~p: ~p",
                       [Bucket, {E, R, erlang:get_stacktrace()}]),
            {E, R}
    end.


-spec ensure_bucket_config(port(), bucket_name(), bucket_type(),
                           {pos_integer(), nonempty_string()}) ->
                                  ok | no_return().
ensure_bucket_config(Sock, Bucket, membase, {MaxSize, DBDir}) ->
    MaxSizeBin = list_to_binary(integer_to_list(MaxSize)),
    DBDirBin = list_to_binary(DBDir),
    {ok, {ActualMaxSizeBin,
          ActualDBDirBin}} = mc_client_binary:stats(
                               Sock, <<>>,
                               fun (<<"ep_max_data_size">>, V, {_, Path}) ->
                                       {V, Path};
                                   (<<"ep_dbname">>, V, {S, _}) ->
                                       {S, V};
                                   (_, _, CD) ->
                                       CD
                               end, {missing_max_size, missing_path}),
    case ActualMaxSizeBin of
        MaxSizeBin ->
            ok;
        X1 when is_binary(X1) ->
            ?log_info("Changing max_size of ~p from ~s to ~s", [Bucket, X1,
                                                                MaxSizeBin]),
            mc_client_binary:set_flush_param(Sock, <<"max_size">>, MaxSizeBin)
    end,
    case ActualDBDirBin of
        DBDirBin ->
            ok;
        X2 when is_binary(X2) ->
            ?log_info("Changing dbname of ~p from ~s to ~s", [Bucket, X2,
                                                              DBDirBin]),
            %% Just exit; this will delete and recreate the bucket
            exit(normal)
    end;
ensure_bucket_config(Sock, _Bucket, memcached, _MaxSize) ->
    %% TODO: change max size of memcached bucket also
    %% Make sure it's a memcached bucket
    {ok, present} = mc_client_binary:stats(
                      Sock, <<>>,
                      fun (<<"evictions">>, _, _) ->
                              present;
                          (_, _, CD) ->
                              CD
                      end, not_present),
    ok.


server(Bucket, data) ->
    list_to_atom(?MODULE_STRING ++ "-$data-" ++ Bucket);
server(Bucket, stats) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

has_started(Sock) ->
    Fun = fun (<<"ep_warmup_thread">>, V, _) -> V;
              (_, _, CD) -> CD
          end,
    case mc_client_binary:stats(Sock, <<>>, Fun, missing_stat) of
        {ok, <<"complete">>} ->
            true;
        {ok, missing_stat} ->
            true;
        {ok, _} ->
            false
    end.
