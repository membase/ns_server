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
-export([start_link/5]).
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([find_missing/2, flush_docs/2]).
-export([connect/2, select_bucket/2, disconnect/1, stop/1]).

-export([find_missing_pipeline/2, flush_docs_pipeline/2]).

-export([format_status/2]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").


%% -------------------------------------------------------------------------- %%
%% ---                         public functions                           --- %%
%% -------------------------------------------------------------------------- %%
start_link(Vb, Id, Parent, LocalConflictResolution, ConnectionTimeout) ->
    gen_server:start_link(?MODULE, {Vb, Id, Parent,
                                    LocalConflictResolution, ConnectionTimeout}, []).

%% gen_server behavior callback functions
init({Vb, Id, Parent, LocalConflictResolution, ConnectionTimeout}) ->
    process_flag(trap_exit, true),

    Errs = ringbuffer:new(?XDCR_ERROR_HISTORY),
    InitState = #xdc_vb_rep_xmem_worker_state{
      id = Id,
      vb = Vb,
      parent_server_pid = Parent,
      status  = init,
      statistics = #xdc_vb_rep_xmem_statistics{},
      socket = undefined,
      time_init = calendar:now_to_local_time(erlang:now()),
      time_connected = 0,
      error_reports = Errs,
      local_conflict_resolution=LocalConflictResolution,
      connection_timeout=ConnectionTimeout},

    {ok, InitState}.

format_status(Opt, [PDict, State]) ->
    xdc_rep_utils:sanitize_status(Opt, PDict, State).

-spec select_bucket(pid(), #xdc_rep_xmem_remote{}) -> ok |
                                                      {memcached_error, term(), term()}.
select_bucket(Server, Remote) ->
    gen_server:call(Server, {select_bucket, Remote}, infinity).

-spec find_missing(pid(), list()) -> {ok, list()} | {error, term()}.
find_missing(Server, IdRevs) ->
    gen_server:call(Server, {find_missing, IdRevs}, infinity).

-spec find_missing_pipeline(pid(), list()) -> {ok, list()} | {error, term()}.
find_missing_pipeline(Server, IdRevs) ->
    gen_server:call(Server, {find_missing_pipeline, IdRevs}, infinity).

-spec flush_docs(pid(), list()) -> {ok, integer(), integer()} | {error, term()}.
flush_docs(Server, DocsList) ->
    gen_server:call(Server, {flush_docs, DocsList}, infinity).

-spec flush_docs_pipeline(pid(), list()) -> {ok, integer(), integer()} | {error, term()}.
flush_docs_pipeline(Server, DocsList) ->
    gen_server:call(Server, {flush_docs_pipeline, DocsList}, infinity).

-spec connect(pid(), #xdc_rep_xmem_remote{}) -> ok | {error, term()}.
connect(Server, Remote) ->
    gen_server:call(Server, {connect, Remote}, infinity).

-spec disconnect(pid()) -> ok.
disconnect(Server) ->
    gen_server:call(Server, disconnect, infinity).

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
                                           options = RemoteOptions} = Remote},
            _From,
            #xdc_vb_rep_xmem_worker_state{id = Id, vb = Vb} =  State) ->
    case proplists:get_bool(dont_use_mcd_pool, RemoteOptions) of
        false ->
            McdDst = memcached_clients_pool:make_loc(Host, Port, Bucket, Password),
            {reply, ok, State#xdc_vb_rep_xmem_worker_state{mcd_loc = McdDst}};
        true ->
            %% establish connection to remote memcached
            Socket = case connect_internal(Remote) of
                         {ok, S} ->
                             S;
                         _ ->
                             ?xdcr_error("[xmem_worker ~p for vb ~p]: unable to connect remote memcached"
                                         "(ip: ~p, port: ~p) after ~p attempts",
                                         [Id, Vb,
                                          Remote#xdc_rep_xmem_remote.ip,
                                          Remote#xdc_rep_xmem_remote.port,
                                          ?XDCR_XMEM_CONNECTION_ATTEMPTS]),
                             nil
                     end,
            {reply, ok, State#xdc_vb_rep_xmem_worker_state{socket = Socket,
                                                           time_connected = calendar:now_to_local_time(erlang:now()),
                                                           status = connected}}
    end;

handle_call(disconnect, {_Pid, _Tag}, #xdc_vb_rep_xmem_worker_state{} =  State) ->
    State1 = close_connection(State),
    {reply, ok, State1, hibernate};

handle_call({select_bucket, _Remote}, _From,
            #xdc_vb_rep_xmem_worker_state{mcd_loc = McdDst} =  State) when McdDst =/= undefined ->
    {reply, ok, State};
handle_call({select_bucket, #xdc_rep_xmem_remote{} = Remote}, {_Pid, _Tag},
            #xdc_vb_rep_xmem_worker_state{id = Id, vb = Vb, socket = Socket} =  State) ->
    %% establish connection to remote memcached
    case select_bucket_internal(Remote, Socket) of
        ok ->
            ok;
        {memcached_error, not_supported, Msg} ->
            ?xdcr_debug("[xmem_worker ~p for vb ~p]: cmd select_bucket no longer supported  (bucket: ~p, username: ~p) at node ~p, "
                        "error msg: ~p",
                        [Id, Vb,
                         Remote#xdc_rep_xmem_remote.bucket,
                         Remote#xdc_rep_xmem_remote.username,
                         Remote#xdc_rep_xmem_remote.ip,
                         Msg]),
            ok;
        Error ->
            ?xdcr_error("[xmem_worker ~p for vb ~p]: unable to select remote bucket ~p (username: ~p) at node ~p, "
                        "error msg: ~p",
                        [Id, Vb,
                         Remote#xdc_rep_xmem_remote.bucket,
                         Remote#xdc_rep_xmem_remote.username,
                         Remote#xdc_rep_xmem_remote.ip,
                         Error])
    end,
    {reply, ok, State#xdc_vb_rep_xmem_worker_state{status = bucket_selected}};

handle_call({find_missing, IdRevs}, _From,
            #xdc_vb_rep_xmem_worker_state{vb = Vb,
                                          socket = Socket} =  State) ->
    TimeStart = now(),
    MissingIdRevs =
        lists:foldr(fun({Key, Rev}, Acc) ->
                            Missing =  is_missing(Socket, Vb, {Key, Rev}),
                            Acc1 = case Missing of
                                       true ->
                                           [{Key, Rev} | Acc];
                                       _ ->
                                           Acc
                                   end,
                            Acc1
                    end,
                    [], IdRevs),

    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    _AvgLatency = TimeSpent div length(IdRevs),
    {reply, {ok, MissingIdRevs}, State};

%% ----------- Pipelined Memached Ops --------------%%
handle_call({find_missing_pipeline, IdRevs}, _From,
            #xdc_vb_rep_xmem_worker_state{vb = Vb, mcd_loc = McdDst} =  State) when McdDst =/= undefined ->
    {ok, MissingRevs, ErrRevs} = pooled_memcached_client:find_missing_revs(McdDst, Vb, IdRevs),
    [?xdcr_trace("Error! memcached error when fetching metadata from remote for key: ~p, "
                 "just send the doc (msg: "
                 "\"unexpected response from remote memcached (vb: ~p, error: ~p)\")",
                 [Key, Vb, Error])
     || {Error, {Key, _}} <- ErrRevs],
    {reply, {ok, ErrRevs ++ MissingRevs}, State};
handle_call({find_missing_pipeline, IdRevs}, _From,
            #xdc_vb_rep_xmem_worker_state{vb = Vb,
                                          socket = Sock} =  State) ->
    TimeStart = now(),
    McHeader = #mc_header{vbucket = Vb},
    %% send out all keys
    Pid = spawn_link(fun () ->
                             _NumKeysSent =
                                 lists:foldr(fun({Key, _Rev}, Acc) ->
                                                     Entry = #mc_entry{key = Key},
                                                     ok = mc_cmd_pipeline(?CMD_GET_META, Sock,
                                                                          {McHeader, Entry}),
                                                     Acc + 1
                                             end,
                                             0, IdRevs)
                     end),

    %% receive all response
    MissingIdRevs =
        lists:foldr(fun({Key, SrcMeta}, Acc) ->
                            Missing = case receive_remote_meta_pipeline(Sock, Vb) of
                                          {key_enoent, _Error, _CAS} ->
                                              true;
                                          {ok, DestMeta, _CAS} ->
                                              case max(SrcMeta, DestMeta) of
                                                  DestMeta ->
                                                      false; %% no need to replicate
                                                  SrcMeta ->
                                                      true; %% need to replicate to remote
                                                  _ ->
                                                      false
                                              end;
                                          {timeout, ErrorMsg} ->
                                              ?xdcr_trace("Warning! timeout when fetching metadata from remote for key: ~p, "
                                                          "just send the doc (msg: ~p)", [Key, ErrorMsg]),
                                              true;
                                          {error, ErrorMsg} ->
                                              ?xdcr_error("Error! memcached error when fetching metadata for key: ~p, "
                                                          "just send the doc (msg: ~p)", [Key, ErrorMsg]),
                                              true
                                      end,
                            case Missing of
                                true ->
                                    [{Key, SrcMeta} | Acc];
                                _ ->
                                    Acc
                            end
                    end,
                    [], IdRevs),

    erlang:unlink(Pid),
    erlang:exit(Pid, kill),
    misc:wait_for_process(Pid, infinity),

    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    _AvgLatency = TimeSpent div length(IdRevs),
    {reply, {ok, MissingIdRevs}, State};

handle_call({flush_docs, DocsList}, _From,
            #xdc_vb_rep_xmem_worker_state{id = Id, vb = VBucket,
                                          socket = Socket,
                                          local_conflict_resolution = LocalConflictResolution,
                                          connection_timeout = ConnectionTimeout} =  State) ->
    TimeStart = now(),
    %% enumerate all docs and update them
    {NumDocsRepd, NumDocsRejected, Errors} =
        lists:foldr(
          fun (#doc{id = Key, rev = Rev} = Doc, {AccRepd, AccRejd, ErrorAcc}) ->
                  case flush_single_doc(Key, Socket, VBucket, LocalConflictResolution, Doc, 2) of
                      {ok, flushed} ->
                          {(AccRepd + 1), AccRejd, ErrorAcc};
                      {ok, rejected} ->
                          {AccRepd, (AccRejd + 1), ErrorAcc};
                      {error, Error} ->
                          ?xdcr_error("Error! unable to flush doc (key: ~p, rev: ~p) due to error ~p",
                                      [Key, Rev, Error]),
                          ErrorsAcc1 = [{{Key, Rev}, Error} | ErrorAcc],
                          {AccRepd, AccRejd, ErrorsAcc1}
                  end
          end,
          {0, 0, []}, DocsList),

    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    _AvgLatency = TimeSpent div length(DocsList),

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

    case Errors of
        [] ->
            ok;
        _ ->
            %% for some reason we can only return one error. Thus
            %% we're logging everything else here
            ?xdcr_error("[xmem_worker ~p for vb ~p]: Error, could not "
                        "update docs. Time spent in ms: ~p, "
                        "# of docs trying to update: ~p, error msg: ~n~p",
                        [Id, VBucket, TimeSpent, length(DocsList), Errors]),
            ok
    end,

    {reply, {ok, NumDocsRepd, NumDocsRejected}, State};

%% ----------- Pipelined Memached Ops --------------%%
handle_call({flush_docs_pipeline, DocsList}, _From,
            #xdc_vb_rep_xmem_worker_state{id = Id, vb = VBucket,
                                          mcd_loc = McdDst,
                                          connection_timeout = ConnectionTimeout} =  State)
  when McdDst =/= undefined ->

    TimeStart = now(),

    {ok, Statuses} = pooled_memcached_client:bulk_set_metas(McdDst, VBucket, DocsList),

    {Flushed, Enoent, Eexist, NotMyVb, Einval, OtherErr, ErrorKeys} = categorise_statuses(Statuses, DocsList),

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
                            "other errors: ~p",
                            [DocsListSize, (Flushed + Eexist), Enoent, NotMyVb, Einval, OtherErr]),

                %% stop replicator if too many memacched errors
                case (Flushed + Eexist + ?XDCR_XMEM_MEMCACHED_ERRORS) > DocsListSize of
                    true ->
                        {reply, {ok, Flushed, Eexist}, State};
                    _ ->
                        ErrorStr = ?format_msg("in batch of ~p docs: flushed: ~p, rejected (eexists): ~p; "
                                               "remote memcached errors: enoent: ~p, not-my-vb: ~p, invalid: ~p, "
                                               "others: ~p",
                                               [DocsListSize, Flushed, Eexist, Enoent, NotMyVb,
                                                Einval, OtherErr]),
                        {stop, {error, {ErrorStr, ErrorKeys}}, State}
                end
        end,
    RV;

handle_call({flush_docs_pipeline, DocsList}, _From,
            #xdc_vb_rep_xmem_worker_state{id = Id, vb = VBucket,
                                          socket = Sock,
                                          connection_timeout = ConnectionTimeout} =  State) ->
    TimeStart = now(),

    %% send out all docs
    Pid = spawn_link(
            fun () ->
                    _NumDocsSent =
                        lists:foldr(
                          fun (#doc{id = Key, rev = Rev, deleted = Deleted,
                                    body = DocValue} = _Doc, Acc) ->
                                  {OpCode, Data} = case Deleted of
                                                       true ->
                                                           {?CMD_DEL_WITH_META, <<>>};
                                                       _ ->
                                                           {?CMD_SET_WITH_META, DocValue}
                                                   end,
                                  McHeader = #mc_header{vbucket = VBucket, opcode = OpCode},
                                  Ext = mc_client_binary:rev_to_mcd_ext(Rev),
                                  %% CAS does not matter since remote ep_engine has capability
                                  %% to do getMeta internally before doing setWithMeta or delWithMeta
                                  CAS  = 0,
                                  McBody = #mc_entry{key = Key, data = Data, ext = Ext, cas = CAS},

                                  ok = mc_cmd_pipeline(OpCode, Sock, {McHeader, McBody}),
                                  Acc + 1
                          end,
                          0,
                          DocsList)
            end),

    %% receive all responses
    {Flushed, Enoent, Eexist, NotMyVb, Einval, Timeout, OtherErr, ErrorKeys} =
        lists:foldr(fun(#doc{id = Key} = _Doc,
                        {FlushedAcc, EnoentAcc, EexistsAcc, NotMyVbAcc, EinvalAcc, TimeoutAcc, OtherErrAcc, KeysAcc}) ->
                            case get_flush_response_pipeline(Sock, VBucket) of
                                {ok, _, _} ->
                                    {FlushedAcc + 1, EnoentAcc, EexistsAcc, NotMyVbAcc, EinvalAcc, TimeoutAcc, OtherErrAcc,
                                     KeysAcc};
                                {memcached_error, key_enoent, _} ->
                                    {FlushedAcc, EnoentAcc + 1, EexistsAcc, NotMyVbAcc, EinvalAcc, TimeoutAcc, OtherErrAcc,
                                     [Key | KeysAcc]};
                                {memcached_error, key_eexists, _} ->
                                    {FlushedAcc, EnoentAcc, EexistsAcc + 1, NotMyVbAcc, EinvalAcc, TimeoutAcc, OtherErrAcc,
                                     [Key | KeysAcc]};
                                {memcached_error, not_my_vbucket, _} ->
                                    {FlushedAcc, EnoentAcc, EexistsAcc, NotMyVbAcc + 1, EinvalAcc, TimeoutAcc, OtherErrAcc,
                                     [Key | KeysAcc]};
                                {memcached_error, einval, _} ->
                                    {FlushedAcc, EnoentAcc, EexistsAcc, NotMyVbAcc, EinvalAcc + 1, TimeoutAcc, OtherErrAcc,
                                     [Key | KeysAcc]};
                                {memcached_error, timeout, _} ->
                                    {FlushedAcc, EnoentAcc, EexistsAcc, NotMyVbAcc, EinvalAcc, TimeoutAcc + 1, OtherErrAcc,
                                     [Key | KeysAcc]};
                                {memcached_error, error, _} ->
                                    {FlushedAcc, EnoentAcc, EexistsAcc, NotMyVbAcc, EinvalAcc, TimeoutAcc, OtherErrAcc + 1,
                                     [Key | KeysAcc]}
                            end
                    end,
                    {0, 0, 0, 0, 0, 0, 0, []}, DocsList),

    erlang:unlink(Pid),
    erlang:exit(Pid, kill),
    misc:wait_for_process(Pid, infinity),

    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    _AvgLatency = TimeSpent div length(DocsList),

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
                            "(by error type, enoent: ~p, not-my-vb: ~p, einval: ~p, timeout: ~p "
                            "other errors: ~p",
                            [DocsListSize, (Flushed + Eexist), Enoent, NotMyVb, Einval, Timeout, OtherErr]),

                %% stop replicator if too many memacched errors
                case (Flushed + Eexist + ?XDCR_XMEM_MEMCACHED_ERRORS) > DocsListSize of
                    true ->
                        {reply, {ok, Flushed, Eexist}, State};
                    _ ->
                        ErrorStr = ?format_msg("in batch of ~p docs: flushed: ~p, rejected (eexists): ~p; "
                                               "remote memcached errors: enoent: ~p, not-my-vb: ~p, invalid: ~p, "
                                               "timeout: ~p, others: ~p",
                                               [DocsListSize, Flushed, Eexist, Enoent, NotMyVb,
                                                Einval, Timeout, OtherErr]),
                        {stop, {error, {ErrorStr, ErrorKeys}}, State}
                end
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

terminate(Reason, State) when Reason == normal orelse Reason == shutdown ->
    terminate_cleanup(State);

terminate(Reason, #xdc_vb_rep_xmem_worker_state{vb = Vb,
                                                id = Id,
                                                parent_server_pid = Par} = State) ->
    report_error(Reason, Vb, Par),
    ?xdcr_error("[xmem_worker ~p for vb ~p]: shutdown xmem worker, error reported to "
                "parent xmem srv: ~p", [Id, Vb, Par]),
    terminate_cleanup(State),
    ok.

terminate_cleanup(#xdc_vb_rep_xmem_worker_state{} = State) ->
    close_connection(State),
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

close_connection(#xdc_vb_rep_xmem_worker_state{socket = Socket} = State) ->
    case Socket of
        undefined ->
            ok;
        _ ->
            ok = gen_tcp:close(Socket)
    end,
    State#xdc_vb_rep_xmem_worker_state{socket = undefined, mcd_loc = undefined, status = idle}.

connect_internal(#xdc_rep_xmem_remote{} = Remote) ->
    connect_internal(?XDCR_XMEM_CONNECTION_ATTEMPTS, Remote).
connect_internal(0, _) ->
    {error, couldnt_connect_to_remote_memcached};
connect_internal(Tries, #xdc_rep_xmem_remote{} = Remote) ->

    Ip = Remote#xdc_rep_xmem_remote.ip,
    Port = Remote#xdc_rep_xmem_remote.port,
    User = Remote#xdc_rep_xmem_remote.username,
    Pass = Remote#xdc_rep_xmem_remote.password,
    try
        {ok, S} = gen_tcp:connect(Ip, Port, [binary, {packet, 0}, {active, false}]),
        ok = mc_client_binary:auth(S, {<<"PLAIN">>,
                                       {list_to_binary(User),
                                        list_to_binary(Pass)}}),
        S of
        Sock -> {ok, Sock}
    catch
        E:R ->
            ?xdcr_debug("Unable to connect: ~p, retrying.", [{E, R}]),
            timer:sleep(1000), % Avoid reconnecting too fast.
            NewTries = Tries - 1,
            connect_internal(NewTries, Remote)
    end.

-spec select_bucket_internal(#xdc_rep_xmem_remote{}, inet:socket()) -> ok |
                                                                       {memcached_error, term(), term()}.
select_bucket_internal(#xdc_rep_xmem_remote{bucket = Bucket} = _Remote, Socket) ->
    mc_client_binary:select_bucket(Socket, Bucket).

-spec is_missing(inet:socket(), integer(), {integer(), term()}) -> boolean().
is_missing(Socket, VBucket, {Key, LocalMeta}) ->
    case get_remote_meta(Socket, VBucket, Key) of
        {key_enoent, _Error, _CAS} ->
            true;
        {not_my_vbucket, Error} ->
            throw({bad_request, not_my_vbucket, Error});
        {ok, RemoteMeta, _CAS} ->
            case max(RemoteMeta, LocalMeta) of
                RemoteMeta ->
                    false; %% no need to replicate
                LocalMeta ->
                    true; %% need to replicate to remote
                _ ->
                    false
                end
    end.

-spec get_remote_meta(inet:socket(), integer(), term()) -> {ok, term(), integer()} |
                                                           {key_enoent, list(), integer()} |
                                                           {not_my_vbucket, list()}.
get_remote_meta(Socket, VBucket, Key) ->
    %% issue get_meta to remote memcached
    Reply = case mc_client_binary:get_meta(Socket, Key, VBucket) of
                {memcached_error, key_enoent, RemoteCAS} ->
                    {key_enoent, "remote_memcached_error: key does not exist", RemoteCAS};
                {memcached_error, not_my_vbucket, _} ->
                    ErrorMsg = ?format_msg("remote_memcached_error: not my vbucket (vb: ~p)", [VBucket]),
                    {not_my_vbucket, ErrorMsg};
                {ok, RemoteFullMeta, RemoteCAS, _Flags} ->
                    {ok, RemoteFullMeta, RemoteCAS}
            end,
    Reply.

-spec flush_single_doc(integer(), inet:socket(), integer(), boolean(), #doc{}, integer()) -> {ok, flushed}  |
                                                                                             {ok, rejected} |
                                                                                             {error, {term(), term()}}.
flush_single_doc(Id, _Socket, VBucket, _LocalConflictResolution,
                 #doc{id = DocId, deleted = Deleted} = _Doc, 0) ->
    ?xdcr_error("[xmem_worker ~p for vb ~p]: Error, unable to flush doc (key: ~p, deleted: ~p) "
                "to destination, maximum retry reached.",
                [Id, VBucket, DocId, Deleted]),
    {error, {bad_request, max_retry}};

flush_single_doc(Id, Socket, VBucket, LocalConflictResolution,
                 #doc{id = DocId, rev = DocRev, body = DocValue,
                      deleted = DocDeleted} = Doc, Retry) ->
    {SrcSeqNo, SrcRevId} = DocRev,
    ConflictRes = case LocalConflictResolution of
             false ->
                 {key_enoent, "no local conflict resolution, send it optimistically", 0};
             _ ->
                  get_remote_meta(Socket, VBucket, DocId)
         end,

    RV = case ConflictRes of
             {key_enoent, _ErrorMsg, DstCAS} ->
                 flush_single_doc_remote(Socket, VBucket, DocId, DocValue, DocRev, DocDeleted, DstCAS);
             {not_my_vbucket, _} ->
                 {error, {bad_request, not_my_vbucket}};
             {ok, {DstSeqNo, DstRevId}, DstCAS} ->
                 case DocDeleted of
                     false ->
                         %% for non-del mutation, compare full metadata
                         DstFullMeta = {DstSeqNo, DstRevId},
                         SrcFullMeta = {SrcSeqNo, SrcRevId},
                         case max(SrcFullMeta, DstFullMeta) of
                             DstFullMeta ->
                                 ok;
                             %% replicate src doc to destination, using
                             %% the same CAS returned from the get_remote_meta() above.
                             SrcFullMeta ->
                                 flush_single_doc_remote(Socket, VBucket, DocId, DocValue, DocRev, false, DstCAS)
                         end;
                     _ ->
                         %% for deletion, just compare seqno and CAS to match
                         %% the resolution algorithm in ep_engine:deleteWithMeta
                         <<SrcCAS:64, _SrcExp:32, _SrcFlg:32>> = SrcRevId,
                         <<DstCAS:64, _DstExp:32, _DstFlg:32>> = DstRevId,
                         SrcDelMeta = {SrcSeqNo, SrcCAS},
                         DstDelMeta = {DstSeqNo, DstCAS},
                         case max(SrcDelMeta, DstDelMeta) of
                             DstDelMeta ->
                                 ok;
                             _ ->
                                 flush_single_doc_remote(Socket, VBucket, DocId, DocValue, DocRev, true, DstCAS)
                         end
                 end
         end,

    case RV of
        retry ->
            flush_single_doc(Id, Socket, VBucket, LocalConflictResolution, Doc, Retry-1);
        ok ->
            {ok, flushed};
        {ok, key_eexists} ->
            {ok, rejected};
        _Other ->
            RV
    end.


flush_single_doc_remote(Socket, VBucket, Key, Value, Rev, DocDeleted, CAS) ->
    case mc_client_binary:update_with_rev(Socket, VBucket, Key, Value, Rev, DocDeleted, CAS) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_eexists, _} ->
            {ok, key_eexists};
        %% not supposed to see key_enoent, give another try
        {memcached_error, key_enoent, _} ->
            retry;
        %% more serious error, no retry
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            {error, {bad_request, einval}}
    end.

-spec receive_remote_meta_pipeline(inet:socket(), integer()) ->
                                          {ok, term(), term()} |
                                          {key_enoent, list(), term()} |
                                          {timeout, list()} |
                                          {error, list()}.
receive_remote_meta_pipeline(Sock, VBucket) ->
    Response = mc_binary:recv(Sock, res, ?XDCR_XMEM_CONNECTION_TIMEOUT),
    Raw = case Response of
              %% get meta of key succefully
              {ok, #mc_header{status=?SUCCESS}, #mc_entry{ext = Ext, cas = CAS}} ->
                  <<MetaFlags:32/big, ItemFlags:32/big,
                    Expiration:32/big, SeqNo:64/big>> = Ext,
                  RevId = <<CAS:64/big, Expiration:32/big, ItemFlags:32/big>>,
                  RemoteRev = {SeqNo, RevId},
                  {ok, RemoteRev, CAS, MetaFlags};

              %% key not found, which is Ok if replicating new items
              {ok, #mc_header{status=?KEY_ENOENT}, #mc_entry{cas=CAS}} ->
                  {ok, key_enoent, CAS};

              %% unexpected response returned by remote memcached, treat it as error
              {ok, #mc_header{status=OtherResponse}, #mc_entry{cas=_CAS}} ->
                  {memcached_error,
                   ?format_msg("unexpected response from remote memcached "
                               "(vb: ~p, status code: ~p, error: ~p)",
                               [VBucket, OtherResponse, mc_client_binary:map_status(OtherResponse)])};

              %% if timeout when fetching remote metadata, treat it as local wins and just send the doc
              {error, timeout} ->
                  {timeout, ?format_msg("remote memcached timeout when retrieving metadata at sock: ~p, vb: ~p",
                                                [Sock, VBucket])}
          end,

    Reply = case Raw of
                {ok, RemoteFullMeta, RemoteCAS, _Flags} ->
                    {ok, RemoteFullMeta, RemoteCAS};
                {ok, key_enoent, RemoteCAS} ->
                    {key_enoent, "key does not exist at remote", RemoteCAS};
                %% if timeout in retreiving metadata, we just send the doc optimistically
                {timeout, ErrorMsg} ->
                    {timeout, ErrorMsg};
                {memcached_error, ErrorMsg} ->
                    {error, ErrorMsg}
            end,
    Reply.

-spec get_flush_response_pipeline(inet:socket(), integer()) ->
                                         {ok, #mc_header{}, #mc_entry{}} |
                                         {memcached_error, key_enoent, integer()} |
                                         {memcached_error, key_eesxists, integer()} |
                                         {memcached_error, not_my_vbucket, integer()} |
                                         {memcached_error, einval, integer()} |
                                         {memcached_error, timeout, list()} |
                                         {memcached_error, term(), term()}.

get_flush_response_pipeline(Sock, VBucket) ->
    Response = mc_binary:recv(Sock, res, ?XDCR_XMEM_CONNECTION_TIMEOUT),
    Reply = case Response of
                {ok, #mc_header{status=?SUCCESS} = McHdr,  #mc_entry{} = McBody} ->
                    {ok, McHdr, McBody};
                {ok, #mc_header{status=?KEY_ENOENT}, #mc_entry{cas = CAS} = _McBody} ->
                    {memcached_error, key_enoent, CAS};
                {ok, #mc_header{status=?KEY_EEXISTS}, #mc_entry{cas = CAS} = _McBody} ->
                    {memcached_error, key_eexists, CAS};
                {ok, #mc_header{status=?NOT_MY_VBUCKET}, #mc_entry{cas = CAS} = _McBody} ->
                    {memcached_error, not_my_vbucket, CAS};
                {ok, #mc_header{status=?EINVAL}, #mc_entry{cas = CAS} = _McBody} ->
                    {memcached_error, einval, CAS};
                %% unexpected response returned by remote memcached, treat it as error
                {ok, #mc_header{status=OtherResponse}, #mc_entry{cas=_CAS}} ->
                    {memcached_error, error,
                     ?format_msg("unexpected response from remote memcached (vb: ~p, status code: ~p, error: ~p)",
                                 [VBucket, OtherResponse, mc_client_binary:map_status(OtherResponse)])};

                {error, timeout} ->
                    {memcached_error, timeout, ?format_msg("remote memcached timeout when flushing data at sock ~p, vb: ~p",
                                                           [Sock, VBucket])}
            end,
    Reply.

-spec mc_cmd_pipeline(integer(), inet:socket(), {#mc_header{}, #mc_entry{}}) -> ok.
mc_cmd_pipeline(Opcode, Sock, {Header, Entry}) ->
    ok = mc_binary:send(Sock, req,
                        Header#mc_header{opcode = Opcode}, mc_client_binary:ext(Opcode, Entry)),
    ok.

categorise_statuses(Statuses, DocsList) ->
    categorise_statuses_loop(Statuses, DocsList, 0, 0, 0, 0, 0, 0, []).

categorise_statuses_loop([], [], Flushed, Enoent, Eexist, NotMyVb, Einval, OtherErr, ErrorKeys) ->
    {Flushed, Enoent, Eexist, NotMyVb, Einval, OtherErr, lists:reverse(ErrorKeys)};
categorise_statuses_loop([Status | RestSt], [#doc{id=Key} | RestDocs],
                         Flushed, Enoent, Eexist, NotMyVb, Einval, OtherErr, ErrorKeys) ->
    case Status of
        success ->
            categorise_statuses_loop(RestSt, RestDocs, Flushed + 1, Enoent, Eexist, NotMyVb, Einval, OtherErr, ErrorKeys);
        key_enoent ->
            categorise_statuses_loop(RestSt, RestDocs, Flushed, Enoent + 1, Eexist, NotMyVb, Einval, OtherErr, [Key | ErrorKeys]);
        key_eexists ->
            categorise_statuses_loop(RestSt, RestDocs, Flushed, Enoent, Eexist + 1, NotMyVb, Einval, OtherErr, [Key | ErrorKeys]);
        not_my_vbucket ->
            categorise_statuses_loop(RestSt, RestDocs, Flushed, Enoent, Eexist, NotMyVb + 1, Einval, OtherErr, [Key | ErrorKeys]);
        einval ->
            categorise_statuses_loop(RestSt, RestDocs, Flushed, Enoent, Eexist, NotMyVb, Einval + 1, OtherErr, [Key | ErrorKeys]);
        _ ->
            categorise_statuses_loop(RestSt, RestDocs, Flushed, Enoent, Eexist, NotMyVb, Einval, OtherErr + 1, [Key | ErrorKeys])
    end.
