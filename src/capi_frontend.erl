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
-include("ns_common.hrl").

-compile(export_all).

not_implemented(_Arg, _Rest) ->
    exit({_Arg, not_implemented}).

do_db_req(#httpd{user_ctx=UserCtx,path_parts=[DbName|_]}=Req, Fun) ->
    case couch_db:open(DbName, [{user_ctx, UserCtx}]) of
        {ok, Db} ->
            try
                Fun(Req, Db)
                after
                    catch couch_db:close(Db)
                end;
        Error ->
            throw(Error)
    end.


%% Required for replication
get_db_info(Db) ->
    case is_couchbase_db(Db#db.name) of
        false -> couch_db:get_db_info(Db)
    end.


with_vbucket_db(Db, VBucket, Fun) ->
    DbName = iolist_to_binary([Db#db.name, $/, integer_to_list(VBucket)]),
    {ok, RealDb} = couch_db:open(DbName, []),
    try
        Fun(RealDb)
    after
        couch_db:close(RealDb)
    end.

update_doc(Db, Doc, Options) ->
    case is_couchbase_db(Db#db.name) of
        false -> couch_db:update_doc(Db, Doc, Options)
    end.

update_doc(Db, Doc, Options, UpdateType) ->
    case is_couchbase_db(Db#db.name) of
        false -> couch_db:update_doc(Db, Doc, Options, UpdateType)
    end.

ensure_full_commit(Db, RequiredSeq) ->
    UpdateSeq = couch_db:get_update_seq(Db),
    CommittedSeq = couch_db:get_committed_update_seq(Db),
    case RequiredSeq of
        undefined ->
            couch_db:ensure_full_commit(Db);
        _ ->
            if RequiredSeq > UpdateSeq ->
                    throw({bad_request,
                           "can't do a full commit ahead of current update_seq"});
               RequiredSeq > CommittedSeq ->
                    couch_db:ensure_full_commit(Db);
               true ->
                    {ok, Db#db.instance_start_time}
            end
    end.

check_is_admin(_Db) ->
    ok.



handle_changes(ChangesArgs, Req, Db) ->
    couch_changes:handle_changes(ChangesArgs, Req, Db).

start_view_compact(DbName, GroupId) ->
    exit(not_implemented(start_view_compact, [DbName, GroupId])).

start_db_compact(Db) ->
    exit(not_implemented(start_db_compact, [Db])).

cleanup_view_index_files(Db) ->
    couch_view:cleanup_index_files(Db).

get_group_info(Db, DesignId) ->
    with_vbucket_db(Db, 0,
                    fun (RealDb) ->
                            couch_view:get_group_info(RealDb, DesignId)
                    end).

create_db(DbName, UserCtx) ->
    exit(not_implemented(create_db, [DbName, UserCtx])).

delete_db(DbName, UserCtx) ->
    exit(not_implemented(delete_db, [DbName, UserCtx])).

update_docs(Db, Docs, Options) ->
    case is_couchbase_db(Db#db.name) of
        false -> couch_db:update_docs(Db, Docs, Options)
    end.

update_docs(Db, Docs, Options, Type) ->
    case is_couchbase_db(Db#db.name) of
        false -> couch_db:update_docs(Db, Docs, Options, Type)
    end.

purge_docs(Db, IdsRevs) ->
    %% couch_db:purge_docs(Db, IdsRevs).
    exit(not_implemented(purge_docs, [Db, IdsRevs])).

get_missing_revs(Db, JsonDocIdRevs) ->
    %% couch_db:get_missing_revs(Db, JsonDocIdRevs).
    exit(not_implemented(get_missing_revs, [Db, JsonDocIdRevs])).

set_security(Db, SecurityObj) ->
    exit(not_implemented(set_security, [Db, SecurityObj])).
    %% couch_db:set_security(Db, SecurityObj).

get_security(Db) ->
    exit(not_implemented(get_security, [Db])).
    %% couch_db:get_security(Db).

set_revs_limit(Db, Limit) ->
    exit(not_implemented(set_revs_limit, [Db, Limit])).
    %% couch_db:set_revs_limit(Db, Limit).

get_revs_limit(Db) ->
    exit(not_implemented(get_revs_limit, [Db])).
    %% couch_db:get_revs_limit(Db).


open_doc_revs(Db, DocId, Revs, Options) ->
    case is_couchbase_db(Db#db.name) of
        false -> couch_db:open_doc_revs(Db, DocId, Revs, Options)
    end.


open_doc(Db, DocId, Options) ->
    case is_couchbase_db(Db#db.name) of
        false -> couch_db:open_doc(Db, DocId, Options)
    end.

make_attachment_fold(_Att, ReqAcceptsAttEnc) ->
    case ReqAcceptsAttEnc of
        false -> fun couch_doc:att_foldl_decode/3;
        _ -> fun couch_doc:att_foldl/3
    end.

range_att_foldl(Att, From, To, Fun, Acc) ->
    couch_doc:range_att_foldl(Att, From, To, Fun, Acc).

-spec all_databases() -> {ok, [binary()]}.
all_databases() ->
    couch_server:all_databases().
%{ok, [?l2b(Name) || Name <- ns_bucket:get_bucket_names(membase)]}.

task_status_all() ->
    couch_task_status:all().

restart_core_server() ->
    exit(not_implemented(restart_core_server, [])).

config_all() ->
    exit(not_implemented(config_all, [])).

config_get(Section) ->
    exit(not_implemented(config_get, [Section])).

config_get(Section, Key, Default) ->
    exit(not_implemented(config_get, [Section, Key, Default])).

config_set(Section, Key, Value, Persist) ->
    exit(not_implemented(config_set, [Section, Key, Value, Persist])).

config_delete(Section, Key, Persist) ->
    exit(not_implemented(config_delete, [Section, Key, Persist])).

increment_update_seq(Db) ->
    exit(not_implemented(increment_update_seq, [Db])).

stats_aggregator_all(Range) ->
    exit(not_implemented(stats_aggregator_all, [Range])).

stats_aggregator_get_json(Key, Range) ->
    exit(not_implemented(stats_aggregator_get_json, [Key, Range])).

stats_aggregator_collect_sample() ->
    exit(not_implemented(stats_aggregator_collect_sample, [])).

couch_doc_open(Db, DocId, Rev, Options) ->
    case Rev of
    nil -> % open most recent rev
        case open_doc(Db, DocId, Options) of
        {ok, Doc} ->
            Doc;
         Error ->
             throw(Error)
         end;
  _ -> % open a specific rev (deletions come back as stubs)
      case open_doc_revs(Db, DocId, [Rev], Options) of
          {ok, [{ok, Doc}]} ->
              Doc;
          {ok, [{{not_found, missing}, Rev}]} ->
              throw(not_found);
          {ok, [Else]} ->
              throw(Else)
      end
  end.


is_couchbase_db(Name) ->
    nomatch =:= re:run(Name, <<"/">>).
