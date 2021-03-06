%% @author Couchbase <info@couchbase.com>
%% @copyright 2013-2016 Couchbase, Inc.
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
-module(pooled_memcached_client).

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").
-include("xdcr_dcp_streamer.hrl").

-export([find_missing_revs/4, bulk_set_metas/4]).

-export([send_batch/2, extract_recv_socket/1]).

-spec find_missing_revs(any(), vbucket_id(), [{binary(), rev()}], non_neg_integer() | infinity) ->
                               {ok,
                                [{binary(), rev()}],
                                [{atom(), {binary(), rev()}}]}.
find_missing_revs(DestRef, Vb, IdRevs, Timeout) ->
    execute(DestRef, fun find_missing_revs_inner/4, [Vb, IdRevs, Timeout]).

send_batch({batch_socket, Socket}, Requests) ->
    BatchBytes = iolist_size(Requests),
    BatchReqs = length(Requests),
    system_stats_collector:add_histo(xdcr_batch_bytes, BatchBytes),
    system_stats_collector:add_histo(xdcr_batch_reqs, BatchReqs),
    Data1 = [<<BatchBytes:32/big, BatchReqs:32/big>> | Requests],
    ok = prim_inet:send(Socket, Data1);
send_batch(Socket, Requests) ->
    ok = prim_inet:send(Socket, Requests).

extract_recv_socket({batch_socket, S}) ->
    S;
extract_recv_socket(S) ->
    S.


find_missing_revs_inner(S, Vb, IdRevs, Timeout) ->
    SenderPid = spawn_link(
                  fun () ->
                          Data = [begin
                                      H = #mc_header{vbucket = Vb,
                                                     opcode = ?CMD_GET_META},
                                      E = #mc_entry{key = Key},
                                      mc_binary:encode(req, H, E)
                                  end || {Key, _Rev} <- IdRevs],
                          send_batch(S, Data)
                  end),
    RV = fetch_missing_revs_loop(extract_recv_socket(S), IdRevs, [], [], Timeout),
    misc:unlink_terminate_and_wait(SenderPid, kill),
    RV.

fetch_missing_revs_loop(_S, [], Acc, AccErr, _Timeout) ->
    {ok, lists:reverse(Acc), lists:reverse(AccErr)};
fetch_missing_revs_loop(S, [{_Key, Rev} = Pair | Rest], Acc, AccErr, Timeout) ->
    Missing =
        case mc_binary:recv(S, res, Timeout) of
            %% get meta of key successfully
            {ok, #mc_header{status=?SUCCESS}, #mc_entry{ext = Ext, cas = CAS}} ->
                <<_MetaFlags:32/big, ItemFlags:32/big,
                  Expiration:32/big, SeqNo:64/big>> = Ext,
                RevId = <<CAS:64/big, Expiration:32/big, ItemFlags:32/big>>,
                RemoteRev = {SeqNo, RevId},
                RemoteRev < Rev;
            %% key not found, which is Ok if replicating new items
            {ok, #mc_header{status=?KEY_ENOENT}, _} ->
                true;
            %% unexpected response returned by remote memcached, treat it as error
            {ok, #mc_header{status=OtherResponse}, _} ->
                {error, mc_client_binary:map_status(OtherResponse)}
        end,
    case Missing of
        {error, Err} ->
            fetch_missing_revs_loop(S, Rest, Acc, [{Err, Pair} | AccErr], Timeout);
        _Bool ->
            NewAcc = if Missing -> [Pair | Acc];
                        true -> Acc
                     end,
            fetch_missing_revs_loop(S, Rest, NewAcc, AccErr, Timeout)
    end.


bulk_set_metas(_DestRef, _Vb, [] = _MutationsList, _Timeout) ->
    {ok, []};
bulk_set_metas(DestRef, Vb, MutationsList, Timeout) ->
    execute(DestRef, fun bulk_set_metas_inner/4, [Vb, MutationsList, Timeout]).

bulk_set_metas_inner(S, Vb, MutationsList, Timeout) ->
    RecverPid =
        erlang:spawn_link(
          erlang, apply,
          [fun bulk_set_metas_recv_replies/4, [S, self(), length(MutationsList), Timeout]]),
    Data = [encode_single_set_meta(Vb, M) || M <- MutationsList],
    send_batch(S, Data),
    receive
        {RecverPid, RV} ->
            {ok, RV}
    end.

encode_single_set_meta(Vb,
                       #dcp_mutation{id = Key, rev = Rev, deleted = Deleted,
                                     body = DocValue, datatype = DT}) ->
    {OpCode, Data} = case Deleted of
                         true ->
                             {?CMD_DEL_WITH_META, <<>>};
                         _ ->
                             {?CMD_SET_WITH_META, DocValue}
                     end,
    Ext = mc_client_binary:rev_to_mcd_ext(Rev),
    McHeader = #mc_header{vbucket = Vb, opcode = OpCode},
    %% CAS does not matter since remote ep_engine has capability
    %% to do getMeta internally before doing setWithMeta or delWithMeta
    CAS  = 0,
    McBody = #mc_entry{key = Key, data = Data, ext = Ext,
                       cas = CAS, datatype = DT},
    mc_binary:encode(req, McHeader, McBody).

bulk_set_metas_recv_replies(S, Parent, Count, Timeout) ->
    RVs = bulk_set_metas_replies_loop(extract_recv_socket(S), Count, [], Timeout),
    Parent ! {self(), RVs}.

bulk_set_metas_replies_loop(_S, 0, Acc, _Timeout) ->
    lists:reverse(Acc);
bulk_set_metas_replies_loop(S, Count, Acc, Timeout) ->
    case mc_binary:recv(S, res, Timeout) of
        {ok, #mc_header{status=Status}, _} ->
            NewAcc = [mc_client_binary:map_status(Status) | Acc],
            bulk_set_metas_replies_loop(S, Count - 1, NewAcc, Timeout)
    end.

execute(DestRef, Body, Args) ->
    Parent = self(),
    Pid =
        proc_lib:spawn_link(
          fun () ->
                  RV = execute_on_socket(DestRef, Body, Args),
                  Parent ! {self(), RV}
          end),
    receive
        {'EXIT', Pid, Reason} ->
            ?log_error("Child memcached client process died: ~p", [Reason]),
            erlang:exit(Reason);
        {Pid, RV} ->
            RV
    end.

execute_on_socket(DestRef, Body, Args) ->
    case DestRef:take_socket() of
        {ok, S} ->
            execute_with_socket(S, Body, Args, DestRef);
        {error, _} = Error ->
            Error
    end.

execute_with_socket(S, Body, Args, DestRef) ->
    RV = erlang:apply(Body, [S | Args]),
    case RV of
        _ when is_tuple(RV) andalso element(1, RV) =:= ok ->
            DestRef:put_socket(S),
            RV;
        Error ->
            %% no need to close socket, it'll be autoclosed
            Error
    end.
