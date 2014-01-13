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

-module (ns_ssl_proxy_server).

-export([start_link/2, start_downstream/1, start_upstream/1]).

-export([loop_plain_to_ssl/3, loop_ssl_to_plain/3]).

-define(CONTROL_PAYLOAD_TIMEOUT, 10000).
-define(PROXY_RESPONSE_TIMEOUT, 60000).

-include("ns_common.hrl").

start_link(Socket, downstream) ->
    Pid = proc_lib:spawn_link(?MODULE, start_downstream, [Socket]),
    {ok, Pid};

start_link(Socket, upstream) ->
    Pid = proc_lib:spawn_link(?MODULE, start_upstream, [Socket]),
    {ok, Pid}.

start_upstream(Socket) ->
    KV = ns_ssl:receive_json(Socket, ?CONTROL_PAYLOAD_TIMEOUT),

    ?log_debug("Got payload: ~p", [KV]),

    Port = proplists:get_value(<<"port">>, KV),
    ProxyHost = proplists:get_value(<<"proxyHost">>, KV),
    ProxyPort = proplists:get_value(<<"proxyPort">>, KV),

    CertPem = ns_ssl:receive_binary_payload(Socket, ?CONTROL_PAYLOAD_TIMEOUT),
    VerifyOpts = ns_ssl:cert_pem_to_ssl_verify_options(CertPem),

    {ok, PlainSocket} = gen_tcp:connect(binary_to_list(ProxyHost), ProxyPort,
                                        [binary,
                                         inet,
                                         {packet, raw},
                                         {nodelay, true},
                                         {active, false}], ?PROXY_RESPONSE_TIMEOUT),
    ?log_debug("Got tcp connection"),
    %% there's no need for slow 256 bit
    %% encryption. I'm not qualified to
    %% choose between rc4-128 and
    %% aes128. And erlang prefers
    %% aes128 more (with ephemeral DH
    %% key exchange at the
    %% top). Wikipedia mentions beast
    %% attack against aes128 (and any
    %% other cbc mode ciphers). But
    %% based on limited time I've spent
    %% understanding it:
    %%
    %% a) openssl had a workaround for
    %% that for many years
    %%
    %% b) it's only useful if attacker
    %% can ask victim to send something
    %% predictable
    SSLOpts = [{ciphers, [Triple || {_E, Ci, _H} = Triple <- ssl:cipher_suites(),
                                    Ci =:= rc4_128 orelse Ci =:= aes_128_cbc]}
               | VerifyOpts],
    {ok, SSLSocket} = ssl:connect(PlainSocket, SSLOpts),

    ?log_debug("Got ssl connection"),

    send_initial_req(SSLSocket, Port),

    ?log_debug("send payload and reading reply"),

    KV2 = ns_ssl:receive_json(SSLSocket, ?CONTROL_PAYLOAD_TIMEOUT),
    <<"ok">> = proplists:get_value(<<"type">>, KV2),

    ?log_debug("Got ok reply, replying back"),

    send_reply(Socket, ok),

    erlang:process_flag(trap_exit, true),
    proc_lib:spawn_link(?MODULE, loop_plain_to_ssl, [Socket, SSLSocket, self()]),
    proc_lib:spawn_link(?MODULE, loop_ssl_to_plain, [Socket, SSLSocket, self()]),
    wait_and_close_sockets(Socket, SSLSocket).

start_downstream(SSLSocket) ->
    ?log_debug("Got downstream connect. Doing ssl_accept"),
    case ssl:ssl_accept(SSLSocket) of
        ok -> ok;
        AcceptErr ->
            ?log_debug("ssl accept failed: ~p", [AcceptErr]),
            exit(normal)
    end,

    ?log_debug("Downstream handler started on socket ~p ~n", [SSLSocket]),

    KV = ns_ssl:receive_json(SSLSocket, ?CONTROL_PAYLOAD_TIMEOUT),

    Port = proplists:get_value(<<"port">>, KV),

    ?log_debug("Got port: ~p", [Port]),

    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port,
                                   [binary,
                                    {reuseaddr, true},
                                    inet,
                                    {packet, raw},
                                    {nodelay, true},
                                    {active, false}], infinity),

    ?log_debug("Connected to final destination"),

    send_reply(SSLSocket, ok),

    ?log_debug("Replied back ok"),

    erlang:process_flag(trap_exit, true),
    proc_lib:spawn_link(?MODULE, loop_plain_to_ssl, [Socket, SSLSocket, self()]),
    proc_lib:spawn_link(?MODULE, loop_ssl_to_plain, [Socket, SSLSocket, self()]),
    wait_and_close_sockets(Socket, SSLSocket).

send_initial_req(Socket, Port) ->
    ns_ssl:send_json(Socket, {[{port, Port}]}).

send_reply(Socket, Type) ->
    ns_ssl:send_json(Socket, {[{type, Type}]}).

wait_and_close_sockets(PlainSocket, SSLSocket) ->
    receive
        {{error, closed}, PlainSocket} ->
            ?log_debug("Connection closed on socket ~p~n", [PlainSocket]),
            ssl:close(SSLSocket);
        {{error, closed}, SSLSocket} ->
            ?log_debug("Connection closed on socket ~p~n", [SSLSocket]),
            gen_tcp:close(PlainSocket);
        {{error, Reason}, Sock} ->
            ?log_error("Error ~p on socket ~p~n", [Reason, Sock]),
            ssl:close(SSLSocket),
            gen_tcp:close(PlainSocket),
            exit({error, Reason});
        {'EXIT', Pid, Reason} ->
            ?log_debug("Subprocess ~p exited with reason ~p~n", [Pid, Reason]),
            ssl:close(SSLSocket),
            gen_tcp:close(PlainSocket)
    end.

loop_plain_to_ssl(PlainSock, SSLSock, Parent) ->
    case gen_tcp:recv(PlainSock, 0) of
        {ok, Packet} ->
            case ssl:send(SSLSock, Packet) of
                ok ->
                    loop_plain_to_ssl(PlainSock, SSLSock, Parent);
                Error ->
                    Parent ! {Error, SSLSock}
            end;
        Error ->
            Parent ! {Error, PlainSock}
    end.

loop_ssl_to_plain(PlainSock, SSLSock, Parent) ->
    case ssl:recv(SSLSock, 0) of
        {ok, Packet} ->
            case gen_tcp:send(PlainSock, Packet) of
                ok ->
                    loop_ssl_to_plain(PlainSock, SSLSock, Parent);
                Error ->
                    Parent ! {Error, PlainSock}
            end;
        Error ->
            Parent ! {Error, SSLSock}
    end.
