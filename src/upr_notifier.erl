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
%% @doc the service that provides notification to subscribers every time
%%      when new mutations appear on certain partition after certain seqno
%%
-module(upr_notifier).

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").

-record(partition, {partition :: vbucket_id(),
                    last_known_pos = undefined :: {seq_no(), integer(), seq_no()} | undefined,
                    stream_state = closed :: pending | open | closed,
                    subscribers = []}).

-export([start_link/1, subscribe/5]).

-export([init/1, handle_packet/5, handle_call/4, handle_cast/3]).

start_link(Bucket) ->
    upr_proxy:start_link(notifier, get_connection_name(Bucket, node()), node(), Bucket, ?MODULE, [Bucket]).

subscribe(Bucket, Partition, StartSeqNo, UUID, HighSeqNo) ->
    gen_server:call(server_name(Bucket), {subscribe, Partition, StartSeqNo, UUID, HighSeqNo}, infinity).

init([Bucket]) ->
    upr_proxy:no_proxy_setup(self()),
    erlang:register(server_name(Bucket), self()),
    [].

server_name(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).

handle_call({subscribe, Partition, StartSeqNo, UUID, HighSeqNo}, From, State, ParentState) ->
    PartitionState = get_partition(Partition, State),
    do_subscribe(From, {StartSeqNo, UUID, HighSeqNo}, PartitionState, State, ParentState).

handle_cast(Msg, State, _ParentState) ->
    ?log_warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_packet(request, ?NOOP, _Packet, State, ParentState) ->
    {ok, quiet} = mc_client_binary:respond(?NOOP, upr_proxy:get_socket(ParentState),
                                           {#mc_header{status = ?SUCCESS},
                                            #mc_entry{}}),
    {block, State};

handle_packet(request, Opcode, Packet, State, ParentState) ->
    {Header, Body} = mc_binary:decode_packet(Packet),
    PartitionState = get_partition(Header#mc_header.opaque, State),
    {block,
     set_partition(handle_request(Opcode, Header, Body, PartitionState, ParentState), State)};

handle_packet(response, Opcode, Packet, State, ParentState) ->
    {Header, Body} = mc_binary:decode_packet(Packet),
    PartitionState = get_partition(Header#mc_header.opaque, State),
    {block,
     set_partition(handle_response(Opcode, Header, Body, PartitionState, ParentState), State)}.

handle_response(?UPR_STREAM_REQ, Header, Body,
                #partition{stream_state = pending,
                           partition = Partition,
                           last_known_pos = {_, UUID, HighSeqNo}} = PartitionState, ParentState) ->
    case upr_commands:process_response(Header, Body) of
        ok ->
            PartitionState#partition{stream_state = open};
        {rollback, RollbackSeqNo} ->
            ?log_debug("Rollback stream for partition ~p to seqno ~p", [Partition, RollbackSeqNo]),
            upr_commands:stream_request(upr_proxy:get_socket(ParentState),
                                        Partition, Partition, RollbackSeqNo, 0, UUID, HighSeqNo),
            PartitionState
    end.

handle_request(?UPR_STREAM_END, _Header, _Body,
               #partition{stream_state = open,
                          subscribers = Subscribers} = PartitionState, _ParentState) ->
    [gen_server:reply(From, ok) || From <- Subscribers],
    PartitionState#partition{stream_state = closed,
                             subscribers = []}.

get_connection_name(Bucket, Node) ->
    "ns_server:xdcr:" ++ atom_to_list(Node) ++ ":" ++ Bucket.

get_partition(Partition, Partitions) ->
    case lists:keyfind(Partition, #partition.partition, Partitions) of
        false ->
            #partition{partition = Partition};
        P ->
            P
    end.

set_partition(#partition{partition = Partition} = PartitionState,
              Partitions) ->
    lists:keystore(Partition, #partition.partition, Partitions, PartitionState).

add_subscriber(From, #partition{subscribers = Subscribers} = PartitionState) ->
    PartitionState#partition{subscribers = [From | Subscribers]}.

%% here we have the following possible situations:
%%
%% 1. stream is closed
%%   1.1. requested pos is equal to the last known pos
%%          return immediately because we know that there is data after this pos
%%   1.2  requested pos is behind the last known pos
%%          we should return immediately because we know that there is data after this pos
%%          but we can detect this situation for sure only if UUID and HighSeqNo for
%%          these two positions match. in a quite rare case if they don't match
%%          we still going to open stream
%%   1.3  we cannot say that the requested pos is behind the last known pos
%%          it can be ahead or the positions have different UUID and HighSeqNo
%%          in this case we open a stream and change last known pos to the requested pos
%%          we will notify the subscriber as soon as the stream closes
%%
%% 2. stream is open or pending (opening)
%%   2.1. requested pos is equal to the last known pos
%%          add the subscriber to the list of subscribers
%%          we will notify the subscriber as soon as the stream closes
%%   2.2. requested pos is not equal to the last known pos
%%          there's quite a slim chance that the requested pos is ahead of
%%          the pos the stream was opened on (only in case of race between the
%%          subscription request and close_stream message)
%%          and we are ok with some false positives
%%          so we can assume that the requested pos is behind the last known pos
%%          and return immediately since the data is already available
do_subscribe(_From, {StartSeqNo, UUID, HighSeqNo},
             #partition{last_known_pos = {LNStartSeqNo, UUID, HighSeqNo},
                        stream_state = closed} = PartitionState, State, _ParentState)
  when StartSeqNo =< LNStartSeqNo ->
    {reply, ok, set_partition(PartitionState, State)};

do_subscribe(From, {StartSeqNo, UUID, HighSeqNo} = Pos,
             #partition{partition = Partition,
                        stream_state = closed} = PartitionState,
             State, ParentState) ->
    upr_commands:stream_request(upr_proxy:get_socket(ParentState),
                                Partition, Partition, StartSeqNo, 0, UUID, HighSeqNo),

    PartitionState1 = PartitionState#partition{last_known_pos = Pos,
                                               stream_state = pending},
    {noreply, set_partition(add_subscriber(From, PartitionState1), State)};

do_subscribe(From, Pos,
             #partition{last_known_pos = Pos} = PartitionState,
             State, _ParentState) ->
    {noreply, set_partition(add_subscriber(From, PartitionState), State)};

do_subscribe(_From, _Pos,
             PartitionState, State, _ParentState) ->
    {reply, ok, set_partition(PartitionState, State)}.
