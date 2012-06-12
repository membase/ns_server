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
-include_lib("couch_index_merger/include/couch_index_merger.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

-define(DEV_MULTIPLE, 20).

-record(collect_acc, {
          row_count = undefined,
          rows = []
         }).


not_implemented(Arg, Rest) ->
    {not_implemented, Arg, Rest}.

is_couchbase_db(<<"_replicator">>) ->
    false;
is_couchbase_db(Name) ->
    nomatch =:= binary:match(Name, <<"/">>).

do_db_req(#httpd{mochi_req=MochiReq,user_ctx=UserCtx,path_parts=[DbName|_]}=Req, Fun) ->
    % check auth here
    [BucketName|_] = binary:split(DbName,<<"/">>),
    ListBucketName = ?b2l(BucketName),
    BucketConfig = case ns_bucket:get_bucket(ListBucketName) of
                      not_present ->
                            case DbName of
                                <<"_replicator">> -> [{auth_type, none}];
                                _ -> throw({not_found, missing})
                            end;
                      {ok, X} -> X
                  end,
    case menelaus_auth:is_bucket_accessible({ListBucketName, BucketConfig}, MochiReq) of
        true ->
            case is_couchbase_db(DbName) of
                true ->
                    case ns_bucket:couchbase_bucket_exists(DbName) of
                        true ->
                            %% undefined #db fields indicate bucket database
                            Db = #db{user_ctx = UserCtx, name = DbName},
                            Fun(Req, Db);
                        _ ->
                            erlang:throw({not_found, no_couchbase_bucket_exists})
                    end;
                false ->
                    couch_db_frontend:do_db_req(Req, Fun)
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
    case valid_ddoc(Doc) of
        ok ->
            capi_ddoc_replication_srv:update_doc(Name, Doc);
        {error, Reason} ->
            throw({invalid_design_doc, Reason})
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
                          case valid_ddoc(Doc) of
                              ok -> ok;
                              {error, Reason} ->
                                  throw({invalid_design_doc, Reason})
                          end
                  end, Docs),

    lists:foreach(fun(#doc{id = <<"_design/",_/binary>>} = Doc) ->
                          ok = capi_ddoc_replication_srv:update_doc(Name, Doc)
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

    %% get the timestamp from stats
    {ok, Stats0} = ns_memcached:stats(Bucket, <<"">>),
    EpStartupTime0 =  list_to_integer(?b2l(proplists:get_value(
                        <<"ep_startup_time">>, Stats0))),

    %% create a new open checkpoint
    {ok, OpenCheckpointId} = ns_memcached:create_new_checkpoint(Bucket, list_to_integer(VBucket)),

    %% wait til the persited checkpoint ID catch up with open checkpoint ID
    PollResult = misc:poll_for_condition(
        fun() ->
            %% check out ep engine startup time
            {ok, Stats1} = ns_memcached:stats(Bucket, <<"">>),
            EpStartupTime1 = list_to_integer(?b2l(proplists:get_value(
                        <<"ep_startup_time">>, Stats1))),

            {ok, Stats2} = ns_memcached:stats(Bucket, <<"checkpoint">>),
            PersistedCheckpointId = list_to_integer(?b2l(proplists:get_value(
                ?l2b(["vb_", VBucket, ":persisted_checkpoint_id"]), Stats2))),

            case EpStartupTime0 == EpStartupTime1 of
                false ->
                    %% if startup time mismatch, simply exit the polling
                    %% and re-query startup time to caller
                    ?log_warning("Engine startup time mismatch."),
                    true;
                _ ->
                    PersistedCheckpointId >= (OpenCheckpointId - 1)
            end
        end,
        10000,  %% timeout in ms
        100),   %% sleep time in ms

    case PollResult of
        ok ->
            {ok, Stats3} = ns_memcached:stats(Bucket, <<"">>),
            EpStartupTime = proplists:get_value(<<"ep_startup_time">>, Stats3),
            {ok, EpStartupTime};
        timeout ->
            ?log_warning("Timed out when waiting for open checkpoint to be persisted."),
            {error, time_out_polling}
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
            capi_frontend:with_subdb(Db, VBucket,
                                     fun(RealDb) ->
                                             handle_random_req(Req, RealDb)
                                     end);

        false ->
            Params1 = capi_view:view_merge_params(Req, Db, nil, <<"_all_docs">>),
            Params2 = setup_sender(Params1),

            #collect_acc{rows=Rows} = couch_index_merger:query_index(
                                        couch_view_merger, Params2, Req),

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

%% Do basic checking on design documents content to ensure it is a valid
%% design document
-spec valid_ddoc(#doc{}) -> ok | {error, term()}.
valid_ddoc(Doc) ->
    case catch validate_ddoc(Doc) of
        ok ->
            ok;
        Error ->
            {error, Error}
    end.

validate_ddoc(Doc) ->

    #doc{body={Fields}, content_meta=Meta} = couch_doc:with_ejson_body(Doc),

    Meta == ?CONTENT_META_JSON
        orelse throw(invalid_json),

    is_json_object(couch_util:get_value(<<"options">>, Fields, {[]}))
        orelse throw(invalid_options),

    is_json_object(couch_util:get_value(<<"views">>, Fields, {[]}))
        orelse throw(invalid_view),

    ok.

is_json_object({Obj}) when is_list(Obj) ->
    true;
is_json_object(_) ->
    false.
