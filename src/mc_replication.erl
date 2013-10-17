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
%% @doc some common methods to work with memcached connections
%%
-module(mc_replication).

-include("mc_constants.hrl").

-export([connect/3, connect/4, process_data/4, process_data/3]).

-define(CONNECT_TIMEOUT, ns_config_ets_dup:get_timeout(ebucketmigrator_connect, 180000)).

connect({Host, Port}, Username, Password) ->
    {ok, Sock} = gen_tcp:connect(Host, Port,
                                 [binary, {packet, raw}, {active, false},
                                  {nodelay, true}, {delay_send, true},
                                  {keepalive, true},
                                  {recbuf, 10*1024*1024},
                                  {sndbuf, 10*1024*1024}],
                                 ?CONNECT_TIMEOUT),
    case Username of
        undefined ->
            ok;
        "default" ->
            ok;
        _ ->
            ok = mc_client_binary:auth(Sock, {<<"PLAIN">>,
                                              {list_to_binary(Username),
                                               list_to_binary(Password)}})
    end,
    Sock.

connect(HostAndPort, Username, Password, undefined) ->
    connect(HostAndPort, Username, Password);
connect(HostAndPort, Username, Password, Bucket) ->
    Sock = connect(HostAndPort, Username, Password),
    ok = mc_client_binary:select_bucket(Sock, Bucket),
    Sock.

%% @doc Chop up a buffer into packets, calling the callback with each packet.
-spec process_data(binary(), fun((binary(), tuple()) -> {binary(), tuple()}),
                                tuple()) -> {binary(), tuple()}.
process_data(<<_Magic:8, _Opcode:8, _KeyLen:16, _ExtLen:8, _DataType:8,
               _VBucket:16, BodyLen:32, _Opaque:32, _CAS:64, _Rest/binary>>
                 = Buffer, CB, State)
  when byte_size(Buffer) >= BodyLen + ?HEADER_LEN ->
    %% We have a complete command
    {Packet, NewBuffer} = split_binary(Buffer, BodyLen + ?HEADER_LEN),
    case CB(Packet, State) of
        {ok, State1} ->
            process_data(NewBuffer, CB, State1);
        {stop, State1} ->
            {NewBuffer, State1}
    end;
process_data(Buffer, _CB, State) ->
    %% Incomplete
    {Buffer, State}.


%% @doc Append Data to the appropriate buffer, calling the given
%% callback for each packet.
-spec process_data(binary(), non_neg_integer(),
                   fun((binary(), tuple()) -> tuple()), tuple()) -> tuple().
process_data(Data, Elem, CB, State) ->
    Buffer = element(Elem, State),
    {NewBuf, NewState} = process_data(<<Buffer/binary, Data/binary>>, CB, State),
    setelement(Elem, NewState, NewBuf).
