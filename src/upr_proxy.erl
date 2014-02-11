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
%% @doc UPR proxy code that is common for consumer and producer sides
%%
-module(upr_proxy).

-behaviour(gen_server).

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([start_link/6, connect_proxies/2, nuke_connection/4, process_upr_response/1]).

-export([get_socket/1, get_partner/1, upr_close_stream/2]).

-record(state, {sock :: port(),
                buf = <<>> :: binary(),
                ext_module,
                ext_state,
                proxy_to = undefined,
                partner = undefined :: pid() | undefined
               }).

-define(HIBERNATE_TIMEOUT, 10000).

init([Type, ConnName, Node, Bucket, ExtModule, InitArgs]) ->
    erlang:process_flag(trap_exit, true),
    Sock = connect(Type, ConnName, Node, Bucket),

    ExtState = ExtModule:init(InitArgs),

    {ok, #state{
            sock = Sock,
            ext_module = ExtModule,
            ext_state = ExtState
           }, ?HIBERNATE_TIMEOUT}.

start_link(Type, ConnName, Node, Bucket, ExtModule, InitArgs) ->
    gen_server:start_link(?MODULE, [Type, ConnName, Node, Bucket, ExtModule, InitArgs], []).

get_socket(State) ->
    State#state.sock.

get_partner(State) ->
    State#state.partner.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_cast({setup_proxy, Partner, ProxyTo}, #state{sock = Socket} = State) ->
    % setup socket to receive the first message
    ok = inet:setopts(Socket, [{active, once}]),

    {noreply, State#state{proxy_to = ProxyTo, partner = Partner}, ?HIBERNATE_TIMEOUT};
handle_cast(Msg, State = #state{ext_module = ExtModule, ext_state = ExtState}) ->
    {noreply, NewExtState} = ExtModule:handle_cast(Msg, ExtState, State),
    {noreply, State#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT}.

terminate(_Reason, State) ->
    disconnect(State#state.sock).

handle_info({tcp, Socket, Data}, #state{sock = Socket} = State) ->
    %% Set up the socket to receive another message
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, mc_replication:process_data(Data, #state.buf,
                                          fun process_packet/2, State), ?HIBERNATE_TIMEOUT};

handle_info({tcp_closed, Socket}, State) ->
    ?rebalance_info("Socket ~p was closed. Closing myself. State = ~p", [Socket, State]),
    {stop, normal, State};

handle_info({'EXIT', _Pid, _Reason} = ExitSignal, State) ->
    ?rebalance_error("killing myself due to exit signal: ~p", [ExitSignal]),
    {stop, {got_exit, ExitSignal}, State};

handle_info(timeout, State) ->
    {noreply, State, hibernate};

handle_info(Msg, State) ->
    ?rebalance_warning("Unexpected handle_info(~p, ~p)", [Msg, State]),
    {noreply, State, ?HIBERNATE_TIMEOUT}.

handle_call(get_socket, _From, State = #state{sock = Sock}) ->
    {reply, Sock, State, ?HIBERNATE_TIMEOUT};
handle_call(Command, From, State = #state{ext_module = ExtModule, ext_state = ExtState}) ->
    case ExtModule:handle_call(Command, From, ExtState, State) of
        {ReplyType, Reply, NewExtState} ->
            {ReplyType, Reply, State#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT};
        {ReplyType, NewExtState} ->
            {ReplyType, State#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT}
    end.

handle_packet(Type, Msg, Packet,
              State = #state{ext_module = ExtModule, ext_state = ExtState, proxy_to = ProxyTo}) ->
    {Action, NewExtState} = ExtModule:handle_packet(Type, Msg, Packet, ExtState, State),
    case Action of
        proxy ->
            ok = gen_tcp:send(ProxyTo, Packet);
        block ->
            ok
    end,
    {ok, State#state{ext_state = NewExtState}}.

-ifdef(DEBUG_UPR).
-define(print_proxied_packet(X), ?rebalance_info("Proxy packet: ~s", [format_packet_nicely(Packet)])).
-else.
-define(print_proxied_packet(X), ok).
-endif.

process_packet(<<?REQ_MAGIC:8, Opcode:8, _Rest/binary>> = Packet, State) ->
    ?print_proxied_packet(X),
    handle_packet(request, Opcode, Packet, State);
process_packet(<<?RES_MAGIC:8, Opcode:8, _KeyLen:16, _ExtLen:8,
                 _DataType:8, Status:16, _Rest/binary>> = Packet, State) ->
    case Status of
        ?SUCCESS ->
            ?print_proxied_packet(X);
        _ ->
            ?rebalance_warning("Received error response: ~s", [format_packet_nicely(Packet)])
    end,
    handle_packet(response, Opcode, Packet, State).

connect(Type, ConnName, Node, Bucket) ->
    {Username, Password} = ns_bucket:credentials(Bucket),

    Sock = mc_replication:connect(ns_memcached:host_port(Node), Username, Password),
    ok = upr_open(Sock, ConnName, Type),
    Sock.

disconnect(Sock) ->
    gen_tcp:close(Sock).

nuke_connection(Type, ConnName, Node, Bucket) ->
    disconnect(connect(Type, ConnName, Node, Bucket)).

connect_proxies(Pid1, Pid2) ->
    gen_server:cast(Pid1, {setup_proxy, Pid2, gen_server:call(Pid2, get_socket, infinity)}),
    gen_server:cast(Pid2, {setup_proxy, Pid1, gen_server:call(Pid1, get_socket, infinity)}).

process_upr_response({ok, #mc_header{status=?SUCCESS}, #mc_entry{}}) ->
    ok;
process_upr_response({ok, #mc_header{status=Status}, #mc_entry{data=Msg}}) ->
    {upr_error, mc_client_binary:map_status(Status), Msg}.

upr_open(Sock, ConnName, Type) ->
    Flags = case Type of
                consumer ->
                    <<0:32/big>>;
                producer ->
                    <<1:32/big>>
            end,
    Extra = <<0:32, Flags/binary>>,

    process_upr_response(
      mc_client_binary:cmd_vocal(?UPR_OPEN, Sock,
                                 {#mc_header{},
                                  #mc_entry{key = ConnName,ext = Extra}})).

upr_close_stream(Sock, Partition) ->
    ?rebalance_debug("Close stream for partition ~p", [Partition]),
    {ok, quiet} = mc_client_binary:cmd_quiet(?UPR_CLOSE_STREAM, Sock,
                                             {#mc_header{opaque = Partition,
                                                         vbucket = Partition},
                                              #mc_entry{}}).

upr_command_2_atom(?UPR_OPEN) ->
    upr_open;
upr_command_2_atom(?UPR_ADD_STREAM) ->
    upr_add_stream;
upr_command_2_atom(?UPR_CLOSE_STREAM) ->
    upr_close_stream;
upr_command_2_atom(?UPR_STREAM_REQ) ->
    upr_stream_req;
upr_command_2_atom(?UPR_GET_FAILOVER_LOG) ->
    upr_get_failover_log;
upr_command_2_atom(?UPR_STREAM_END) ->
    upr_stream_end;
upr_command_2_atom(?UPR_SNAPSHOT_MARKER) ->
    upr_snapshot_marker;
upr_command_2_atom(?UPR_MUTATION) ->
    upr_mutation;
upr_command_2_atom(?UPR_DELETION) ->
    upr_deletion;
upr_command_2_atom(?UPR_EXPIRATION) ->
    upr_expiration;
upr_command_2_atom(?UPR_FLUSH) ->
    upr_flush;
upr_command_2_atom(?UPR_SET_VBUCKET_STATE) ->
    upr_set_vbucket_state;
upr_command_2_atom(_) ->
    not_upr.

format_packet_nicely(<<?REQ_MAGIC:8, _Rest/binary>> = Packet) ->
    {Header, _Body} = mc_binary:decode_packet(Packet),
    format_packet_nicely("REQUEST", "", Header, Packet);
format_packet_nicely(<<?RES_MAGIC:8, _Opcode:8, _KeyLen:16, _ExtLen:8,
                       _DataType:8, Status:16, _Rest/binary>> = Packet) ->
    {Header, _Body} = mc_binary:decode_packet(Packet),
    format_packet_nicely("RESPONSE",
                         io_lib:format(" status = ~.16X (~w)",
                                       [Status, "0x", mc_client_binary:map_status(Status)]),
                         Header, Packet).

format_packet_nicely(Type, Status, Header, Packet) ->
    lists:flatten(
      io_lib:format("~s: ~.16X (~w) vbucket = ~w opaque = ~.16X~s~n~s",
                    [Type,
                     Header#mc_header.opcode, "0x",
                     upr_command_2_atom(Header#mc_header.opcode),
                     Header#mc_header.vbucket,
                     Header#mc_header.opaque, "0x",
                     Status,
                     format_hex_strings(hexlify(Packet))])).

hexlify(<<>>, Acc) ->
    Acc;
hexlify(<<Byte:8, Rest/binary>>, Acc) ->
    hexlify(Rest, [lists:flatten(io_lib:format("~2.16.0B", [Byte])) | Acc]).

hexlify(Binary) ->
    lists:reverse(hexlify(Binary, [])).

format_hex_strings([], _, Acc) ->
    Acc;
format_hex_strings([String | Rest], 3, Acc) ->
    format_hex_strings(Rest, 0, Acc ++ String ++ "\n");
format_hex_strings([String | Rest], Count, Acc) ->
    format_hex_strings(Rest, Count + 1, Acc ++ String ++ " ").

format_hex_strings(Strings) ->
    format_hex_strings(Strings, 0, "").
