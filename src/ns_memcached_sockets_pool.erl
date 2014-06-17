%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc
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
%% @doc pool of sockets that are used for long blocking memcached calls
%%
-module(ns_memcached_sockets_pool).

-include("ns_common.hrl").

-export([start_link/0]).

-export([take_socket/0, take_socket/1, put_socket/1, executing_on_socket/1]).

start_link() ->
    Options = [{name, ?MODULE},
               {connection_timeout, 30000},
               {pool_size, 10000}],
    ns_connection_pool:start_link(Options).

take_socket() ->
    case ns_connection_pool:maybe_take_socket(?MODULE, ns_memcached) of
        {ok, Sock} ->
            {ok, Sock};
        no_socket ->
            ns_memcached:connect()
    end.

take_socket(Bucket) ->
    case take_socket() of
        {ok, Socket} ->
            case mc_client_binary:select_bucket(Socket, Bucket) of
                ok ->
                    {ok, Socket};
                Err ->
                    {error, {select_bucket_failed, Err}}
            end;
        Error ->
            Error
    end.

put_socket(Socket) ->
    ns_connection_pool:put_socket(?MODULE, ns_memcached, Socket).

executing_on_socket(Fun) ->
    misc:executing_on_new_process(
      fun () ->
              case ns_memcached_sockets_pool:take_socket() of
                  {ok, Sock} ->
                      Result = Fun(Sock),
                      ns_memcached_sockets_pool:put_socket(Sock),
                      Result;
                  Error ->
                      Error
              end
      end).
