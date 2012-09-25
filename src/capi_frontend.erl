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

-record(collect_acc, {
          row_count = undefined,
          rows = []
         }).


not_implemented(Arg, Rest) ->
    {not_implemented, Arg, Rest}.

do_db_req(#httpd{path_parts=[<<"_replicator">>|_]}=Req, Fun) ->
    %% TODO: AUTH!!!!
    couch_db_frontend:do_db_req(Req, Fun);
do_db_req(#httpd{mochi_req=MochiReq, user_ctx=UserCtx,
                 path_parts=[DbName | RestPathParts]} = Req, Fun) ->

    % check auth here
    [BucketName | AfterSlash] = binary:split(DbName, <<"/">>),
    ListBucketName = ?b2l(BucketName),
    BucketConfig = case ns_bucket:get_bucket_light(ListBucketName) of
                      not_present ->
                           throw({not_found, missing});
                      {ok, X} -> X
                  end,
    case menelaus_auth:is_bucket_accessible({ListBucketName, BucketConfig}, MochiReq) of
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

get_db_info(#db{filepath = undefined, name = Name}) ->
    Info = [{db_name, Name},
            {instance_start_time, <<>>}],
    {ok, Info};
get_db_info(#db{name = <<"_replicator">>} = Db) ->
    couch_db:get_db_info(Db);
get_db_info(#db{name = DbName}) ->
    [Bucket, _Master] = string:tokens(binary_to_list(DbName), [$/]),
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

update_doc(#db{name = <<"_replicator">>}, Doc, _Options) ->
    xdc_rdoc_replication_srv:update_doc(Doc);

update_doc(#db{filepath = undefined, name=Name} = Db,
           #doc{id=DocId} = Doc, Options) ->
    R = attempt(Name, DocId,
                capi_crud, update_doc, [Db, Doc, Options]),
    case R of
        ok ->
            ok;
        unsupported ->
            not_implemented(update_doc, [Db, Doc, Options]);
        Error ->
            %% rpc transforms exceptions into values; need to rethrow them
            throw(Error)
    end.

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

-spec ensure_full_commit(any(), integer()) -> {ok, binary()}.
ensure_full_commit(#db{filepath = undefined} = _Db, _RequiredSeq) ->
    {ok, <<>>};

ensure_full_commit(#db{name = DbName} = _Db, _RequiredSeq) ->

    [Bucket, VBucket] = string:tokens(binary_to_list(DbName), [$/]),

    %% subscribe to capture mc_couch_events
    Server = self(),
    MyEventId = create_ckpt_event_id(Bucket, VBucket),
    {value, TimeoutSec} = ns_config:search(xdcr_capi_checkpoint_timeout),

    CkptEventsHandler = fun ({EventId, VBCheckpoint}, _) ->
                                case EventId ==  MyEventId of
                                    true ->
                                        Event2Capi = {persisted_ckpt, VBCheckpoint},
                                        Server ! Event2Capi;
                                    _  ->
                                        []
                                end;
                            (_UnmacthedEvt, _) ->
                                ok
                        end,

    ns_pubsub:subscribe_link(mc_couch_events, CkptEventsHandler, []),

    %% create a new open checkpoint
    StartTime = now(),
    {ok, OpenCheckpointId, PersistedCkptId} = ns_memcached:create_new_checkpoint(Bucket, list_to_integer(VBucket)),

    Result = case PersistedCkptId >= (OpenCheckpointId - 1) of
                 true ->
                     ?xdcr_debug("rep (bucket: ~p, vbucket ~p) issues an empty open ckpt, no need to wait (open ckpt: ~p, persisted ckpt: ~p)",
                                 [Bucket, VBucket, OpenCheckpointId, PersistedCkptId]),
                     {ok, PersistedCkptId};
                 _ ->
                     %% waiting for persisted ckpt to catch up, time out in milliseconds
                     ?xdcr_debug("rep (bucket: ~p, vbucket ~p) waiting for chkpt persisted (open ckpt: ~p, timeout: ~p secs)",
                                 [Bucket, VBucket, OpenCheckpointId, TimeoutSec]),
                     ensure_full_commit_loop(OpenCheckpointId, TimeoutSec*1000)
             end,

    case Result of
        {ok, LastPersistedCkptId} ->
            {ok, Stats2} = ns_memcached:stats(Bucket, <<"">>),
            EpStartupTime = proplists:get_value(<<"ep_startup_time">>, Stats2),
            WorkTime = timer:now_diff(now(), StartTime) div 1000,
            ?xdcr_debug("last persisted ckpt: ~p, open ckpt: ~p for rep (bucket: ~p, vbucket ~p), "
                        "time spent in millisecs: ~p",
                        [LastPersistedCkptId, OpenCheckpointId, Bucket, VBucket, WorkTime]),

            {ok, EpStartupTime};
        timeout ->
            ?xdcr_warning("Timed out when rep (bucket ~p, vb: ~p) waiting for open checkpoint "
                         "(id: ~p) to be persisted.",
                         [Bucket, VBucket, OpenCheckpointId]),
            {error, time_out_polling}
    end.

ensure_full_commit_loop(OpenCheckpointId, Timeout) ->
    receive
        {persisted_ckpt, PersistedCheckpointId} ->
            case PersistedCheckpointId >= (OpenCheckpointId - 1) of
                true ->
                    {ok, PersistedCheckpointId};
                _ ->
                    ensure_full_commit_loop(OpenCheckpointId, Timeout)
            end
    after Timeout ->
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
    Result =
        try
            capi_replication:get_missing_revs(Db, JsonDocIdRevs)
        catch
            throw:unsupported ->
                exit(not_implemented(get_missing_revs, [Db, JsonDocIdRevs]))
        end,

    Result.

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

open_doc(#db{filepath = undefined} = Db, <<"_design/",_/binary>> = DocId, Options) ->
    with_subdb(Db, <<"master">>,
               fun (RealDb) ->
                       couch_db:open_doc(RealDb, DocId, Options)
               end);

open_doc(#db{filepath = undefined, name = Name} = Db, DocId, Options) ->
    case catch attempt(Name, DocId, capi_crud, open_doc, [Db, DocId, Options]) of
        {badrpc, nodedown} ->
            throw({502, <<"node_down">>, <<"The node is currently down.">>});
        {badrpc, {'EXIT',{noproc, _}}} ->
            throw({503, <<"node_warmup">>, <<"Data is not yet loaded.">>});
        max_vbucket_retry ->
            throw({503, <<"node_warmup">>, <<"Data is not yet loaded.">>});
        Response ->
            Response
    end;
open_doc(Db, DocId, Options) ->
    couch_db:open_doc(Db, DocId, Options).


make_attachment_fold(_Att, ReqAcceptsAttEnc) ->
    case ReqAcceptsAttEnc of
        false -> fun couch_doc:att_foldl_decode/3;
        _ -> fun couch_doc:att_foldl/3
    end.

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

%% Keep the last previous non design doc id found so if the random item
%% picked was a design doc, return last document, or not_found
-spec fold_docs(#doc_info{}, any(), tuple()) -> {ok, any()} | {stop, any()}.
fold_docs(#doc_info{id = <<"_design", _/binary>>}, _, {0, undefined}) ->
    {stop, {error, not_found}};
fold_docs(#doc_info{id = <<"_design", _/binary>>}, _, {0, Id}) ->
    {stop, Id};
fold_docs(#doc_info{id = Id}, _, {0, _Id}) ->
    {stop, Id};
fold_docs(#doc_info{deleted=true}, _, Acc) ->
    {ok, Acc};
fold_docs(_, _, {N, Id}) ->
    {ok, {N - 1, Id}}.


%% Return 404 when no documents are found
-spec no_random_docs(#httpd{}) -> any().
no_random_docs(Req) ->
    couch_httpd:send_error(Req, 404, <<"no_docs">>, <<"No documents in database">>).


-spec setup_sender(#index_merge{}) -> #index_merge{}.
setup_sender(MergeParams) ->
    MergeParams#index_merge{
      user_acc = #collect_acc{},
      callback = fun collect_ids/2,
      extra = #view_merge{
        make_row_fun = fun({{DocId, DocId}, _Value}) -> DocId end
       }
     }.


%% Colled Id's in the callback of the view merge, ignore design documents
-spec collect_ids(any(), #collect_acc{}) -> any().
collect_ids(stop, Acc) ->
    {ok, Acc};
collect_ids({start, X}, Acc) ->
    {ok, Acc#collect_acc{row_count=X}};
collect_ids({row, Id}, #collect_acc{rows=Rows} = Acc) ->
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

%% Attempt to forward the request to the correct server, first try normal
%% map, then vbucket map, then try all nodes
-spec attempt(binary(), binary(), atom(), atom(), list()) -> any().
attempt(DbName, DocId, Mod, Fun, Args) ->
    attempt(DbName, DocId, Mod, Fun, Args, plain_map).

-spec attempt(binary(), binary(), atom(),
              atom(), list(), list() | plain_map | fast_forward) -> any().
attempt(_DbName, _DocId, _Mod, _Fun, _Args, []) ->
    throw(max_vbucket_retry);

attempt(DbName, DocId, Mod, Fun, Args, [Node | Rest]) ->
    case rpc:call(Node, Mod, Fun, Args) of
        not_my_vbucket ->
            attempt(DbName, DocId, Mod, Fun, Args, Rest);
        Else ->
            Else
    end;

attempt(DbName, DocId, Mod, Fun, Args, plain_map) ->
    {_, Node} = cb_util:vbucket_from_id(?b2l(DbName), DocId),
    case rpc:call(Node, Mod, Fun, Args) of
        not_my_vbucket ->
            attempt(DbName, DocId, Mod, Fun, Args, fast_forward);
        Else ->
            Else
    end;

attempt(DbName, DocId, Mod, Fun, Args, fast_forward) ->
    R =
        case cb_util:vbucket_from_id_fastforward(?b2l(DbName), DocId) of
            ffmap_not_found ->
                next_attempt;
            {_, Node} ->
                case rpc:call(Node, Mod, Fun, Args) of
                    not_my_vbucket ->
                        next_attempt;
                    Else ->
                        {ok, Else}
                end
        end,

    case R of
        next_attempt ->
            Nodes = ns_cluster_membership:active_nodes(),
            attempt(DbName, DocId, Mod, Fun, Args, Nodes);
        {ok, R1} ->
            R1
    end.

-spec create_ckpt_event_id(string(), string()) -> binary().
create_ckpt_event_id(Bucket, VBucket) ->
    EventName = "persisted_ckpt_" ++  Bucket ++ "_vb_" ++  VBucket,
    list_to_binary(EventName).
