%% @author Couchbase <info@couchbase.com>
%% @copyright 2013-2017 Couchbase, Inc.
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
-module(memcached_clients_pool).

-include("ns_common.hrl").

-export([start_link/0,
         make_loc/5]).

-export([take_socket/1, put_socket/2]).

start_link() ->
    Options = [{name, memcached_clients_pool},
               {connection_timeout, 30000},
               {pool_size_per_dest, 100}],
    ns_connection_pool:start_link(Options).

take_socket({?MODULE, {Host, Port, Bucket, Auth, Enchancer}}) ->
    case ns_connection_pool:maybe_take_socket(memcached_clients_pool,
                                              {Host, Port, Bucket, Enchancer}) of
        {ok, _S} = Ok ->
            Ok;
        no_socket ->
            establish_connection(Host, Port, Bucket, Auth, Enchancer)
    end.

establish_connection(Host, Port, Bucket, Password, Enchancer) ->
    case gen_tcp:connect(Host, Port, [misc:get_net_family(), binary,
                                      {packet, 0}, {keepalive, true},
                                      {nodelay, true}, {active, false}]) of
        {ok, S} ->
            case mc_client_binary:auth(S, {<<"PLAIN">>,
                                           {list_to_binary(Bucket),
                                            list_to_binary(Password)}}) of
                ok ->
                    case Enchancer of
                        [] ->
                            {ok, S};
                        _ ->
                            ok = Enchancer:enchance_socket(S),
                            {ok, S}
                    end;
                {memcached_error, _, _} = McdError ->
                    {error, {auth_failed, McdError}}
            end;
        {error, _ } = Error ->
            Error
    end.

put_socket(Socket, {?MODULE, {Host, Port, Bucket, _Auth, Enchancer}}) ->
    ns_connection_pool:put_socket(memcached_clients_pool,
                                  {Host, Port, Bucket, Enchancer}, Socket).

make_loc(Host, Port, Bucket, Password, Enchancer) ->
    {?MODULE, {Host, Port, Bucket, Password, Enchancer}}.
