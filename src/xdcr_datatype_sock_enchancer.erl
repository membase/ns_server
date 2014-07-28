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
-module(xdcr_datatype_sock_enchancer).

-include("mc_constants.hrl").
-include("xdcr_dcp_streamer.hrl").

-export([enchance_socket/1,
         from_xmem_options/1]).

%% note: we're using #dcp_packet{} to talk plain memcached. Some time
%% later we'll unify them (dropping mc_client_binary and friends)
enchance_socket(Sock) ->
    Req = #dcp_packet{opcode = ?CMD_HELLO,
                      key = <<"xmem">>,
                      body = <<?MC_FEATURE_DATATYPE:16>>},
    EncReq = xdcr_dcp_streamer:encode_req(Req),
    %% we need this extra layer of abstraction in order to correctly
    %% support ssl proxy connections that require extra framing
    pooled_memcached_client:send_batch(Sock, [EncReq]),

    RecvSock = pooled_memcached_client:extract_recv_socket(Sock),
    {res, Resp, <<>>, _Size} = xdcr_dcp_streamer:read_message_loop(RecvSock, <<>>),
    #dcp_packet{opcode = ?CMD_HELLO,
                status = ?SUCCESS,
                body = <<?MC_FEATURE_DATATYPE:16>>} = Resp,
    ok.

from_xmem_options(XMemRemoteOptions) ->
    case proplists:get_value(supports_datatype, XMemRemoteOptions) of
        true ->
            ?MODULE;
        _ ->
            []
    end.
