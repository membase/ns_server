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
-include("mc_entry.hrl").
-include("mc_constants.hrl").

start_link(Socket, downstream) ->
    Pid = proc_lib:spawn_link(?MODULE, start_downstream, [Socket]),
    {ok, Pid};

start_link(Socket, upstream) ->
    Pid = proc_lib:spawn_link(?MODULE, start_upstream, [Socket]),
    {ok, Pid}.

start_upstream(Socket) ->
    KV = ns_ssl:receive_json(Socket, ?CONTROL_PAYLOAD_TIMEOUT),

    ?log_debug("Got payload: ~p", [KV]),

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
    SSLOpts = case os:getenv("COUCHBASE_WANT_ARCFOUR") of
                  false -> [{ciphers, [Triple || {_E, Ci, _H} = Triple <- ssl:cipher_suites(),
                                                 Ci =:= rc4_128 orelse Ci =:= aes_128_cbc]}
                            | VerifyOpts];
                  _ ->
                      [{ciphers, [Triple || {_E, Ci, _H} = Triple <- ssl:cipher_suites(),
                                            Ci =:= rc4_128]}
                       | VerifyOpts]
              end,
    {ok, SSLSocket} = ssl:connect(PlainSocket, SSLOpts),

    ?log_debug("Got ssl connection"),

    send_initial_req(SSLSocket, KV),

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


    case {proplists:get_value(<<"bucket">>, KV),
          proplists:get_value(<<"password">>, KV)} of
        {undefined, _} ->
            erlang:process_flag(trap_exit, true),
            proc_lib:spawn_link(?MODULE, loop_plain_to_ssl, [Socket, SSLSocket, self()]),
            proc_lib:spawn_link(?MODULE, loop_ssl_to_plain, [Socket, SSLSocket, self()]),
            wait_and_close_sockets(Socket, SSLSocket);
        {Bucket, Password} ->
            ?log_debug("Got bucket and password"),
            do_auth(Socket, Bucket, Password),
            inet:setopts(Socket, [{active, true}]),
            requests_loop(Socket, SSLSocket)
    end.

do_auth(Socket, Bucket, Password) ->
    AuthEntry = #mc_entry{key = <<"PLAIN">>,
                          data = <<""/binary, 0:8,
                                   Bucket/binary, 0:8,
                                   Password/binary>>},
    ok = mc_binary:send(Socket, req,
                        #mc_header{opcode = ?CMD_SASL_AUTH}, AuthEntry),
    {ok, #mc_header{status=?SUCCESS}, _} = mc_binary:recv(Socket, res, infinity),
    ok.


ssl_passive_recv(SSLSocket) ->
    ssl:setopts(SSLSocket, [{active, once}]),
    receive
        {ssl, SSLSocket, Data} ->
            Data;
        {ssl_closed, SSLSocket} ->
            closed;
        {ssl_error, Socket, Reason} ->
            ?log_debug("ssl socket (~p) error: ~p", [Socket, Reason]),
            closed
    end.

requests_loop(Socket, SSLSocket) ->
    case ssl_passive_recv(SSLSocket) of
        closed ->
            %% it'll automagically close memcached socket
            erlang:exit(normal);
        Data ->
            ok = requests_loop_with_data(Socket, SSLSocket, Data),
            requests_loop(Socket, SSLSocket)
    end.

requests_loop_with_data(Socket, SSLSocket, Data) ->
    case Data of
        <<BatchBytes:32/big, BatchReqs:32/big, RestData0/binary>> ->
            case RestData0 of
                <<>> -> ok;
                _ ->
                    %% we're sending stuff to memcached as soon as
                    %% possible to make it start handling batch as soon
                    %% as possible
                    ok = prim_inet:send(Socket, RestData0)
            end,
            %% do we have enough stuff ?
            case BatchBytes - erlang:size(RestData0) of
                0 ->
                    RestData0,
                    requests_loop_pipe_replies(Socket, SSLSocket, BatchReqs, [], <<>>);
                MoreSize when MoreSize > 0 ->
                    {ok, MoreData} = ssl:recv(SSLSocket, MoreSize),
                    ok = prim_inet:send(Socket, MoreData),
                    requests_loop_pipe_replies(Socket, SSLSocket, BatchReqs, [], <<>>);
                _ ->
                    %% somebody got multiple batches outstanding on
                    %% the wire. We don't expect it and therefore
                    %% handle it in simplest possible way
                    <<FirstBatchData:(BatchBytes)/binary, RestBatchData/binary>> = RestData0,
                    ok = prim_inet:send(Socket, FirstBatchData),
                    requests_loop_pipe_replies(Socket, SSLSocket, BatchReqs, [], <<>>),
                    requests_loop_with_data(Socket, SSLSocket, RestBatchData)
            end;
        _ ->
            %% we don't even have a header.
            case ssl_passive_recv(SSLSocket) of
                closed ->
                    ?log_warning("Got downstream ssl close before having full batch"),
                    erlang:exit(normal);
                MoreData ->
                    requests_loop_with_data(Socket, SSLSocket, <<Data/binary,MoreData/binary>>)
            end
    end.

recv_with_data(Sock, Len, Data) ->
    DataSize = erlang:size(Data),
    case DataSize >= Len of
        true ->
            RV = binary_part(Data, 0, Len),
            Rest = binary_part(Data, Len, DataSize-Len),
            {ok, RV, Rest};
        false ->
            receive
                {tcp, Sock, NewData} ->
                    recv_with_data(Sock, Len, <<Data/binary, NewData/binary>>);
                {tcp_closed, Sock} ->
                    {error, closed}
            end
    end.


requests_loop_pipe_replies(_Socket, SSLSocket, 0 = _BatchReqs, Replies, Data) ->
    {empty_data, <<>>} = {empty_data, Data},
    ok = ssl:send(SSLSocket, lists:reverse(Replies));
requests_loop_pipe_replies(Socket, SSLSocket, BatchReqs, Replies, Data) ->
    {ok, Hdr, Rest} = recv_with_data(Socket, ?HEADER_LEN, Data),
    <<?RES_MAGIC:8, _Opcode:8, KeyLen:16, ExtLen:8,
      _DataType:8, _Status:16, BodyLen:32,
      _Opaque:32, _CAS:64>> = Hdr,
    CmdLen = erlang:max(ExtLen + KeyLen, BodyLen),
    {ok, Body, BodyRest} = recv_with_data(Socket, CmdLen, Rest),
    NewReplies = [[Hdr | Body] | Replies],
    requests_loop_pipe_replies(Socket, SSLSocket,
                               BatchReqs - 1, NewReplies, BodyRest).

send_initial_req(Socket, KV) ->
    ns_ssl:send_json(Socket, {KV}).

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
