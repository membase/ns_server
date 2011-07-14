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

-compile(export_all).

not_implemented(Arg, Rest) ->
    {not_implemented, Arg, Rest}.

do_db_req(#httpd{user_ctx=UserCtx,path_parts=[DbName|_]}=Req, Fun) ->
    case is_couchbase_db(DbName) of
        true ->
            %% undefined #db fields indicate bucket database
            Db = #db{user_ctx = UserCtx, name = DbName},
            Fun(Req, Db);
        false ->
            couch_db_frontend:do_db_req(Req, Fun)
    end.

get_db_info(#db{filepath = undefined} = Db) ->
    exit(not_implemented(get_db_info, [Db]));
get_db_info(Db) ->
    couch_db:get_db_info(Db).

with_subdb(Db, VBucket, Fun) ->
    SubName = case is_binary(VBucket) of
                  true -> VBucket;
                  _ -> integer_to_list(VBucket)
              end,
    DbName = iolist_to_binary([Db#db.name, $/, SubName]),
    UserCtx = #user_ctx{roles=[<<"_admin">>]},
    {ok, RealDb} = couch_db:open(DbName, [{user_ctx, UserCtx}]),
    try
        Fun(RealDb)
    after
        couch_db:close(RealDb)
    end.


update_doc(Db, Doc, Options) ->
    update_doc(Db, Doc, Options, interactive_edit).

update_doc(#db{filepath = undefined} = Db, #doc{id = <<"_design/",_/binary>>} = Doc, Options, UpdateType) ->
    with_subdb(Db, <<"master">>,
               fun (RealDb) ->
                       couch_db:update_doc(RealDb, Doc, Options, UpdateType)
               end);

update_doc(#db{filepath = undefined, name = Name} = Db,
           #doc{id = DocId} = Doc, Options, UpdateType) ->
    {_, Node} = cb_util:vbucket_from_id(?b2l(Name), DocId),
    rpc:call(Node, capi_crud, update_doc, [Db, Doc, Options, UpdateType]);

update_doc(Db, Doc, Options, UpdateType) ->
    couch_db:update_doc(Db, Doc, Options, UpdateType).

update_docs(Db, Docs, Options) ->
    update_docs(Db, Docs, Options, interactive_edit).

update_docs(#db{filepath = undefined} = Db, Docs, Options, Type) ->
    {DesignDocs, [] = NormalDocs} =
        lists:partition(fun (#doc{id = <<"_design/", _/binary>>}) -> true;
                            (_) -> false
                        end, Docs),
    case update_design_docs(Db, DesignDocs, Options, Type) of
        {ok, DDocResults} ->
            %% TODO: work out error handling here
            {ok, NormalResults} = update_normal_docs(Db, NormalDocs,
                                                     Options, Type),
            %% TODO: Looks like we need to reorder results here
            {ok, NormalResults ++ DDocResults};
        Error ->
            %% TODO: work out error handling here
            Error
    end;
update_docs(Db, Docs, Options, Type) ->
    couch_db:update_docs(Db, Docs, Options, Type).


update_design_docs(#db{filepath = undefined} = Db, Docs, Options, Type) ->
    with_subdb(Db, <<"master">>,
               fun (RealDb) ->
                       couch_db:update_docs(RealDb, Docs, Options, Type)
               end).

update_normal_docs(_Db, [], _Options, _Type) ->
    {ok, []};
update_normal_docs(#db{filepath = undefined} = Db, Docs, Options, Type) ->
    exit(not_implemented(update_normal_docs, [Db, Docs, Options, Type]));
update_normal_docs(Db, Docs, Options, Type) ->
    exit(not_implemented(update_normal_docs, [Db, Docs, Options, Type])).

-spec ensure_full_commit(any(), integer()) -> {ok, binary()}.
ensure_full_commit(#db{filepath = undefined} = _Db, _RequiredSeq) ->
    {ok, <<"0">>};
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

handle_changes(ChangesArgs, Req, #db{filepath = undefined} = Db) ->
    exit(not_implemented(handle_changes, [ChangesArgs, Req, Db]));
handle_changes(ChangesArgs, Req, Db) ->
    couch_changes:handle_changes(ChangesArgs, Req, Db).

start_view_compact(DbName, GroupId) ->
    exit(not_implemented(start_view_compact, [DbName, GroupId])).

start_db_compact(#db{filepath = undefined} = Db) ->
    couch_db:start_compact(Db);
start_db_compact(Db) ->
    exit(not_implemented(start_db_compact, [Db])).

cleanup_view_index_files(Db) ->
    couch_view:cleanup_index_files(Db).

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

open_doc_revs(#db{filepath = undefined} = Db, <<"_design/",_/binary>> = DocId, Revs, Options) ->
    with_subdb(Db, <<"master">>,
               fun (RealDb) ->
                       couch_db:open_doc_revs(RealDb, DocId, Revs, Options)
               end);
open_doc_revs(#db{filepath = undefined} = Db, DocId, Revs, Options) ->
    exit(not_implemented(open_doc_revs, [Db, DocId, Revs, Options]));
open_doc_revs(Db, DocId, Revs, Options) ->
    couch_db:open_doc_revs(Db, DocId, Revs, Options).


open_doc(#db{filepath = undefined} = Db, <<"_design/",_/binary>> = DocId, Options) ->
    with_subdb(Db, <<"master">>, fun (RealDb) ->
        couch_db:open_doc(RealDb, DocId, Options)
    end);

open_doc(#db{filepath = undefined, name = Name} = Db, DocId, Options) ->
    {_, Node} = cb_util:vbucket_from_id(?b2l(Name), DocId),
    rpc:call(Node, capi_crud, open_doc, [Db, DocId, Options]);

open_doc(Db, DocId, Options) ->
    couch_db:open_doc(Db, DocId, Options).


make_attachment_fold(_Att, ReqAcceptsAttEnc) ->
    case ReqAcceptsAttEnc of
        false -> fun couch_doc:att_foldl_decode/3;
        _ -> fun couch_doc:att_foldl/3
    end.

range_att_foldl(Att, From, To, Fun, Acc) ->
    couch_doc:range_att_foldl(Att, From, To, Fun, Acc).

-spec all_databases() -> {ok, [binary()]}.
all_databases() ->
    {ok, DBs} = couch_server:all_databases(),
    {ok, DBs ++ [?l2b(Name) || Name <- ns_bucket:get_bucket_names(membase)]}.

task_status_all() ->
    %% TODO: why ?
    couch_task_status:all().

restart_core_server() ->
    exit(not_implemented(restart_core_server, [])).

config_all() ->
    couch_config:all().

config_get(Section) ->
    couch_config:get(Section).

config_get(Section, Key, Default) ->
    couch_config:get(Section, Key, Default).

config_set(Section, Key, Value, Persist) ->
    couch_config:set(Section, Key, Value, Persist).

config_delete(Section, Key, Persist) ->
    couch_config:delete(Section, Key, Persist).

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
