-module (mc_connection).

-export([start_link/1, init/1]).
-export([respond/5, respond/4]).

-include("ns_common.hrl").
-include("mc_constants.hrl").


-record(mc_response, {
          status=0,
          extra,
          engine_specific = <<>>,
          key,
          body,
          cas=0
         }).

start_link(Socket) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [Socket])}.


to_bin(undefined) -> <<>>;
to_bin(IoList) -> IoList.

respond(Magic, Socket, OpCode, Opaque, Res) ->
    Key = to_bin(Res#mc_response.key),
    Extra = to_bin(Res#mc_response.extra),
    EngineSpecific = to_bin(Res#mc_response.engine_specific),
    KeyLen = iolist_size(Key),
    ExtraLen = iolist_size(Extra),
    EngineSpecificLen = iolist_size(EngineSpecific),
    Status = Res#mc_response.status,
    CAS = Res#mc_response.cas,
    DataBody = to_bin(Res#mc_response.body),
    DataBodyLength = iolist_size(DataBody),
    BodyLen = DataBodyLength + KeyLen + ExtraLen + EngineSpecificLen,
    ok = gen_tcp:send(Socket, [<<Magic, OpCode:8, KeyLen:16,
                               ExtraLen:8, 0:8, Status:16,
                               BodyLen:32, Opaque:32, CAS:64>>,
                               Extra,
                               EngineSpecific,
                               Key,
                               DataBody]).

respond(Socket, OpCode, Opaque, Res) ->
    respond(?RES_MAGIC, Socket, OpCode, Opaque, Res).

% Read-data special cases a 0 size to just return an empty binary.
read_data(_Socket, 0, _ForWhat) -> <<>>;
read_data(Socket, N, _ForWhat) ->
    {ok, Data} = gen_tcp:recv(Socket, N),
    Data.

read_message(Socket, KeyLen, ExtraLen, BodyLen) ->
    Extra = read_data(Socket, ExtraLen, extra),
    Key = read_data(Socket, KeyLen, key),
    Body = read_data(Socket, BodyLen - (KeyLen + ExtraLen), body),

    {Extra, Key, Body}.

do_notify_vbucket_update(BucketName, VBucket, Body) ->
    <<FileVersion:64,
      NewPos:64,
      VBStateUpdated:32,
      VBState:32,
      VBCheckpoint:64>> = Body,

    case VBStateUpdated of
        ?MCCOUCH_VB_COMPACTION_DONE ->
            case adjust_couch_db_version(BucketName, VBucket, FileVersion, NewPos) of
                ?SUCCESS ->
                    ?SUCCESS;
                Ret ->
                    Ret
            end;
        ?MCCOUCH_VB_COMPACT_OPENDB_ERROR ->
            ?SUCCESS;
        ?MCCOUCH_VB_COMPACT_RENAME_ERROR ->
            ?SUCCESS;
        _ ->
            do_notify_vbucket_update(BucketName, VBucket, FileVersion, NewPos, VBStateUpdated,
                                     VBState, VBCheckpoint)
    end.

adjust_couch_db_version(BucketName, VBucket, FileVersion, NewPos) ->
    DbName = capi_utils:build_dbname(BucketName, VBucket),
    ?log_info("Compaction of ~p is done. New Version : ~p, New Pos: ~p",
              [DbName, FileVersion, NewPos]),
    case couch_db:open_int(DbName, []) of
        {ok, Db} ->
            try
                case couch_db:jump_to_another_version(Db, FileVersion, NewPos) of
                    ok ->
                        ?SUCCESS;
                    update_behind_couchdb ->
                        ?log_error("~s vbucket ~p behind couchdb version on update.~n",
                                   [BucketName, VBucket]),
                        ?EINVAL;
                    version_didnt_change ->
                        ?log_error("Version ~p was not changed for ~s vbucket ~p by the ep-engine compactor.~n",
                                   [FileVersion, BucketName, VBucket]),
                        ?EINVAL;
                    compacting ->
                        ?log_error("~s vbucket ~p is being compacted by the couchdb compactor.~n",
                                   [BucketName, VBucket]),
                        ?EINVAL;
                    waiting_delayed_commit ->
                        ?log_error("~s vbucket ~p has uncommited changes.~n",
                                   [BucketName, VBucket]),
                        ?EINVAL;
                    was_updated ->
                        ?log_error("~s vbucket ~p was updated by couchdb during compaction.~n",
                                   [BucketName, VBucket]),
                        ?EINVAL
                end
            after
                couch_db:close(Db)
            end;
        {not_found,no_db_file} ->
            ?log_error("~s vbucket ~p file deleted or missing.~n",
                       [BucketName, VBucket]),
            ?EINVAL
    end.

do_notify_vbucket_update(BucketName, VBucket, FileVersion, NewPos, VBStateUpdated,
                         VBState, VBCheckpoint) ->
    DbName = capi_utils:build_dbname(BucketName, VBucket),
    ResponseStatus =
        case couch_db:open_int(DbName, []) of
            {ok, Db} ->
                try
                    case couch_db:update_header_pos(Db, FileVersion, NewPos) of
                        ok ->
                            ?SUCCESS;
                        retry_new_file_version ->
                            %% Retry, can happen when couchdb compacts the file
                            ?log_debug("sending back retry_new_file_version"),
                            ?ETMPFAIL;
                        update_behind_couchdb ->
                            %% shouldn't happen, somehow we wrote to a file and are behind
                            %% of what couchdb has, maybe someone is updating the file
                            %% on the couchdb side.
                            ?log_error("~s vbucket ~p behind couchdb version on update.~n",
                                       [BucketName, VBucket]),
                            ?EINVAL;
                        update_file_ahead_of_couchdb ->
                            %% shouldn't happen, somehow we wrote to a file and are ahead
                            %% of what couchdb has.
                            ?log_error("~s vbucket ~p ahead of couchdb version on update.~n",
                                       [BucketName, VBucket]),
                            ?EINVAL
                    end
                after
                    couch_db:close(Db)
                end;
            {not_found,no_db_file} ->
                ?log_error("~s vbucket ~p file deleted or missing.~n",
                           [BucketName, VBucket]),
                %% Somehow the file we updated can't be found. What?
                ?EINVAL
        end,
    if
        (VBStateUpdated band 1) =:= 1 ->
            VBStateAtom = vbucket_state_to_atom(VBState),
            Event = {set_vbucket,
                     binary_to_list(BucketName),
                     VBucket,
                     VBStateAtom,
                     VBCheckpoint},
            gen_event:sync_notify(mc_couch_events, Event),
            ?log_debug("Signaled mc_couch_event: ~p", [Event]);
        true ->
            ok
    end,

    ResponseStatus.

-spec vbucket_state_to_atom(int_vb_state()) -> atom().
vbucket_state_to_atom(?VB_STATE_ACTIVE) ->
    active;
vbucket_state_to_atom(?VB_STATE_REPLICA) ->
    replica;
vbucket_state_to_atom(?VB_STATE_PENDING) ->
    pending;
vbucket_state_to_atom(?VB_STATE_DEAD) ->
    dead.

do_delete_vbucket(BucketName, VBucket) ->
    ?log_debug("Notifying mc_couch_events of vbucket deletion: ~s/~p", [BucketName, VBucket]),
    gen_event:sync_notify(mc_couch_events,
                          {delete_vbucket, binary_to_list(BucketName), VBucket}),

    DbName = capi_utils:build_dbname(BucketName, VBucket),
    ?log_info("Deleting vbucket: ~s/~p", [BucketName, VBucket]),
    couch_server:delete(DbName, []),
    ?SUCCESS.

just_process_message(BucketName, ?CMD_NOTIFY_VBUCKET_UPDATE, VBucket, Extra, Key, Body, CAS) ->
    <<>> = Extra,
    <<>> = Key,
    0 = CAS,
    do_notify_vbucket_update(BucketName, VBucket, Body);
just_process_message(BucketName, ?CMD_DELETE_VBUCKET, VBucket, Extra, Key, Body, CAS) ->
    <<>> = Extra,
    <<>> = Key,
    <<>> = Body,
    0 = CAS,
    do_delete_vbucket(BucketName, VBucket);
just_process_message(_BucketName, ?FLUSH, _, _, _, _, _) ->
    ?log_info("FLUSHING ALL THE THINGS!", []),
    exit(unsupported).

handle_message(Socket, BucketName, OpCode, VBucket, Extra, Key, Body, Opaque, CAS) ->
    ResponseStatus = just_process_message(BucketName, OpCode, VBucket, Extra, Key, Body, CAS),
    respond(Socket, OpCode, Opaque, #mc_response{status = ResponseStatus}).

read_full_message(Socket, Continuation) ->
    case gen_tcp:recv(Socket, ?HEADER_LEN) of
        {ok, <<?REQ_MAGIC:8, OpCode:8, KeyLen:16,
               ExtraLen:8, 0:8, VBucket:16,
               BodyLen:32,
               Opaque:32,
               CAS:64>>} ->
            {Extra, Key, Body} = read_message(Socket, KeyLen, ExtraLen, BodyLen),
            {ok, Continuation(Socket, OpCode, VBucket, Extra, Key, Body, Opaque, CAS)};
        Crap ->
            Crap
    end.

handle_select_bucket(Socket, ?CMD_SELECT_BUCKET,
                      _VBucket, <<>> = _Extra, BucketName, <<>> = _Body, Opaque, 0 = _CAS) ->
    respond(Socket, ?CMD_SELECT_BUCKET, Opaque, #mc_response{}),
    BucketName;
handle_select_bucket(_Socket, OpCode, VBucket, Extra, Key, Body, Opaque, CAS) ->
    ?log_error("Extected select bucket as first command but got: ~p",
               [{OpCode, VBucket, Extra, Key, Body, Opaque, CAS}]),
    %% not including potentially larger body
    exit({bad_initial_command, OpCode, VBucket, Extra, Key, Opaque, CAS}).

make_process_message_function(BucketName) ->
    fun (Socket, OpCode, VBucket, Extra, Key, Body, Opaque, CAS) ->
            handle_message(Socket, BucketName, OpCode, VBucket, Extra, Key, Body, Opaque, CAS)
    end.

init(Socket) ->
    case read_full_message(Socket, fun handle_select_bucket/8) of
        {ok, BucketName} ->
            ProcessFunction = make_process_message_function(BucketName),
            run_loop(Socket, ProcessFunction);
        Crap ->
            ?log_error("Failed to initialize mccouch connection: ~p", [Crap]),
            exit({init_failed, Crap})
    end.


run_loop(Socket, ProcessFunction) ->
    case read_full_message(Socket, ProcessFunction) of
        {ok, ok} ->
            run_loop(Socket, ProcessFunction);
        {error, closed} ->
            ?log_info("mccouch connection was normally closed"),
            ok;
        {error, Error} ->
            ?log_error("Got error reading mccouch command: ~p", [Error]),
            exit({error_reading_command, Error})
    end.

