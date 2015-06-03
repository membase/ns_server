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

-module(ns_ssl_downstream_proxy_listener).

-include("ns_common.hrl").

%% API
-export([start_link/0, init/0]).

start_link() ->
   proc_lib:start_link(?MODULE, init, []).

init() ->
    erlang:register(?MODULE, self()),

    {ok, Port} = application:get_env(ns_ssl_proxy, downstream_port),
    {ok, CertFile} = application:get_env(ns_ssl_proxy, cert_file),
    {ok, PrivateKeyFile} = application:get_env(ns_ssl_proxy, private_key_file),
    {ok, CACertFile} = application:get_env(ns_ssl_proxy, cacert_file),

    case ssl:listen(Port,
                    [{reuseaddr, true},
                     {backlog, 100},
                     inet,
                     binary,
                     {keepalive, true},
                     {packet, raw},
                     {active, false},
                     {nodelay, true},
                     {versions, ['tlsv1', 'tlsv1.1', 'tlsv1.2']},
                     {certfile, CertFile},
                     {keyfile, PrivateKeyFile},
                     {cacertfile, CACertFile},
                     {dh, ns_ssl_services_setup:dh_params_der()}]) of
        {ok, Sock} ->
            proc_lib:init_ack({ok, self()}),
            accept_loop(Sock);
        {error, Reason} ->
            erlang:exit({listen_failed, Reason})
    end.

accept_loop(LSock) ->
    case ssl:transport_accept(LSock) of
        {ok, S} ->
            Pid = ns_ssl_proxy_server_sup:start_handler(S, downstream),
            case ssl:controlling_process(S, Pid) of
                ok -> ok;
                Err ->
                    ?log_debug("failed to set controlling process of ssl socket: ~p", [Err]),
                    ssl:close(S)
            end,
            accept_loop(LSock);
        {error, closed} ->
            exit(shutdown);
        Error ->
            exit(Error)
    end.
