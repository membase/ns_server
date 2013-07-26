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
-export([find_missing/2, flush_docs/2, ensure_full_commit/2]).
-export([connect/2, select_bucket/2, disconnect/1, stop/1]).

-export([find_missing_pipeline/2, flush_docs_pipeline/2]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").


%% -------------------------------------------------------------------------- %%
%% ---                         public functions                           --- %%
%% -------------------------------------------------------------------------- %%
start_link(Vb, Id, Parent, Options) ->
    gen_server:start_link(?MODULE, {Vb, Id, Parent, Options}, []).

%% gen_server behavior callback functions
init({Vb, Id, Parent, Options}) ->
    process_flag(trap_exit, true),

    Errs = ringbuffer:new(?XDCR_ERROR_HISTORY),
    InitState = #xdc_vb_rep_xmem_worker_state{
      id = Id,
      vb = Vb,
      parent_server_pid = Parent,
      options = Options,
      status  = init,
      statistics = #xdc_vb_rep_xmem_statistics{},
      socket = undefined,
      time_init = calendar:now_to_local_time(erlang:now()),
      time_connected = 0,
      error_reports = Errs},

    {ok, InitState}.

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

-spec ensure_full_commit(pid(), list()) -> {ok, binary()} |
                                           {error, time_out_polling}.
ensure_full_commit(Server, RemoteBucket) ->
    gen_server:call(Server, {ensure_full_commit, RemoteBucket}, infinity).

stop(Server) ->
    gen_server:cast(Server, stop).

handle_info({'EXIT',_Pid, normal}, St) ->
    {noreply, St};

handle_info({'EXIT',_Pid, Reason}, St) ->
    {stop, Reason, St}.

handle_call({connect, #xdc_rep_xmem_remote{} = Remote}, {_Pid, _Tag},
            #xdc_vb_rep_xmem_worker_state{id = Id, vb = Vb} =  State) ->
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
                                                   status = connected}};

handle_call(disconnect, {_Pid, _Tag}, #xdc_vb_rep_xmem_worker_state{} =  State) ->
    State1 = close_connection(State),
    {reply, ok, State1};

handle_call({select_bucket, #xdc_rep_xmem_remote{} = Remote}, {_Pid, _Tag},
            #xdc_vb_rep_xmem_worker_state{id = Id, vb = Vb, socket = Socket} =  State) ->
    %% establish connection to remote memcached
    case select_bucket_internal(Remote, Socket) of
        ok ->
            ok;
        _ ->
            ?xdcr_error("[xmem_worker ~p for vb ~p]: unable to select remote bucket ~p at node ~p",
                        [Id, Vb,
                         Remote#xdc_rep_xmem_remote.bucket,
                         Remote#xdc_rep_xmem_remote.ip])
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
                                                  SrcMeta ->
                                                      true; %% need to replicate to remote
                                                  DestMeta ->
                                                      false; %% no need to replicate
                                                  _ ->
                                                      false
                                              end;
                                          {error, Error, Msg} ->
                                              ?xdcr_error("Error! err ~p (error msg: ~p) found in replication, "
                                                          "abort the worker thread", [Error, Msg]),
                                              throw({bad_request, Error, Msg})
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
                                          socket = Socket} =  State) ->
    TimeStart = now(),
    %% enumerate all docs and update them
    {NumDocsRepd, NumDocsRejected, Errors} =
        lists:foldr(
          fun (#doc{id = Key, rev = Rev} = Doc, {AccRepd, AccRejd, ErrorAcc}) ->
                  case flush_single_doc(Key, Socket, VBucket, Doc, 2) of
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
    {value, DefaultConnTimeout} = ns_config:search(xdcr_connection_timeout),
    DefTimeoutSecs = misc:getenv_int("XDCR_CONNECTION_TIMEOUT", DefaultConnTimeout),
    TimeSpentSecs = TimeSpent div 1000,
    case TimeSpentSecs > DefTimeoutSecs of
        true ->
            ?xdcr_error("[xmem_worker ~p for vb ~p]: update ~p docs takes too long to finish!"
                        "(total time spent: ~p secs, default connection time out: ~p secs)",
                        [Id, VBucket, length(DocsList), TimeSpentSecs, DefTimeoutSecs]);
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
                                          socket = Sock} =  State) ->
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
    {Flushed, Enoent, Eexist, NotMyVb, Einval, Timeout, ErrorKeys} =
        lists:foldr(fun(#doc{id = Key} = _Doc,
                        {FlushedAcc, EnoentAcc, EexistsAcc, NotMyVbAcc, EinvalAcc, TimeoutAcc, KeysAcc}) ->
                            case get_flush_response_pipeline(Sock, VBucket) of
                                {ok, _, _} ->
                                    {FlushedAcc + 1, EnoentAcc, EexistsAcc, NotMyVbAcc, EinvalAcc, TimeoutAcc,
                                     KeysAcc};
                                {memcached_error, key_enoent, _} ->
                                    {FlushedAcc, EnoentAcc + 1, EexistsAcc, NotMyVbAcc, EinvalAcc, TimeoutAcc,
                                    lists:append(KeysAcc, [Key])};
                                {memcached_error, key_eexists, _} ->
                                    {FlushedAcc, EnoentAcc, EexistsAcc + 1, NotMyVbAcc, EinvalAcc, TimeoutAcc,
                                     lists:append(KeysAcc, [Key])};
                                {memcached_error, not_my_vbucket, _} ->
                                    {FlushedAcc, EnoentAcc, EexistsAcc, NotMyVbAcc + 1, EinvalAcc, TimeoutAcc,
                                     lists:append(KeysAcc, [Key])};
                                {memcached_error, einval, _} ->
                                    {FlushedAcc, EnoentAcc, EexistsAcc, NotMyVbAcc, EinvalAcc + 1, TimeoutAcc,
                                     lists:append(KeysAcc, [Key])};
                                {memcached_error, timeout, _} ->
                                    {FlushedAcc, EnoentAcc, EexistsAcc, NotMyVbAcc, EinvalAcc, TimeoutAcc + 1,
                                     lists:append(KeysAcc, [Key])}
                            end
                    end,
                    {0, 0, 0, 0, 0, 0, []}, DocsList),

    erlang:unlink(Pid),
    erlang:exit(Pid, kill),
    misc:wait_for_process(Pid, infinity),

    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    _AvgLatency = TimeSpent div length(DocsList),

    %% dump error msg if timeout
    {value, DefaultConnTimeout} = ns_config:search(xdcr_connection_timeout),
    DefTimeoutSecs = misc:getenv_int("XDCR_CONNECTION_TIMEOUT", DefaultConnTimeout),
    TimeSpentSecs = TimeSpent div 1000,
    case TimeSpentSecs > DefTimeoutSecs of
        true ->
            ?xdcr_error("[xmem_worker ~p for vb ~p]: update ~p docs takes too long to finish!"
                          "(total time spent: ~p secs, default connection time out: ~p secs)",
                          [Id, VBucket, length(DocsList), TimeSpentSecs, DefTimeoutSecs]);
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
                ?xdcr_error("out of ~p docs, succ to flush ~p docs, fail to flush others "
                            "(by error type, enoent: ~p, not-my-vb: ~p, einval: ~p, timeout: ~p~n"
                            "list of keys with errors: ~p",
                            [DocsListSize, (Flushed + Eexist), Enoent, NotMyVb, Einval, Timeout,
                             ErrorKeys]),

                %% stop replicator if two many memacched errors
                 case (Flushed + Eexist + ?XDCR_XMEM_MEMCACHED_ERRORS) > DocsListSize of
                    true ->
                         {reply, {ok, Flushed, Eexist}, State};
                     _ ->
                         {stop, {error, {Flushed, Eexist, Enoent, NotMyVb, Einval, Timeout}}, State}
                 end
        end,
    RV;

handle_call({ensure_full_commit, Bucket}, _From,
            #xdc_vb_rep_xmem_worker_state{vb = VBucket,
                                          socket = Socket,
                                          statistics = OldStat} = State) ->
    RV = ensure_full_commit_internal(Socket, Bucket, VBucket),
    CkptIssued = OldStat#xdc_vb_rep_xmem_statistics.ckpt_issued,
    CkptFailed = OldStat#xdc_vb_rep_xmem_statistics.ckpt_failed,

    Stat = case RV of
               {ok, _} ->
                   OldStat#xdc_vb_rep_xmem_statistics{ckpt_issued = CkptIssued + 1};
               _ ->
                   ?xdcr_error("failed to issue a ckpt for vb ~p (bucket: ~p), "
                               "total ckpt issued (succ: ~p, fail: ~p)",
                               [VBucket, Bucket, CkptIssued, (CkptFailed+1)]),
                   OldStat#xdc_vb_rep_xmem_statistics{ckpt_failed = CkptFailed + 1}
           end,
    {reply, RV, State#xdc_vb_rep_xmem_worker_state{statistics = Stat}};

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
    ?xdcr_error("[xmem_worker ~p for vb ~p]: Shutting xmem worker for reason: ~p",
                [Id, Vb, Reason]),
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
    String = iolist_to_binary(io_lib:format("~s - Error replicating vbucket ~p: ~p",
                                            [Time, Vb, Err])),
    gen_server:cast(Parent, {report_error, {RawTime, String}}).

close_connection(#xdc_vb_rep_xmem_worker_state{socket = Socket} = State) ->
    case Socket of
        undefined ->
            ok;
        _ ->
            ok = gen_tcp:close(Socket)
    end,
    State#xdc_vb_rep_xmem_worker_state{socket = undefined, status = idle}.

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
                LocalMeta ->
                    true; %% need to replicate to remote
                RemoteMeta ->
                    false; %% no need to replicate
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

-spec flush_single_doc(integer(), inet:socket(), integer(), #doc{}, integer()) -> {ok, flushed}  |
                                                                                  {ok, rejected} |
                                                                                  {error, {term(), term()}}.
flush_single_doc(Id, _Socket, VBucket, #doc{id = DocId} = _Doc, 0) ->
    ?xdcr_error("[xmem_worker ~p for vb ~p]: Error, unable to flush doc (key: ~p) "
                "to destination, maximum retry reached.",
                [Id, VBucket, DocId]),
    {error, {bad_request, max_retry}};

flush_single_doc(Id, Socket, VBucket,
                 #doc{id = DocId, rev = DocRev, body = DocValue,
                      deleted = DocDeleted} = Doc, Retry) ->
    {SrcSeqNo, SrcRevId} = DocRev,
    ConflictRes = case xdc_rep_utils:is_local_conflict_resolution() of
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
                DstFullMeta = {DstSeqNo, DstRevId},
                SrcFullMeta = {SrcSeqNo, SrcRevId},
                case max(SrcFullMeta, DstFullMeta) of
                    DstFullMeta ->
                        ok;
                    %% replicate src doc to destination, using
                    %% the same CAS returned from the get_remote_meta() above.
                    SrcFullMeta ->
                        flush_single_doc_remote(Socket, VBucket, DocId, DocValue, DocRev, DocDeleted, DstCAS)
                end
        end,

    case RV of
        retry ->
            flush_single_doc(Id, Socket, VBucket, Doc, Retry-1);
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

-spec ensure_full_commit_internal(inet:socket(), list(), integer()) -> {ok, binary()} |
                                                                       {error, time_out_polling}.
ensure_full_commit_internal(Socket, Bucket, VBucket) ->
    %% create a new open checkpoint
    StartTime = now(),
    {ok, OpenCheckpointId, PersistedCkptId} = mc_client_binary:create_new_checkpoint(Socket, VBucket),

    Result = case PersistedCkptId >= (OpenCheckpointId - 1) of
                 true ->
                     ?xdcr_debug("replication to remote (bucket: ~p, vbucket ~p) issues an empty open ckpt, "
                                 "no need to wait (open ckpt: ~p, persisted ckpt: ~p)",
                                 [Bucket, VBucket, OpenCheckpointId, PersistedCkptId]),
                     ok;
                 _ ->
                     %% waiting for persisted ckpt to catch up, time out in milliseconds
                     ?xdcr_debug("replication to (bucket: ~p, vbucket ~p)  wait for priority chkpt persisted: ~p, "
                                 "current persisted chkpt: ~p",
                                 [Bucket, VBucket, (OpenCheckpointId-1), PersistedCkptId]),
                     wait_priority_checkpoint_persisted(Socket, Bucket, VBucket, (OpenCheckpointId - 1))
             end,

    RV = case Result of
             ok ->
                 {ok, Stats2} = mc_binary:quick_stats(Socket, <<>>,
                                                      fun (K, V, Acc) ->
                                                              [{K, V} | Acc]
                                                      end, []),

                 EpStartupTime = proplists:get_value(<<"ep_startup_time">>, Stats2),
                 WorkTime = timer:now_diff(now(), StartTime) div 1000,
                 ?xdcr_debug("persistend open ckpt: ~p for rep (bucket: ~p, vbucket ~p), "
                             "time spent in millisecs: ~p",
                             [OpenCheckpointId, Bucket, VBucket, WorkTime]),

                 {ok, EpStartupTime};
             timeout ->
                 ?xdcr_error("Alert! timeout when rep (bucket ~p, vb: ~p) waiting for open checkpoint "
                               "(id: ~p) to be persisted.",
                               [Bucket, VBucket, OpenCheckpointId]),
                 {error, time_out_polling}
         end,
    RV.

-spec wait_priority_checkpoint_persisted(inet:socket(), list(), integer(), integer()) -> ok | timeout.
wait_priority_checkpoint_persisted(Socket, Bucket, VBucket, CheckpointId) ->
  case mc_client_binary:wait_for_checkpoint_persistence(Socket, VBucket, CheckpointId) of
      ok ->
          ok;
      {memcached_error, etmpfail, _} ->
          ?xdcr_error("rep (bucket: ~p, vbucket ~p)  fail to persist priority chkpt: ~p",
                      [Bucket, VBucket, CheckpointId]),
          timeout;
      ErrorMsg ->
          ?xdcr_error("rep (bucket: ~p, vbucket ~p)  fail to persist priority chkpt: ~p (unrecgnized error: ~p)",
                      [Bucket, VBucket, CheckpointId, ErrorMsg]),
          timeout
  end.

-spec receive_remote_meta_pipeline(inet:socket(), integer()) ->
                                          {ok, term(), term()} |
                                          {key_enoent, list(), term()} |
                                          {error, term(), term()}.
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
              %% if timeout
              {error, timeout} ->
                  {memcached_error, timeout, ?format_msg("remote memcached timeout at sock: ~p, vb: ~p",
                                                         [Sock, VBucket])};
              %% other errors
              Response ->
                  ?xdcr_error("unrecognized response from memcached: ~p (sock: ~p, vb: ~p),",
                              [Response, Sock, VBucket]),
                  mc_client_binary:process_error_response(Response)
          end,

    Reply = case Raw of
                {ok, RemoteFullMeta, RemoteCAS, _Flags} ->
                    {ok, RemoteFullMeta, RemoteCAS};
                {ok, key_enoent, RemoteCAS} ->
                    {key_enoent, "key does not exist at remote", RemoteCAS};
                {memcached_error, not_my_vbucket, _} ->
                    ErrorMsg = ?format_msg("remote_memcached_error: not my vbucket (vb: ~p)", [VBucket]),
                    {error, not_my_vbucket, ErrorMsg};
                {memcached_error, Status, Msg} ->
                    ErrorMsg = ?format_msg("remote_memcached_error: status ~p, msg: ~p (vb: ~p)",
                                           [Status, Msg, VBucket]),
                    {error, memcached_error, ErrorMsg}
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
                {error, timeout} ->
                    {memcached_error, timeout, ?format_msg("remote memcached timeout at sock ~p, vb: ~p",
                                                           [Sock, VBucket])};
                Response ->
                    ?xdcr_error("unrecognized response from memcached: ~p (sock: ~p, vb: ~p),",
                                [Response, Sock, VBucket]),
                    mc_client_binary:process_error_response(Response)
            end,
    Reply.

-spec mc_cmd_pipeline(integer(), inet:socket(), {#mc_header{}, #mc_entry{}}) -> ok.
mc_cmd_pipeline(Opcode, Sock, {Header, Entry}) ->
    ok = mc_binary:send(Sock, req,
                        Header#mc_header{opcode = Opcode}, mc_client_binary:ext(Opcode, Entry)),
    ok.
