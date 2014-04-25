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

-module(ns_ssl).

-export([establish_ssl_proxy_connection/7]).

-export([receive_json/2, receive_binary_payload/2, send_json/2,
         cert_pem_to_ssl_verify_options/1]).

-include("ns_common.hrl").

-define(MAX_PAYLOAD_SIZE, 10000).


%% NOTE: this is not exactly cheap, but far cheaper than rest of ssl
%% handshake in my measurements
cert_pem_to_ssl_verify_options(<<"_">>) ->
    [];
cert_pem_to_ssl_verify_options(CertPEM) ->
    [{'Certificate', CertDer, _}] = public_key:pem_decode(CertPEM),
    CertObj = public_key:pkix_decode_cert(CertDer, otp),
    [{verify, verify_peer},
     {verify_fun, {fun verify_fun/3, CertObj}},
     %% cacerts allows us to pass verification if cert is CA cert
     %% that's included in server's handshake response. Which enables
     %% us to do that in future
     %%
     %% otherwise erlang complains about "unknown ca"
     {cacerts, [CertDer]}].

verify_fun(Cert, Event, Etalon) ->
    Resp = case Event of
               {bad_cert, selfsigned_peer} ->
                   case Cert of
                       Etalon ->
                           {valid, Etalon};
                       _ ->
                           {fail, {bad_cert, unrecognized}}
                   end;
               {bad_cert, _} ->
                   {fail, Event};
               {extension, _} ->
                   {unknown, Event};
               valid ->
                   {valid, Etalon};
               valid_peer ->
                   {valid, Etalon}
           end,
    case Resp of
        {valid, _} ->
            Resp;
        _ ->
            ?log_error("Certificate validation failed with reason ~p~n", [Resp]),
            Resp
    end.

establish_ssl_proxy_connection(Socket, Host, Port, ProxyPort, CertPEM, Bucket, Password) ->
    Payload0 = [{proxyHost, list_to_binary(Host)},
                {proxyPort, ProxyPort},
                {port, Port}],
    Payload = case Bucket of
                  undefined ->
                      Payload0;
                  _ ->
                      [{bucket, list_to_binary(Bucket)},
                       {password, list_to_binary(Password)}
                       | Payload0]
              end,
    send_json(Socket, {Payload}),
    send_cert(Socket, CertPEM),
    Reply = receive_json(Socket, infinity),
    <<"ok">> = proplists:get_value(<<"type">>, Reply),
    ok.

recv(Socket, Size, Timeout) ->
    case is_port(Socket) of
        true ->
            gen_tcp:recv(Socket, Size, Timeout);
        _ ->
            ssl:recv(Socket, Size, Timeout)
    end.

send(Socket, IOList) ->
    case is_port(Socket) of
        true ->
            gen_tcp:send(Socket, IOList);
        _ ->
            ssl:send(Socket, IOList)
    end.

send_cert(Socket, CertPEM) ->
    ok = send(Socket, [<<(erlang:size(CertPEM)):32/big>> | CertPEM]).

receive_binary_payload(Socket, Timeout) ->
    {ok, <<Size:32>>} = recv(Socket, 4, Timeout),
    if
        Size > ?MAX_PAYLOAD_SIZE ->
            ?log_error("Received invalid payload size ~p~n", [Size]),
            throw(invalid_size);
        true ->
            ok
    end,
    {ok, Payload} = recv(Socket, Size, Timeout),
    Payload.

receive_json(Socket, Timeout) ->
    {KV} = ejson:decode(receive_binary_payload(Socket, Timeout)),
    KV.

send_json(Socket, Json) ->
    ReqPayload = ejson:encode(Json),
    FullReqPayload = [<<(erlang:size(ReqPayload)):32/big>> | ReqPayload],
    ok = send(Socket, FullReqPayload).
