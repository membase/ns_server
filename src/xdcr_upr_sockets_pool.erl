%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc
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
%% @doc pool of sockets that are used by xdcr upr streaming
%%
-module(xdcr_upr_sockets_pool).

-export([start_link/0]).

-export([take_socket/1, put_socket/2]).

-include("ns_common.hrl").
%% for ?XDCR_UPR_BUFFER_SIZE
-include("xdcr_upr_streamer.hrl").

start_link() ->
    Options = [{name, ?MODULE},
               {connection_timeout, 30000},
               {pool_size, 10000}],
    ns_connection_pool:start_link(Options).


-spec take_socket(bucket_name()) -> {ok, port()}.
take_socket(Bucket) ->
    case ns_connection_pool:maybe_take_socket(?MODULE, Bucket) of
        {ok, Sock} ->
            {ok, Sock};
        no_socket ->
            do_connect(Bucket)
    end.

do_connect(Bucket) ->
    case ns_memcached:connect() of
        {ok, Socket} ->
            case mc_client_binary:select_bucket(Socket, Bucket) of
                ok ->
                    Random = couch_uuids:random(),
                    Name = <<"upr-", (list_to_binary(Bucket))/binary, "-", Random/binary>>,
                    case upr_commands:open_connection(Socket, binary_to_list(Name), producer) of
                        ok ->
                            case upr_commands:setup_flow_control(Socket, ?XDCR_UPR_BUFFER_SIZE) of
                                ok ->
                                    {ok, Socket};
                                Err ->
                                    {error, {setup_flow_control_failed, Err}}
                            end;
                        OCErr ->
                            {error, {open_connection_failed, OCErr}}
                    end;
                Err ->
                    {error, {select_bucket_failed, Err}}
            end;
        Error ->
            Error
    end.

put_socket(Bucket, Socket) ->
    ns_connection_pool:put_socket(?MODULE, Bucket, Socket).
