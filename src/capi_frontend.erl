%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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
-module(capi_frontend).

-compile(export_all).

-include("couch_db.hrl").
-include_lib("couch_index_merger/include/couch_index_merger.hrl").
-include_lib("couch_index_merger/include/couch_view_merger.hrl").
-include("ns_common.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

not_implemented(Arg, Rest) ->
    {not_implemented, Arg, Rest}.

do_db_req(Req, Fun) ->

    request_throttler:request(
      capi,
      fun () ->
              continue_do_db_req(Req, Fun)
      end,
      fun (Error, Reason) ->
              random:seed(os:timestamp()),
              Retry = integer_to_list(random:uniform(10)),
              couch_httpd:send_json(Req, 503, [{"Retry-After", Retry}],
                                    {[{<<"error">>, couch_util:to_binary(Error)},
                                      {<<"reason">>, couch_util:to_binary(Reason)}]})
      end).

continue_do_db_req(#httpd{mochi_req=MochiReq, user_ctx=UserCtx,
                          path_parts=[DbName | RestPathParts]} = Req, Fun) ->
    %% check auth here
    [BucketName | AfterSlash] = binary:split(DbName, <<"/">>),
    ListBucketName = ?b2l(BucketName),
    BucketConfig = case ns_bucket:get_bucket_light(ListBucketName) of
                       not_present ->
                           throw({not_found, missing});
                       {ok, X} -> X
                   end,
    case menelaus_auth:is_bucket_accessible({ListBucketName, BucketConfig}, MochiReq, false) of
        true ->
            case AfterSlash of
                [] ->
                    case couch_util:get_value(type, BucketConfig) =:= membase of
                        true ->
                            %% undefined #db fields indicate bucket database
                            Db = #db{user_ctx = UserCtx, name = DbName},
                            Fun(Req, Db);
                        _ ->
                            erlang:throw({not_found, no_couchbase_bucket_exists})
                    end;
                [AfterSlash1] ->
                    %% xdcr replicates here; to prevent a replication to
                    %% recreated bucket (without refetching vbucket map) or
                    %% even to new cluster we encode a bucket uuid in the url
                    %% and check it here;
                    {VBucket, MaybeUUID} =
                        case binary:split(AfterSlash1, <<";">>) of
                            [AfterSlash2, UUID] ->
                                {AfterSlash2, UUID};
                            _ ->
                                {AfterSlash1, undefined}
                        end,

                    BucketUUID = proplists:get_value(uuid, BucketConfig),
                    true = (BucketUUID =/= undefined),
                    case MaybeUUID =:= undefined orelse
                        BucketUUID =:= MaybeUUID of
                        true ->
                            ok;
                        false ->
                            erlang:throw({not_found, uuids_dont_match})
                    end,

                    RealDbName = <<BucketName/binary, $/, VBucket/binary>>,
                    PathParts = [RealDbName | RestPathParts],

                    %% note that we don't fake mochi_req here; but it seems
                    %% that couchdb doesn't use it in our code path
                    Req1 = Req#httpd{path_parts=PathParts},

                    couch_db_frontend:do_db_req(Req1, Fun)
            end;
        _Else ->
            throw({unauthorized, <<"password required">>})
    end.

%% This is used by 2.x xdcr checkpointing. It's only supposed to work
%% against vbucket
get_db_info(#db{name = DbName}) ->
    Bucket = case string:tokens(binary_to_list(DbName), [$/]) of
                 [BucketV, _Vb] -> BucketV;
                 _ -> throw(not_found)
             end,
    {ok, Stats0} = ns_memcached:stats(Bucket, <<"">>),
    EpStartupTime =  proplists:get_value(<<"ep_startup_time">>, Stats0),
    Info = [{db_name, DbName},
            {instance_start_time, EpStartupTime}],
    {ok, Info}.

with_subdb(#db{name = DbName}, VBucket, Fun) ->
    with_subdb(DbName, VBucket, Fun);
with_subdb(DbName, VBucket, Fun) ->
    DB = capi_utils:must_open_vbucket(DbName, VBucket),
    try
        Fun(DB)
    after
        couch_db:close(DB)
    end.

update_doc(#db{filepath = undefined, name=Name},
           #doc{id = <<"_design/",_/binary>>} = Doc, _Options) ->
    case capi_ddoc_replication_srv:update_doc(Name, Doc) of
        ok ->
            ok;
        {invalid_design_doc, _Reason} = Error ->
            throw(Error)
    end;
update_doc(_Db, _Doc, _Options) ->
    throw(not_found).


update_docs(Db,
            [#doc{id = <<?LOCAL_DOC_PREFIX, _Rest/binary>>} = Doc],
            Options) ->
    ok = couch_db:update_doc(Db, Doc, Options);

update_docs(#db{filepath = undefined, name = Name}, Docs, _Options) ->
    lists:foreach(fun(#doc{id = <<"_design/",_/binary>>} = Doc) ->
                          case capi_ddoc_replication_srv:update_doc(Name, Doc) of
                              ok ->
                                  ok;
                              {invalid_design_doc, _Reason} = Error ->
                                  throw(Error)
                          end
                  end, Docs).

update_docs(Db, Docs, Options, replicated_changes) ->
    Result =
        try
            capi_replication:update_replicated_docs(Db, Docs, Options)
        catch
            throw:unsupported ->
                exit(not_implemented(update_docs,
                                     [Db, Docs, Options, replicated_changes]))
        end,
    Result.


%% new ensure_full_commit uses CMD_CHECKPOINT_PERSISTENCE to issue
%% priority checkpoint
-spec ensure_full_commit(any(), integer()) -> {ok, binary()}.
ensure_full_commit(#db{filepath = undefined} = _Db, _RequiredSeq) ->
    {ok, <<>>};

ensure_full_commit(#db{name = DbName} = _Db, _RequiredSeq) ->
    [Bucket, VBucket] = string:tokens(binary_to_list(DbName), [$/]),

    %% create a new open checkpoint
    StartTime = now(),
    {ok, OpenCheckpointId, PersistedCkptId} = ns_memcached:create_new_checkpoint(Bucket, list_to_integer(VBucket)),

    Result = case PersistedCkptId >= (OpenCheckpointId - 1) of
                 true ->
                     ?xdcr_debug("rep (bucket: ~p, vbucket ~p) issues an empty open ckpt, no need to wait (open ckpt: ~p, persisted ckpt: ~p)",
                                 [Bucket, VBucket, OpenCheckpointId, PersistedCkptId]),
                     ok;
                 _ ->
                     %% waiting for persisted ckpt to catch up, time out in milliseconds
                     ?xdcr_debug("rep (bucket: ~p, vbucket ~p)  wait for priority chkpt persisted: ~p",
                                 [Bucket, VBucket, (OpenCheckpointId-1)]),
                     wait_priority_checkpoint_persisted(Bucket, list_to_integer(VBucket), (OpenCheckpointId - 1))
             end,

    case Result of
        ok ->
            {ok, Stats2} = ns_memcached:stats(Bucket, <<"">>),
            EpStartupTime = proplists:get_value(<<"ep_startup_time">>, Stats2),
            WorkTime = timer:now_diff(now(), StartTime) div 1000,
            ?xdcr_debug("persistend open ckpt: ~p for rep (bucket: ~p, vbucket ~p), "
                        "time spent in millisecs: ~p",
                        [OpenCheckpointId, Bucket, VBucket, WorkTime]),

            {ok, EpStartupTime};
        timeout ->
            ?xdcr_warning("Timed out when rep (bucket ~p, vb: ~p) waiting for open checkpoint "
                         "(id: ~p) to be persisted.",
                         [Bucket, VBucket, OpenCheckpointId]),
            {error, time_out_polling}
    end.

wait_priority_checkpoint_persisted(Bucket, VBucket, CheckpointId) ->
  case ns_memcached:wait_for_checkpoint_persistence(Bucket, VBucket, CheckpointId) of
      ok ->
          ?xdcr_debug("rep (bucket: ~p, vbucket ~p)  priority chkpt persisted successfully: ~p",
                      [Bucket, VBucket, CheckpointId]),
          ok;
      {memcached_error, etmpfail, _} ->
          ?xdcr_debug("rep (bucket: ~p, vbucket ~p)  fail to persist priority chkpt: ~p",
                      [Bucket, VBucket, CheckpointId]),
          timeout
  end.

check_is_admin(_Db) ->
    ok.

handle_changes(ChangesArgs, Req, #db{filepath = undefined} = Db) ->
    exit(not_implemented(handle_changes, [ChangesArgs, Req, Db]));
handle_changes(ChangesArgs, Req, Db) ->
    couch_changes:handle_changes(ChangesArgs, Req, Db).

start_view_compact(DbName, GroupId) ->
    exit(not_implemented(start_view_compact, [DbName, GroupId])).

start_db_compact(#db{filepath = undefined} = Db) ->
    exit(not_implemented(start_db_compact, [Db]));
start_db_compact(Db) ->
    couch_db:start_compact(Db).

cleanup_view_index_files(Db) ->
    exit(not_implemented(cleanup_view_index_files, [Db])).

%% TODO: check if it's useful
get_group_info(#db{filepath = undefined} = Db, DesignId) ->
    with_subdb(Db, <<"master">>,
               fun (RealDb) ->
                       couch_view:get_group_info(RealDb, DesignId)
               end);
get_group_info(Db, DesignId) ->
    couch_view:get_group_info(Db, DesignId).

create_db(DbName, UserCtx) ->
    exit(not_implemented(create_db, [DbName, UserCtx])).

delete_db(DbName, UserCtx) ->
    exit(not_implemented(delete_db, [DbName, UserCtx])).

purge_docs(Db, IdsRevs) ->
    exit(not_implemented(purge_docs, [Db, IdsRevs])).

get_missing_revs(Db, JsonDocIdRevs) ->
    Result =
        try
            capi_replication:get_missing_revs(Db, JsonDocIdRevs)
        catch
            throw:unsupported ->
                exit(not_implemented(get_missing_revs, [Db, JsonDocIdRevs]))
        end,

    Result.

open_doc(#db{filepath = undefined} = Db, <<"_design/",_/binary>> = DocId, Options) ->
    with_subdb(Db, <<"master">>,
               fun (RealDb) ->
                       couch_db:open_doc(RealDb, DocId, Options)
               end);
%% 2.x xdcr checkpointing seemingly uses for it's checkpoints in
%% _local/ docs
open_doc(Db, DocId, Options) ->
    couch_db:open_doc(Db, DocId, Options).


task_status_all() ->
    couch_db_frontend:task_status_all().

restart_core_server() ->
    exit(not_implemented(restart_core_server, [])).

increment_update_seq(Db) ->
    exit(not_implemented(increment_update_seq, [Db])).

stats_aggregator_all(Range) ->
    exit(not_implemented(stats_aggregator_all, [Range])).

stats_aggregator_get_json(Key, Range) ->
    exit(not_implemented(stats_aggregator_get_json, [Key, Range])).

stats_aggregator_collect_sample() ->
    exit(not_implemented(stats_aggregator_collect_sample, [])).

couch_doc_open(Db, DocId, Options) ->
    case open_doc(Db, DocId, Options) of
        {ok, Doc} ->
            Doc;
        Error ->
            throw(Error)
    end.

%% Grab the first vbucket we can find on this server
-spec first_vbucket(binary()) -> non_neg_integer().
first_vbucket(Bucket) ->
    {ok, Config} = ns_bucket:get_bucket(?b2l(Bucket)),
    Map = proplists:get_value(map, Config, []),
    {ok, Index} = first_vbucket(node(), Map, 0),
    Index.


-spec first_vbucket(atom(), list(), integer()) ->
                           {ok, integer()} | {error, no_vbucket_found}.
first_vbucket(_Node, [], _Acc) ->
    {error, no_vbucket_found};
first_vbucket(Node, [[Node|_] | _Rest], I) ->
    {ok, I};
first_vbucket(Node, [_First|Rest], I) ->
    first_vbucket(Node, Rest, I + 1).

has_active_vbuckets(Bucket) ->
    {ok, Config} = ns_bucket:get_bucket(?b2l(Bucket)),
    Map = proplists:get_value(map, Config, []),
    first_vbucket(node(), Map, 0) =/= {error, no_vbucket_found}.

-spec get_version() -> string().
get_version() ->
    Apps = application:loaded_applications(),
    case lists:keysearch(ns_server, 1, Apps) of
        {value, {_, _, Vsn}} -> Vsn;
        false -> "0.0.0"
    end.

-spec welcome_message(binary()) -> [{atom(), binary()}].
welcome_message(WelcomeMessage) ->
    [
     {couchdb, WelcomeMessage},
     {version, list_to_binary(couch_server:get_version())},
     {couchbase, list_to_binary(get_version())}
    ].
