%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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

-module(xdc_vbucket_rep_xmem).

-export([make_location/2, find_missing/2, flush_docs/2]).

-include("xdc_replicator.hrl").
-include("xdcr_upr_streamer.hrl").

make_location(#xdc_rep_xmem_remote{ip = Host,
                                   port = Port,
                                   bucket = Bucket,
                                   vb = VBucket,
                                   password = Password,
                                   options = RemoteOptions},
              ConnectionTimeout) ->
    Enchancer = xdcr_datatype_sock_enchancer:from_xmem_options(RemoteOptions),
    McdDst = case proplists:get_value(cert, RemoteOptions) of
                 undefined ->
                     memcached_clients_pool:make_loc(Host, Port, Bucket, Password, Enchancer);
                 Cert ->
                     LocalProxyPort = ns_config:read_key_fast({node, node(), ssl_proxy_upstream_port}, undefined),
                     RemoteProxyPort = proplists:get_value(remote_proxy_port, RemoteOptions),
                     proxied_memcached_clients_pool:make_proxied_loc(Host, Port, Bucket, Password,
                                                                     LocalProxyPort, RemoteProxyPort,
                                                                     Cert, Enchancer)
             end,

    #xdc_xmem_location{vb = VBucket,
                       mcd_loc = McdDst,
                       connection_timeout = ConnectionTimeout}.

find_missing(#xdc_xmem_location{vb = VBucket, mcd_loc = McdDst}, IdRevs) ->
    {ok, MissingRevs, Errors} =
        pooled_memcached_client:find_missing_revs(McdDst, VBucket, IdRevs),
    ErrRevs =
        [Pair || {_Error, Pair} <- Errors],
    {ok, ErrRevs ++ MissingRevs}.

flush_docs(Loc, MutationsList) ->
    do_flush_docs(Loc, MutationsList, 5).

do_flush_docs(#xdc_xmem_location{vb = VBucket,
                                 mcd_loc = McdDst,
                                 connection_timeout = ConnectionTimeout} = Loc,
              MutationsList, TriesLeft) ->
    true = (TriesLeft > 0),
    TimeStart = now(),

    {ok, Statuses} = pooled_memcached_client:bulk_set_metas(McdDst, VBucket, MutationsList),
    ?x_trace(xmemSetMetas, [{ids, {json, [M#dcp_mutation.id || M <- MutationsList]}},
                            {statuses, {json, Statuses}},
                            {startTS, xdcr_trace_log_formatter:format_ts(TimeStart)}]),

    {ErrorDict, ErrorKeysDict} = categorise_statuses_to_dict(Statuses, MutationsList),
    Flushed = lookup_error_dict(success, ErrorDict),
    Enoent = lookup_error_dict(key_enoent, ErrorDict),
    Eexist = lookup_error_dict(key_eexists, ErrorDict),
    NotMyVb = lookup_error_dict(not_my_vbucket, ErrorDict),
    Einval = lookup_error_dict(einval, ErrorDict),
    TmpFail = lookup_error_dict(etmpfail, ErrorDict),
    Enomem = lookup_error_dict(enomem, ErrorDict),
    OtherErr = (length(Statuses) - Flushed - Eexist - Enoent - NotMyVb - Einval - TmpFail - Enomem),

    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,

    %% dump error msg if timeout
    TimeSpentSecs = TimeSpent div 1000,
    case TimeSpentSecs > ConnectionTimeout of
        true ->
            ?xdcr_error("[xmem_worker for vb ~p]: update ~p docs takes too long to finish!"
                        "(total time spent: ~p secs, default connection time out: ~p secs)",
                        [VBucket, length(MutationsList), TimeSpentSecs, ConnectionTimeout]);
        _ ->
            ok
    end,

    DocsListSize = length(MutationsList),
    if
        (Flushed + Eexist) == DocsListSize ->
            {ok, Flushed, Eexist};
        (Flushed + Eexist + TmpFail) == DocsListSize andalso TriesLeft > 1 ->
            FailedMutations = [M || {M, etmpfail} <- lists:zip(MutationsList, Statuses)],
            Delay = case TriesLeft of
                        5 -> 1;
                        4 -> 10;
                        3 -> 100;
                        2 -> 500
                    end,
            ?x_trace(xmemRetry, [{delay, Delay},
                                 {attemptsLeft, TriesLeft - 1}]),
            timer:sleep(Delay),
            case do_flush_docs(Loc, FailedMutations, TriesLeft - 1) of
                {error, _} = Err ->
                    Err;
                {ok, ChildFlushed, ChildExist} ->
                    {ok, Flushed + ChildFlushed, Eexist + ChildExist}
            end;
        true ->
            %% for some reason we can only return one error. Thus
            %% we're logging everything else here
            ?xdcr_error("out of ~p docs, succ to send ~p docs, fail to send others "
                        "(by error type, enoent: ~p, not-my-vb: ~p, einval: ~p, "
                        "tmp fail: ~p, enomem: ~p, other errors: ~p",
                        [DocsListSize, (Flushed + Eexist), Enoent, NotMyVb,
                         Einval, TmpFail, Enomem, OtherErr]),

            ErrorKeyStr = convert_error_dict_to_string(ErrorKeysDict),
            ErrorStr = ?format_msg("in batch of ~p docs: flushed: ~p, rejected (eexists): ~p; "
                                   "remote memcached errors: enoent: ~p, not-my-vb: ~p, invalid: ~p, "
                                   "tmp fail: ~p, enomem: ~p, others: ~p",
                                   [DocsListSize, Flushed, Eexist, Enoent, NotMyVb,
                                    Einval, TmpFail, Enomem, OtherErr]),
            {error, {ErrorStr, ErrorKeyStr}}
    end.

%% internal
-spec categorise_statuses_to_dict(list(), list()) -> {dict(), dict()}.
categorise_statuses_to_dict(Statuses, MutationsList) ->
    {ErrorDict, ErrorKeys, _}
        = lists:foldl(fun(Status, {DictAcc, ErrorKeyAcc, CountAcc}) ->
                              CountAcc2 = CountAcc + 1,
                              M = lists:nth(CountAcc2, MutationsList),
                              Key = M#dcp_mutation.id,
                              {DictAcc2, ErrorKeyAcc2}  =
                                  case Status of
                                      success ->
                                          {dict:update_counter(success, 1, DictAcc), ErrorKeyAcc};
                                      %% use status as key since # of memcached status is limited
                                      S ->
                                          NewDict = dict:update_counter(S, 1, DictAcc),
                                          CurrKeyList = case dict:find(Status, ErrorKeyAcc) of
                                                            {ok, V} ->
                                                                V;
                                                            _ ->
                                                                []
                                                        end,
                                          NewKeyList = [Key | CurrKeyList],
                                          NewErrorKey = dict:store(Status, NewKeyList, ErrorKeyAcc),
                                          {NewDict, NewErrorKey}
                                  end,
                              {DictAcc2, ErrorKeyAcc2, CountAcc2}
                      end,
                      {dict:new(), dict:new(), 0},
                      lists:reverse(Statuses)),
    {ErrorDict, ErrorKeys}.

-spec lookup_error_dict(term(), dict()) -> integer().
lookup_error_dict(Key, ErrorDict)->
     case dict:find(Key, ErrorDict) of
         error ->
             0;
         {ok, V} ->
             V
     end.

-spec convert_error_dict_to_string(dict()) -> list().
convert_error_dict_to_string(ErrorKeyDict) ->
    StrHead = case dict:size(ErrorKeyDict) > 0 of
                  true ->
                      "Error with their keys:";
                  _ ->
                      "No error keys."
              end,
    ErrorStr =
        dict:fold(fun(Status, KeyList, ErrorStrIn) ->
                          L = length(KeyList),
                          Msg1 = ?format_msg("~p keys with ~p errors", [L, Status]),
                          Msg2 = case L > 10 of
                                     true ->
                                         ?format_msg("(dump first 10 keys: ~p); ",
                                                     [lists:sublist(KeyList, 10)]);
                                     _ ->
                                         ?format_msg("(~p); ", [KeyList])
                                 end,
                          ErrorStrIn ++ Msg1 ++ Msg2
                  end,
                  [], ErrorKeyDict),
    StrHead ++ ErrorStr.
