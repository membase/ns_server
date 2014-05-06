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

-module(ns_ssl_upstream_proxy_listener).

-include("ns_common.hrl").

%% API
-export([start_link/0, init/0]).

start_link() ->
   proc_lib:start_link(?MODULE, init, []).

init() ->
    erlang:register(?MODULE, self()),

    {ok, Port} = application:get_env(ns_ssl_proxy, upstream_port),

    case gen_tcp:listen(Port,
                        [{reuseaddr, true},
                         {backlog, 100},
                         inet,
                         binary,
                         {packet, raw},
                         {nodelay, true},
                         {active, false},
                         {ip, {127, 0, 0, 1}}]) of
        {ok, Sock} ->
            proc_lib:init_ack({ok, self()}),
            accept_loop(Sock);
        {error, Reason} ->
            erlang:exit({listen_failed, Reason})
    end.

accept_loop(LSock) ->
    case gen_tcp:accept(LSock) of
        {ok, S} ->
            Pid = ns_ssl_proxy_server_sup:start_handler(S, upstream),
            case gen_tcp:controlling_process(S, Pid) of
                ok -> ok;
                Err ->
                    ?log_debug("failed to set controlling process of upstream socket: ~p", [Err]),
                    gen_tcp:close(S)
            end,
            accept_loop(LSock);
        {error, closed} ->
            exit(shutdown);
        Error ->
            exit({accept_error, Error})
    end.
