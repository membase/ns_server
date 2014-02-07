%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

-module(xdc_vbucket_rep_xmem_worker).
-behaviour(gen_server).

%% public functions
-export([start_link/4]).
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([connect/2, stop/1]).

-export([find_missing_pipeline/2, flush_docs_pipeline/2]).

-export([format_status/2]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").


%% -------------------------------------------------------------------------- %%
%% ---                         public functions                           --- %%
%% -------------------------------------------------------------------------- %%
start_link(Vb, Id, Parent, ConnectionTimeout) ->
    gen_server:start_link(?MODULE, {Vb, Id, Parent, ConnectionTimeout}, []).

%% gen_server behavior callback functions
init({Vb, Id, Parent, ConnectionTimeout}) ->
    Errs = ringbuffer:new(?XDCR_ERROR_HISTORY),
    InitState = #xdc_vb_rep_xmem_worker_state{
      id = Id,
      vb = Vb,
      parent_server_pid = Parent,
      status  = init,
      statistics = #xdc_vb_rep_xmem_statistics{},
      time_init = calendar:now_to_local_time(erlang:now()),
      time_connected = 0,
      error_reports = Errs,
      connection_timeout=ConnectionTimeout},

    {ok, InitState}.

format_status(Opt, [PDict, State]) ->
    xdc_rep_utils:sanitize_status(Opt, PDict, State).

-spec find_missing_pipeline(pid(), list()) -> {ok, list()} | {error, term()}.
find_missing_pipeline(Server, IdRevs) ->
    gen_server:call(Server, {find_missing_pipeline, IdRevs}, infinity).

-spec flush_docs_pipeline(pid(), list()) -> {ok, integer(), integer()} | {error, term()}.
flush_docs_pipeline(Server, DocsList) ->
    gen_server:call(Server, {flush_docs_pipeline, DocsList}, infinity).

-spec connect(pid(), #xdc_rep_xmem_remote{}) -> ok | {error, term()}.
connect(Server, Remote) ->
    gen_server:call(Server, {connect, Remote}, infinity).

stop(Server) ->
    gen_server:cast(Server, stop).

handle_info({'EXIT',_Pid, normal}, St) ->
    {noreply, St};

handle_info({'EXIT',_Pid, Reason}, St) ->
    {stop, Reason, St}.

handle_call({connect, #xdc_rep_xmem_remote{ip = Host,
                                           port = Port,
                                           bucket = Bucket,
                                           password = Password,
                                           options = RemoteOptions}},
            _From, State) ->
    McdDst = case proplists:get_value(cert, RemoteOptions) of
                 undefined ->
                     memcached_clients_pool:make_loc(Host, Port, Bucket, Password);
                 Cert ->
                     LocalProxyPort = ns_config_ets_dup:unreliable_read_key({node, node(), ssl_proxy_upstream_port}, undefined),
                     RemoteProxyPort = proplists:get_value(remote_proxy_port, RemoteOptions),
                     proxied_memcached_clients_pool:make_proxied_loc(Host, Port, Bucket, Password,
                                                                     LocalProxyPort, RemoteProxyPort,
                                                                     Cert)
             end,
    {reply, ok, State#xdc_vb_rep_xmem_worker_state{mcd_loc = McdDst}};

%% ----------- Pipelined Memached Ops --------------%%
handle_call({find_missing_pipeline, IdRevs}, _From,
            #xdc_vb_rep_xmem_worker_state{vb = Vb, mcd_loc = McdDst} =  State) ->
    {ok, MissingRevs, Errors} = pooled_memcached_client:find_missing_revs(McdDst, Vb, IdRevs),
    ErrRevs =
        [begin
             ?xdcr_trace("Error! memcached error when fetching metadata from remote for key: ~p, "
                         "just send the doc (msg: "
                         "\"unexpected response from remote memcached (vb: ~p, error: ~p)\")",
                         [Key, Vb, Error]),
             Pair
         end || {Error, {Key, _} = Pair} <- Errors],
    {reply, {ok, ErrRevs ++ MissingRevs}, State};

%% ----------- Pipelined Memached Ops --------------%%
handle_call({flush_docs_pipeline, DocsList}, _From,
            #xdc_vb_rep_xmem_worker_state{id = Id, vb = VBucket,
                                          mcd_loc = McdDst,
                                          connection_timeout = ConnectionTimeout} =  State) ->
    TimeStart = now(),

    {ok, Statuses} = pooled_memcached_client:bulk_set_metas(McdDst, VBucket, DocsList),

    {ErrorDict, ErrorKeysDict} = categorise_statuses_to_dict(Statuses, DocsList),
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
            ?xdcr_error("[xmem_worker ~p for vb ~p]: update ~p docs takes too long to finish!"
                        "(total time spent: ~p secs, default connection time out: ~p secs)",
                        [Id, VBucket, length(DocsList), TimeSpentSecs, ConnectionTimeout]);
        _ ->
            ok
    end,

    DocsListSize = length(DocsList),
    RV =
        case (Flushed + Eexist) == DocsListSize of
            true ->
                {reply, {ok, Flushed, Eexist}, State};
            _ ->
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
                {stop, {error, {ErrorStr, ErrorKeyStr}}, State}
        end,
    RV;

handle_call(Msg, From, #xdc_vb_rep_xmem_worker_state{vb = Vb,
                                                     id = Id} = State) ->
    ?xdcr_error("[xmem_worker ~p for vb ~p]: received unexpected call ~p from process ~p",
                [Id, Vb, Msg, From]),
    {stop, {error, {unexpected_call, Msg, From}}, State}.


%% --- handle_cast --- %%
handle_cast(stop, #xdc_vb_rep_xmem_worker_state{} = State) ->
    %% let terminate() do the cleanup
    {stop, normal, State};

handle_cast({report_error, Err}, #xdc_vb_rep_xmem_worker_state{error_reports = Errs} = State) ->
    {noreply, State#xdc_vb_rep_xmem_worker_state{error_reports = ringbuffer:add(Err, Errs)}};

handle_cast(Msg, #xdc_vb_rep_xmem_worker_state{id = Id, vb = Vb} = State) ->
    ?xdcr_error("[xmem_worker ~p for vb ~p]: received unexpected cast ~p",
                [Id, Vb, Msg]),
    {stop, {error, {unexpected_cast, Msg}}, State}.


%% default gen_server callbacks
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, _State) when Reason == normal orelse Reason == shutdown ->
    ok;

terminate(Reason, #xdc_vb_rep_xmem_worker_state{vb = Vb,
                                                id = Id,
                                                parent_server_pid = Par}) ->
    report_error(Reason, Vb, Par),
    ?xdcr_error("[xmem_worker ~p for vb ~p]: shutdown xmem worker, error reported to "
                "parent xmem srv: ~p", [Id, Vb, Par]),
    ok.

%% -------------------------------------------------------------------------- %%
%% ---                  internal helper functions                         --- %%
%% -------------------------------------------------------------------------- %%

report_error(Err, _Vb, _Parent) when Err == normal orelse Err == shutdown ->
    ok;
report_error(Err, Vb, Parent) ->
     %% return raw erlang time to make it sortable
    RawTime = erlang:localtime(),
    Time = misc:iso_8601_fmt(RawTime),
    String = iolist_to_binary(io_lib:format("~s - [XMEM worker] Error replicating "
                                            "vbucket ~p: ~p",
                                            [Time, Vb, Err])),
    gen_server:cast(Parent, {report_error, {RawTime, String}}).

-spec categorise_statuses_to_dict(list(), list()) -> {dict(), dict()}.
categorise_statuses_to_dict(Statuses, DocsList) ->
    {ErrorDict, ErrorKeys, _}
        = lists:foldl(fun(Status, {DictAcc, ErrorKeyAcc, CountAcc}) ->
                              CountAcc2 = CountAcc + 1,
                              Doc = lists:nth(CountAcc2, DocsList),
                              Key = Doc#doc.id,
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
