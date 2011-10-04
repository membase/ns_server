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
-include("ns_stats.hrl").
-include("couch_view_merger.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

-define(DEV_MULTIPLE, 20).

-record(collect_acc, {
    row_count = undefined,
    rows = []
}).


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

update_docs(#db{filepath = undefined, name = BucketBin} = Db,
            Docs, Options, replicated_changes) ->
    Bucket = binary_to_list(BucketBin),

    case proplists:get_value(all_or_nothing, Options, false) of
        true ->
            exit(not_implemented(update_docs,
                                 [Db, Docs, Options, replicated_changes]));
        false ->
            ok
    end,

    Errors =
        lists:foldr(
          fun (#doc{id = Id, revs = {Pos, [RevId | _]}} = Doc, ErrorsAcc) ->
                  case update_replicated_doc(Bucket, Doc) of
                      ok ->
                          ErrorsAcc;
                      {error, Error} ->
                          Rev = {Pos, RevId},
                          [{{Id, Rev}, Error} | ErrorsAcc]
                  end
          end,
          [], Docs),
    {ok, Errors};
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


%% Return a random id from within the cluster, if the full set of data is
%% large then run on first vbucket on local node, if data set is smaller
%% then pick key from all document in the cluster
-spec handle_random_req(#httpd{}, #db{}) -> any().
handle_random_req(Req, #db{filepath = undefined, name = Bucket} = Db) ->

    {A1, A2, A3} = erlang:now(),
    random:seed(A1, A2, A3),

    case run_on_subset(Bucket) of
        {error, no_stats} ->
            no_random_docs(Req);
        true ->
            VBucket = capi_frontend:first_vbucket(Bucket),
            capi_frontend:with_subdb(Db, VBucket, fun(RealDb) ->
                handle_random_req(Req, RealDb)
            end);

        false ->
            Params1 = capi_view:view_merge_params(Req, Db, nil, <<"_all_docs">>),
            Params2 = setup_sender(Params1),

            #collect_acc{rows=Rows}
                = couch_view_merger:query_view(Req,Params2),

            case length(Rows) of
                0 ->
                    no_random_docs(Req);
                N ->
                    couch_httpd:send_json(Req, 200, {[
                        {ok, true},
                        {<<"id">>, lists:nth(random:uniform(N), Rows)}
                    ]})
            end
    end;

handle_random_req(#httpd{method='GET'}=Req, Db) ->
    {ok, Info} = couch_db:get_db_info(Db),
    case couch_util:get_value(doc_count, Info) of
        0 ->
            no_random_docs(Req);
        DocCount ->
            Acc = {random:uniform(DocCount - 1), undefined},
            case couch_db:enum_docs(Db, fun fold_docs/3, Acc, []) of
                {ok, _, {error, not_found}} ->
                    no_random_docs(Req);
                {ok, _, Id} ->
                    couch_httpd:send_json(Req, 200, {[
                        {ok, true},
                        {<<"id">>, Id}
                    ]})
            end
    end;


handle_random_req(Req, _Db) ->
    couch_httpd:send_method_not_allowed(Req, "GET").


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

get_missing_revs(#db{filepath = undefined, name = BucketBin} = Db,
                 JsonDocIdRevs) ->
    Bucket = binary_to_list(BucketBin),

    Results =
        lists:foldr(
          fun ({Id, [Rev]}, Acc) ->
                  {VBucket, _Node} = cb_util:vbucket_from_id(Bucket, Id),

                  case ns_memcached:get_meta(Bucket, Id, VBucket) of
                      {memcached_error, key_enoent, _} ->
                          [{Id, [Rev], []} | Acc];
                      {memcached_error, not_my_vbucket, _} ->
                          throw({bad_request, not_my_vbucket});
                      {ok, _, _, {revid, OurRev}} ->
                          case winning_revision(Rev, OurRev) of
                              Rev ->
                                  [{Id, [Rev], []} | Acc];
                              OurRev ->
                                  Acc
                          end
                  end;
              (_, _) ->
                  exit(not_implemented(get_missing_revs, [Db, JsonDocIdRevs]))
          end, [], JsonDocIdRevs),
    {ok, Results};
get_missing_revs(Db, JsonDocIdRevs) ->
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
    couch_db_frontend:task_status_all().

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


is_couchbase_db(<<"_replicator">>) ->
    false;
is_couchbase_db(Name) ->
    nomatch =:= re:run(Name, <<"/">>).

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


%% Decide whether to run a query on a subset of documents or a full cluster
%% depending on the number of items in the cluster
-spec run_on_subset(binary()) -> true | false | {error, no_stats}.
run_on_subset(Bucket) ->
    case catch stats_reader:latest(minute, node(), ?b2l(Bucket), 1) of
        {ok, [Stats|_]} ->
            {ok, Config} = ns_bucket:get_bucket(?b2l(Bucket)),
            NumVBuckets = proplists:get_value(num_vbuckets, Config, []),
            {ok, N} = orddict:find(curr_items_tot, Stats#stat_entry.values),
            N > NumVBuckets * ?DEV_MULTIPLE;
        {'EXIT', _Reason} ->
            {error, no_stats}
    end.

%% Keep the last previous non design doc id found so if the random item
%% picked was a design doc, return last document, or not_found
-spec fold_docs(#full_doc_info{}, any(), tuple()) -> {ok, any()} | {stop, any()}.
fold_docs(#full_doc_info{id = <<"_design", _/binary>>}, _, {0, undefined}) ->
    {stop, {error, not_found}};
fold_docs(#full_doc_info{id = <<"_design", _/binary>>}, _, {0, Id}) ->
    {stop, Id};
fold_docs(#full_doc_info{id = Id}, _, {0, _Id}) ->
    {stop, Id};
fold_docs(#full_doc_info{deleted=true}, _, Acc) ->
    {ok, Acc};
fold_docs(_, _, {N, Id}) ->
    {ok, {N - 1, Id}}.


%% Return 404 when no documents are found
-spec no_random_docs(#httpd{}) -> any().
no_random_docs(Req) ->
    couch_httpd:send_error(Req, 404, <<"no_docs">>, <<"No documents in database">>).


-spec setup_sender(#view_merge{}) -> #view_merge{}.
setup_sender(MergeParams) ->
    MergeParams#view_merge{
      user_acc = #collect_acc{},
      callback = fun collect_ids/2
    }.


%% Colled Id's in the callback of the view merge, ignore design documents
-spec collect_ids(any(), #collect_acc{}) -> any().
collect_ids(stop, Acc) ->
    {ok, Acc};
collect_ids({start, X}, Acc) ->
    {ok, Acc#collect_acc{row_count=X}};
collect_ids({row, {Doc}}, #collect_acc{rows=Rows} = Acc) ->
    Id = couch_util:get_value(id, Doc),
    case is_design_doc(Id) of
        true -> {ok, Acc};
        false -> {ok, Acc#collect_acc{rows=[Id|Rows]}}
    end.


-spec is_design_doc(binary()) -> true | false.
is_design_doc(<<"_design/", _Rest/binary>>) ->
    true;
is_design_doc(_) ->
    false.

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

-spec winning_revision(Revision, Revision) -> Revision
  when Revision :: {integer(), binary()}.
winning_revision({SeqNo, RevId1} = Rev1, {SeqNo, RevId2} = Rev2) ->
    case RevId1 > RevId2 of
        true ->
            Rev1;
        false ->
            Rev2
    end;
winning_revision({SeqNo1, _} = Rev1, {SeqNo2, _} = Rev2) ->
    case SeqNo1 > SeqNo2 of
        true ->
            Rev1;
        false ->
            Rev2
    end.

update_replicated_doc(Bucket,
                      #doc{id = Id, revs = {Pos, [RevId | _]},
                           body = Body, deleted = Deleted} = _Doc) ->
    {VBucket, _Node} = cb_util:vbucket_from_id(Bucket, Id),
    Json = ?JSON_ENCODE(Body),
    Rev = {Pos, RevId},
    update_replicated_doc_loop(Bucket, VBucket, Id, Rev, Json, Deleted).

update_replicated_doc_loop(Bucket, VBucket,
                           DocId, DocRev, DocJson, DocDeleted) ->
    RV =
        case ns_memcached:get_meta(Bucket, DocId, VBucket) of
            {memcached_error, key_enoent, _} ->
                case DocDeleted of
                    true ->
                        ok;
                    false ->
                        do_add_with_meta(Bucket, DocId, VBucket, DocJson, DocRev)
                end;
            {memcached_error, not_my_vbucket, _} ->
                {error, {bad_request, not_my_vbucket}};
            {ok, _, #mc_entry{cas = CAS}, {revid, OurRev}} ->
                case winning_revision(DocRev, OurRev) of
                    DocRev ->
                        case DocDeleted of
                            true ->
                                do_delete(Bucket, DocId, VBucket, CAS);
                            false ->
                                do_set_with_meta(Bucket, DocId, VBucket,
                                                 DocJson, DocRev, CAS)
                        end;
                    OurRev ->
                        ok
                end
        end,

    case RV of
        retry ->
            update_replicated_doc_loop(Bucket, VBucket, DocId,
                                       DocRev, DocJson, DocDeleted);
        _Other ->
            RV
    end.

do_add_with_meta(Bucket, DocId, VBucket, DocJson, DocRev) ->
    case ns_memcached:add_with_meta(Bucket, DocId, VBucket,
                                    DocJson, {revid, DocRev}) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_eexists, _} ->
            retry;
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            %% this is most likely an invalid revision
            {error, {bad_request, einval}}
    end.

do_set_with_meta(Bucket, DocId, VBucket, DocJson, DocRev, CAS) ->
    case ns_memcached:set_with_meta(Bucket, DocId,
                                    VBucket, DocJson,
                                    {revid, DocRev}, CAS) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_eexists, _} ->
            retry;
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            {error, {bad_request, einval}}
    end.

do_delete(Bucket, DocId, VBucket, CAS) ->
    {ok, Header, _Entry, _NCB} =
        ns_memcached:delete(Bucket, DocId, VBucket, CAS),
    Status = Header#mc_header.status,
    case Status of
        ?SUCCESS ->
            ok;
        ?KEY_ENOENT ->
            retry;
        ?NOT_MY_VBUCKET ->
            {error, {bad_request, not_my_vbucket}};
        ?EINVAL ->
            {error, {bad_request, einval}}
    end.
