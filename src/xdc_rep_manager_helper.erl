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

-module(xdc_rep_manager_helper).

%% public API
-export([changes_feed_loop/0, db_update_notifier/0]).
-export([update_rep_doc/2, maybe_tag_rep_doc/3]).

-include("xdc_replicator.hrl").

changes_feed_loop() ->
    {ok, RepDb} = ensure_rep_db_exists(),
    RepDbName = couch_db:name(RepDb),
    couch_db:close(RepDb),
    Server = self(),
    Pid = spawn_link(
            fun() ->
                    {ok, Db} = couch_db:open_int(RepDbName, [sys_db]),
                    ChangesFeedFun = couch_changes:handle_changes(
                                       #changes_args{
                                          include_docs = true,
                                          feed = "continuous",
                                          timeout = infinity,
                                          db_open_options = [sys_db]
                                         },
                                       {json_req, null},
                                       Db
                                      ),
                    ChangesFeedFun(
                      fun({change, Change, _}, _) ->
                              case has_valid_rep_id(Change) of
                                  true ->
                                      ok = gen_server:call(
                                             Server, {rep_db_update, Change}, infinity);
                                  false ->
                                      ok
                              end;
                         (_, _) ->
                              ok
                      end
                     ),
                    couch_db:close(Db)
            end
           ),
    {Pid, RepDbName}.

%% make sure the replication db exists in couchdb
ensure_rep_db_exists() ->
    DbName = ?l2b(couch_config:get("replicator", "db", "_replicator")),
    UserCtx = #user_ctx{roles = [<<"_admin">>, <<"_replicator">>]},
    case couch_db:open_int(DbName, [sys_db, {user_ctx, UserCtx}]) of
        {ok, Db} ->
            Db;
        _Error ->
            {ok, Db} = couch_db:create(DbName, [sys_db, {user_ctx, UserCtx}])
    end,
    ensure_rep_ddoc_exists(Db, <<"_design/_replicator">>),
    {ok, Db}.


ensure_rep_ddoc_exists(RepDb, DDocID) ->
    case couch_db:open_doc(RepDb, DDocID, []) of
        {ok, _Doc} ->
            ok;
        _ ->
            DDoc = couch_doc:from_json_obj({[
                                             {<<"_id">>, DDocID},
                                             {<<"language">>, <<"javascript">>},
                                             {<<"validate_doc_update">>, ?REP_DB_DOC_VALIDATE_FUN}
                                            ]}),
            ok = couch_db:update_doc(RepDb, DDoc, [])
    end.


has_valid_rep_id({Change}) ->
    has_valid_rep_id(get_value(<<"id">>, Change));
has_valid_rep_id(<<?DESIGN_DOC_PREFIX, _Rest/binary>>) ->
    false;
has_valid_rep_id(_Else) ->
    true.

%% replication db update notifier, msg rep_db_created will be sent
%% to XDCR rep manager when replication doc changed.
db_update_notifier() ->
    Server = self(),
    {ok, Notifier} = couch_db_update_notifier:start_link(
                       fun({created, DbName}) ->
                               case ?l2b(couch_config:get("replicator", "db", "_replicator")) of
                                   DbName ->
                                       ok = gen_server:cast(Server, {rep_db_created, DbName});
                                   _ ->
                                       ok
                               end;
                          (_) ->
                               %% no need to handle the 'deleted' event - the changes feed loop
                               %% dies when the database is deleted
                               ok
                       end
                      ),
    Notifier.

%% update the replication document
update_rep_doc(RepDocId, KVs) ->
    {ok, RepDb} = ensure_rep_db_exists(),
    try
        case couch_db:open_doc(RepDb, RepDocId, [ejson_body]) of
            {ok, LatestRepDoc} ->
                update_rep_doc(RepDb, LatestRepDoc, KVs);
            _ ->
                ok
        end
    catch throw:conflict ->
            %% Shouldn't happen, as by default only the role _replicator can
            %% update replication documents.
            ?LOG_ERROR("Conflict error when updating replication document `~s`."
                       " Retrying.", [RepDocId]),
            ok = timer:sleep(5),
            update_rep_doc(RepDocId, KVs)
    after
        couch_db:close(RepDb)
    end.

update_rep_doc(RepDb, #doc{body = {RepDocBody}} = RepDoc, KVs) ->
    NewRepDocBody = lists:foldl(
                      fun({<<"_replication_state">> = K, State} = KV, Body) ->
                              case get_value(K, Body) of
                                  State ->
                                      Body;
                                  _ ->
                                      Body1 = lists:keystore(K, 1, Body, KV),
                                      lists:keystore(
                                        <<"_replication_state_time">>, 1, Body1,
                                        {<<"_replication_state_time">>, timestamp()})
                              end;
                         ({K, _V} = KV, Body) ->
                              lists:keystore(K, 1, Body, KV)
                      end,
                      RepDocBody, KVs),
    case NewRepDocBody of
        RepDocBody ->
            ok;
        _ ->
            %% Might not succeed - when the replication doc is deleted right
            %% before this update (not an error, ignore).
            couch_db:update_doc(RepDb, RepDoc#doc{body = {NewRepDocBody}}, [])
    end.


%% RFC3339 timestamps.
%% Note: doesn't include the time seconds fraction (RFC3339 says it's optional).
timestamp() ->
    {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:now_to_local_time(now()),
    UTime = erlang:universaltime(),
    LocalTime = calendar:universal_time_to_local_time(UTime),
    DiffSecs = calendar:datetime_to_gregorian_seconds(LocalTime) -
        calendar:datetime_to_gregorian_seconds(UTime),
    zone(DiffSecs div 3600, (DiffSecs rem 3600) div 60),
    iolist_to_binary(
      io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w~s",
                    [Year, Month, Day, Hour, Min, Sec,
                     zone(DiffSecs div 3600, (DiffSecs rem 3600) div 60)])).

zone(Hr, Min) when Hr >= 0, Min >= 0 ->
    io_lib:format("+~2..0w:~2..0w", [Hr, Min]);
zone(Hr, Min) ->
    io_lib:format("-~2..0w:~2..0w", [abs(Hr), abs(Min)]).

%% check if replication id exists, update the replication
%% doc with replication id if not
maybe_tag_rep_doc(DocId, {RepProps}, RepId) ->
    case get_value(<<"_replication_id">>, RepProps) of
        RepId ->
            ok;
        _ ->
            update_rep_doc(DocId, [{<<"_replication_id">>, RepId}])
    end.
