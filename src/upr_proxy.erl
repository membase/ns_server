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

-export([start_link/6, connect_proxies/2, nuke_connection/4]).

-export([get_socket/1, get_partner/1]).

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
    ?rebalance_info("Terminating. Disconnecting from socket ~p", [State#state.sock]),
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
-define(print_proxied_packet(X), ?rebalance_info("Proxy packet: ~s",
                                                 [upr_commands:format_packet_nicely(Packet)])).
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
            ?rebalance_warning("Received error response: ~s",
                               [upr_commands:format_packet_nicely(Packet)])
    end,
    handle_packet(response, Opcode, Packet, State).

connect(Type, ConnName, Node, Bucket) ->
    {Username, Password} = ns_bucket:credentials(Bucket),

    Sock = mc_replication:connect(ns_memcached:host_port(Node), Username, Password),
    ok = upr_commands:open_connection(Sock, ConnName, Type),
    Sock.

disconnect(Sock) ->
    gen_tcp:close(Sock).

nuke_connection(Type, ConnName, Node, Bucket) ->
    ?log_info("Nuke UPR connection ~p type ~p on node ~p", [ConnName, Type, Node]),
    disconnect(connect(Type, ConnName, Node, Bucket)).

connect_proxies(Pid1, Pid2) ->
    gen_server:cast(Pid1, {setup_proxy, Pid2, gen_server:call(Pid2, get_socket, infinity)}),
    gen_server:cast(Pid2, {setup_proxy, Pid1, gen_server:call(Pid1, get_socket, infinity)}).
