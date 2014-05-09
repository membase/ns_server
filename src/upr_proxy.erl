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

-export([start_link/6, maybe_connect/1, connect_proxies/2, nuke_connection/4]).

-export([get_socket/1, get_partner/1]).

-record(state, {sock = undefined :: port() | undefined,
                connect_info,
                buf = <<>> :: binary(),
                ext_module,
                ext_state,
                proxy_to = undefined :: port() | undefined,
                partner = undefined :: pid() | undefined
               }).

-define(HIBERNATE_TIMEOUT, 10000).

init([Type, ConnName, Node, Bucket, ExtModule, InitArgs]) ->
    erlang:process_flag(trap_exit, true),

    {ExtState, State} = ExtModule:init(
                          InitArgs,
                          #state{connect_info = {Type, ConnName, Node, Bucket},
                                 ext_module = ExtModule}),

    {ok, State#state{
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

handle_cast({setup_proxy, Partner, ProxyTo}, State) ->
    {noreply, State#state{proxy_to = ProxyTo, partner = Partner}, ?HIBERNATE_TIMEOUT};
handle_cast(Msg, State = #state{ext_module = ExtModule, ext_state = ExtState}) ->
    {noreply, NewExtState, NewState} = ExtModule:handle_cast(Msg, ExtState, State),
    {noreply, NewState#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT}.

terminate(_Reason, #state{sock = undefined}) ->
    ok;
terminate(_Reason, #state{sock = Sock}) ->
    ?log_debug("Terminating. Disconnecting from socket ~p", [Sock]),
    disconnect(Sock).

handle_info({tcp, Socket, Data}, #state{sock = Socket} = State) ->
    %% Set up the socket to receive another message
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, mc_replication:process_data(Data, #state.buf,
                                          fun handle_packet/2, State), ?HIBERNATE_TIMEOUT};

handle_info({tcp_closed, Socket}, State) ->
    ?log_debug("Socket ~p was closed. Closing myself. State = ~p", [Socket, State]),
    {stop, normal, State};

handle_info({'EXIT', _Pid, _Reason} = ExitSignal, State) ->
    ?log_error("killing myself due to exit signal: ~p", [ExitSignal]),
    {stop, {got_exit, ExitSignal}, State};

handle_info(timeout, State) ->
    {noreply, State, hibernate};

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

handle_packet(<<Magick:8, Opcode:8, _Rest/binary>> = Packet,
              State = #state{ext_module = ExtModule, ext_state = ExtState, proxy_to = ProxyTo}) ->
    case suppress_logging(Packet) of
        true ->
            ok;
        false ->
            ?log_debug("Proxy packet: ~s", [upr_commands:format_packet_nicely(Packet)])
    end,

    Type = case Magick of
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
    {ok, NewState#state{ext_state = NewExtState}}.

suppress_logging(<<?REQ_MAGIC:8, ?UPR_MUTATION:8, _Rest/binary>>) ->
    true;
suppress_logging(<<?REQ_MAGIC:8, ?UPR_DELETION:8, _Rest/binary>>) ->
    true;
suppress_logging(<<?REQ_MAGIC:8, ?UPR_SNAPSHOT_MARKER, _Rest/binary>>) ->
    true;
suppress_logging(<<?RES_MAGIC:8, ?UPR_MUTATION:8, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
suppress_logging(<<?RES_MAGIC:8, ?UPR_DELETION:8, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
suppress_logging(<<?RES_MAGIC:8, ?UPR_SNAPSHOT_MARKER:8, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
suppress_logging(_) ->
    false.

maybe_connect(#state{sock = undefined,
                     connect_info = {Type, ConnName, Node, Bucket}} = State) ->
    Sock = connect(Type, ConnName, Node, Bucket),

    % setup socket to receive the first message
    ok = inet:setopts(Sock, [{active, once}]),

    State#state{sock = Sock};
maybe_connect(State) ->
    State.

connect(Type, ConnName, Node, Bucket) ->
    Username = ns_config:search_node_prop(Node, 'latest-config-marker', memcached, admin_user),
    Password = ns_config:search_node_prop(Node, 'latest-config-marker', memcached, admin_pass),

    Sock = mc_replication:connect({ns_memcached:host_port(Node), Username, Password, Bucket}),
    ok = upr_commands:open_connection(Sock, ConnName, Type),
    Sock.

disconnect(Sock) ->
    gen_tcp:close(Sock).

nuke_connection(Type, ConnName, Node, Bucket) ->
    ?log_debug("Nuke UPR connection ~p type ~p on node ~p", [ConnName, Type, Node]),
    disconnect(connect(Type, ConnName, Node, Bucket)).

connect_proxies(Pid1, Pid2) ->
    gen_server:cast(Pid1, {setup_proxy, Pid2, gen_server:call(Pid2, get_socket, infinity)}),
    gen_server:cast(Pid2, {setup_proxy, Pid1, gen_server:call(Pid1, get_socket, infinity)}).
