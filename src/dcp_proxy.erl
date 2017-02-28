%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
%% @doc DCP proxy code that is common for consumer and producer sides
%%
-module(dcp_proxy).

-behaviour(gen_server).

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([start_link/6, maybe_connect/1, maybe_connect/2,
         connect_proxies/2, nuke_connection/4, terminate_and_wait/2]).

-export([get_socket/1, get_partner/1, get_conn_name/1, get_bucket/1]).

-record(state, {sock = undefined :: port() | undefined,
                connect_info,
                packet_len = undefined,
                buf = <<>> :: binary(),
                ext_module,
                ext_state,
                proxy_to = undefined :: port() | undefined,
                partner = undefined :: pid() | undefined,
                connection_alive
               }).

-define(HIBERNATE_TIMEOUT, 10000).
-define(LIVELINESS_UPDATE_INTERVAL, 1000).

init([Type, ConnName, Node, Bucket, ExtModule, InitArgs]) ->
    {ExtState, State} = ExtModule:init(
                          InitArgs,
                          #state{connect_info = {Type, ConnName, Node, Bucket},
                                 ext_module = ExtModule}),
    self() ! check_liveliness,
    {ok, State#state{
           ext_state = ExtState,
           connection_alive = false
          }, ?HIBERNATE_TIMEOUT}.

start_link(Type, ConnName, Node, Bucket, ExtModule, InitArgs) ->
    gen_server:start_link(?MODULE, [Type, ConnName, Node, Bucket, ExtModule, InitArgs], []).

get_socket(State) ->
    State#state.sock.

get_partner(State) ->
    State#state.partner.

get_conn_name(State) ->
    {_, ConnName, _, _} = State#state.connect_info,
    ConnName.

get_bucket(State) ->
    {_, _, _, Bucket} = State#state.connect_info,
    Bucket.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_cast({setup_proxy, Partner, ProxyTo}, State) ->
    {noreply, State#state{proxy_to = ProxyTo, partner = Partner}, ?HIBERNATE_TIMEOUT};
handle_cast(Msg, State = #state{ext_module = ExtModule, ext_state = ExtState}) ->
    {noreply, NewExtState, NewState} = ExtModule:handle_cast(Msg, ExtState, State),
    {noreply, NewState#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT}.

terminate(_Reason, _State) ->
    ok.

handle_info({tcp, Socket, Data}, #state{sock = Socket} = State) ->
    %% Set up the socket to receive another message
    ok = inet:setopts(Socket, [{active, once}]),

    {noreply, process_data(Data, State), ?HIBERNATE_TIMEOUT};

handle_info({tcp_closed, Socket}, State) ->
    ?log_error("Socket ~p was closed. Closing myself. State = ~p", [Socket, State]),
    {stop, socket_closed, State};

handle_info({'EXIT', _Pid, _Reason} = ExitSignal, State) ->
    ?log_error("killing myself due to exit signal: ~p", [ExitSignal]),
    {stop, {got_exit, ExitSignal}, State};

handle_info(timeout, State) ->
    {noreply, State, hibernate};

handle_info(check_liveliness, #state{connection_alive = false} = State) ->
    erlang:send_after(?LIVELINESS_UPDATE_INTERVAL, self(), check_liveliness),
    {noreply, State, ?HIBERNATE_TIMEOUT};
handle_info(check_liveliness,
            #state{connect_info = {_, _, Node, Bucket},
                   connection_alive = true} = State) ->
    %% We are not interested in the exact time of the last DCP traffic.
    %% We mainly want to know whether there was atleast one DCP message
    %% during the last LIVELINESS_UPDATE_INTERVAL.
    %% An approximate timestamp is good enough.
    %% erlang:now() can be bit expensive compared to os:timestamp().
    %% But, os:timestamp() may not be monotonic.
    %% Since this function gets called only every 1 second, should
    %% be ok to use erlang:now().
    %% Alternatively, we can also attach the timestamp in
    %% dcp_traffic_monitor:node_alive(). But, node_alive is an async operation
    %% so I prefer to attach the timestamp here.

    dcp_traffic_monitor:node_alive(Node, {Bucket, erlang:now(), self()}),
    erlang:send_after(?LIVELINESS_UPDATE_INTERVAL, self(), check_liveliness),
    {noreply, State#state{connection_alive = false}, ?HIBERNATE_TIMEOUT};

handle_info(Msg, State) ->
    ?log_warning("Unexpected handle_info(~p, ~p)", [Msg, State]),
    {noreply, State, ?HIBERNATE_TIMEOUT}.

handle_call(get_socket, _From, State = #state{sock = Sock}) ->
    {reply, Sock, State, ?HIBERNATE_TIMEOUT};
handle_call(Command, From, State = #state{ext_module = ExtModule, ext_state = ExtState}) ->
    case ExtModule:handle_call(Command, From, ExtState, State) of
        {ReplyType, Reply, NewExtState, NewState} ->
            {ReplyType, Reply, NewState#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT};
        {ReplyType, NewExtState, NewState} ->
            {ReplyType, NewState#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT}
    end.

handle_packet(<<Magic:8, Opcode:8, _Rest/binary>> = Packet,
              State = #state{ext_module = ExtModule,
                             ext_state = ExtState,
                             proxy_to = ProxyTo}) ->
    case (erlang:get(suppress_logging_for_xdcr) =:= true
          orelse suppress_logging(Packet)
          orelse not ale:is_loglevel_enabled(?NS_SERVER_LOGGER, debug)) of
        true ->
            ok;
        false ->
            ?log_debug("Proxy packet: ~s", [dcp_commands:format_packet_nicely(Packet)])
    end,

    Type = case Magic of
               ?REQ_MAGIC ->
                   request;
               ?RES_MAGIC ->
                   response
           end,
    {Action, NewExtState, NewState} = ExtModule:handle_packet(Type, Opcode, Packet, ExtState, State),
    case Action of
        proxy ->
            ok = gen_tcp:send(ProxyTo, Packet);
        block ->
            ok
    end,
    {ok, NewState#state{ext_state = NewExtState, connection_alive = true}}.

suppress_logging(<<?REQ_MAGIC:8, ?DCP_MUTATION:8, _Rest/binary>>) ->
    true;
suppress_logging(<<?REQ_MAGIC:8, ?DCP_DELETION:8, _Rest/binary>>) ->
    true;
suppress_logging(<<?REQ_MAGIC:8, ?DCP_SNAPSHOT_MARKER, _Rest/binary>>) ->
    true;
suppress_logging(<<?REQ_MAGIC:8, ?DCP_WINDOW_UPDATE, _Rest/binary>>) ->
    true;
suppress_logging(<<?RES_MAGIC:8, ?DCP_MUTATION:8, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
suppress_logging(<<?RES_MAGIC:8, ?DCP_DELETION:8, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
suppress_logging(<<?RES_MAGIC:8, ?DCP_SNAPSHOT_MARKER:8, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
%% TODO: remove this as soon as memcached stops sending these
suppress_logging(<<?RES_MAGIC:8, ?DCP_WINDOW_UPDATE, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
suppress_logging(<<_:8, ?DCP_NOP:8, _Rest/binary>>) ->
    true;
suppress_logging(_) ->
    false.

maybe_connect(State) ->
    maybe_connect(State, false).

maybe_connect(#state{sock = undefined,
                     connect_info = {Type, ConnName, Node, Bucket}} = State, XAttr) ->
    Sock = connect(Type, ConnName, Node, Bucket, XAttr),

    %% setup socket to receive the first message
    ok = inet:setopts(Sock, [{active, once}]),

    State#state{sock = Sock};
maybe_connect(State, _) ->
    State.

connect(Type, ConnName, Node, Bucket) ->
    connect(Type, ConnName, Node, Bucket, false).

connect(Type, ConnName, Node, Bucket, XAttr) ->
    Username = ns_config:search_node_prop(Node, ns_config:latest(), memcached, admin_user),
    Password = ns_config:search_node_prop(Node, ns_config:latest(), memcached, admin_pass),

    HostPort = ns_memcached:host_port(Node),
    Sock = mc_replication:connect({HostPort, Username, Password, Bucket}),

    XAttr = maybe_negotiate_xattr(Sock, XAttr),
    ok = dcp_commands:open_connection(Sock, ConnName, Type, XAttr),
    Sock.

maybe_negotiate_xattr(_Sock, false = _XAttr) ->
    false;
maybe_negotiate_xattr(Sock, true = _XAttr) ->
    %% If we are here that means that the cluster is XATTRs capable.
    %% So when we try to negotiate XATTRs we don't expect it to fail.
    {ok, true} = dcp_commands:negotiate_xattr(Sock, "proxy"),
    true.

disconnect(Sock) ->
    gen_tcp:close(Sock).

nuke_connection(Type, ConnName, Node, Bucket) ->
    ?log_debug("Nuke DCP connection ~p type ~p on node ~p", [ConnName, Type, Node]),
    disconnect(connect(Type, ConnName, Node, Bucket)).

connect_proxies(Pid1, Pid2) ->
    Sock1 = gen_server:call(Pid1, get_socket, infinity),
    Sock2 = gen_server:call(Pid2, get_socket, infinity),

    gen_server:cast(Pid1, {setup_proxy, Pid2, Sock2}),
    gen_server:cast(Pid2, {setup_proxy, Pid1, Sock1}),
    [{Pid1, Sock1}, {Pid2, Sock2}].

terminate_and_wait(normal, Pairs) ->
    misc:terminate_and_wait(normal, [Pid || {Pid, _} <- Pairs]);
terminate_and_wait(shutdown, Pairs) ->
    misc:terminate_and_wait(shutdown, [Pid || {Pid, _} <- Pairs]);
terminate_and_wait(_Reason, Pairs) ->
    [disconnect(Sock) || {_, Sock} <- Pairs],
    misc:terminate_and_wait(kill, [Pid || {Pid, _} <- Pairs]).

process_data(NewData, #state{buf = PrevData,
                             packet_len = PacketLen} = State) ->
    Data = <<PrevData/binary, NewData/binary>>,
    process_data_loop(Data, PacketLen, State).

process_data_loop(Data, undefined, State) ->
    case Data of
        <<_Magic:8, _Opcode:8, _KeyLen:16, _ExtLen:8, _DataType:8,
          _VBucket:16, BodyLen:32, _Opaque:32, _CAS:64, _Rest/binary>> ->
            process_data_loop(Data, ?HEADER_LEN + BodyLen, State);
        _ ->
            State#state{buf = Data,
                        packet_len = undefined}
    end;
process_data_loop(Data, PacketLen, State) ->
    case byte_size(Data) >= PacketLen of
        false ->
            State#state{buf = Data,
                        packet_len = PacketLen};
        true ->
            {Packet, Rest} = split_binary(Data, PacketLen),
            {ok, NewState} = handle_packet(Packet, State),
            process_data_loop(Rest, undefined, NewState)
    end.
