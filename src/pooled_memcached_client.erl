-module(pooled_memcached_client).

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").
-include("couch_db.hrl").

-export([find_missing_revs/3, bulk_set_metas/3]).

-spec find_missing_revs(any(), vbucket_id(), [{binary(), rev()}]) ->
                               {ok,
                                [{binary(), rev()}],
                                [{atom(), {binary(), rev()}}]}.
find_missing_revs(DestRef, Vb, IdRevs) ->
    execute(DestRef, fun find_missing_revs_inner/3, [Vb, IdRevs]).

find_missing_revs_inner(S, Vb, IdRevs) ->
    SenderPid = spawn_link(
                  fun () ->
                          [begin
                               H = #mc_header{vbucket = Vb,
                                              opcode = ?CMD_GET_META},
                               E = #mc_entry{key = Key},
                               ok = mc_binary:send(S, req, H, E)
                           end || {Key, _Rev} <- IdRevs],
                          ok
                  end),
    RV = fetch_missing_revs_loop(S, IdRevs, [], []),
    erlang:unlink(SenderPid),
    erlang:exit(SenderPid, kill),
    misc:wait_for_process(SenderPid, infinity),
    RV.

fetch_missing_revs_loop(_S, [], Acc, AccErr) ->
    {ok, lists:reverse(Acc), lists:reverse(AccErr)};
fetch_missing_revs_loop(S, [{_Key, Rev} = Pair | Rest], Acc, AccErr) ->
    Missing =
        case mc_binary:recv(S, res, infinity) of
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
            fetch_missing_revs_loop(S, Rest, Acc, [{Err, Pair} | AccErr]);
        _Bool ->
            NewAcc = if Missing -> [Pair | Acc];
                        true -> Acc
                     end,
            fetch_missing_revs_loop(S, Rest, NewAcc, AccErr)
    end.


bulk_set_metas(_DestRef, _Vb, [] = _DocsList) ->
    {ok, []};
bulk_set_metas(DestRef, Vb, DocsList) ->
    execute(DestRef, fun bulk_set_metas_inner/3, [Vb, DocsList]).

bulk_set_metas_inner(S, Vb, DocsList) ->
    RecverPid = erlang:spawn_link(erlang, apply, [fun bulk_set_metas_recv_replies/3, [S, self(), length(DocsList)]]),
    [ok = send_single_set_meta(S, Vb, Doc) || Doc <- DocsList],
    receive
        {RecverPid, RV} ->
            {ok, RV}
    end.

send_single_set_meta(S, Vb,
                     #doc{id = Key, rev = Rev, deleted = Deleted,
                          body = DocValue}) ->
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
    McBody = #mc_entry{key = Key, data = Data, ext = Ext, cas = CAS},
    mc_binary:send(S, req, McHeader, McBody).

bulk_set_metas_recv_replies(S, Parent, Count) ->
    RVs = bulk_set_metas_replies_loop(S, Count, []),
    Parent ! {self(), RVs}.

bulk_set_metas_replies_loop(_S, 0, Acc) ->
    lists:reverse(Acc);
bulk_set_metas_replies_loop(S, Count, Acc) ->
    case mc_binary:recv(S, res, infinity) of
        {ok, #mc_header{status=Status}, _} ->
            NewAcc = [mc_client_binary:map_status(Status) | Acc],
            bulk_set_metas_replies_loop(S, Count - 1, NewAcc)
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
