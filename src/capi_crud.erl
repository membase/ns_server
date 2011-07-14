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

-module(capi_crud).

-include("couch_db.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

-define(i2l(X), integer_to_list(X)).

-export([open_doc/3,
         update_doc/4]).

%% Open a database and run a function using its handler
-spec open_db(function(), binary(), #user_ctx{}) -> any().
open_db(Fun, DbName, UserCtx) ->
    case couch_db:open(DbName, [{user_ctx, UserCtx}]) of
        {ok, Db} ->
            try
                Fun(Db)
            after
                couch_db:close(Db)
            end;
        Error ->
            throw(Error)
    end.


%% Ensure item is synced to CouchDB then read value directly
%% from CouchDB
-spec open_doc(#db{}, binary(), list()) -> any().
open_doc(#db{name = Name, user_ctx = UserCtx}, DocId, Options) ->

    {VBucket, _} = cb_util:vbucket_from_id(Name, DocId),

    {ok, _, Entry, _} = ns_memcached:get(?b2l(Name), DocId, VBucket),
    #mc_entry{cas = CAS} = Entry,
    _ = ns_memcached:sync(?b2l(Name), DocId, VBucket, CAS),

    open_db(fun(Db) ->
        couch_db:open_doc(Db, DocId, Options)
    end, db_from_vbucket(Name, VBucket), UserCtx).


%% Delete a document, differ from couch api as deleted documents in memcached
%% do not exist, in couch they are simply new documents
update_doc(#db{name = Name, user_ctx = UserCtx},
           #doc{id = DocId, revs = {NRevNo, [Rev|_]}, deleted = true},
           Options, _Type) ->

    {VBucket, _} = cb_util:vbucket_from_id(Name, DocId),

    {ok, Header, Entry, _} = ns_memcached:get(?b2l(Name), DocId, VBucket),

    case Header#mc_header.status of

        ?KEY_ENOENT ->
            throw(missing);
        _ ->
            #mc_entry{cas = CAS} = Entry,
            _ = ns_memcached:sync(?b2l(Name), DocId, VBucket, CAS),

            open_db( fun(Db) ->
                {ok, NewDoc} = couch_db:open_doc(Db, DocId, Options),
                {RevNo, [Latest|_]} = NewDoc#doc.revs,
                case {RevNo, Latest} of
                    {NRevNo, Rev} ->
                        ok = delete_doc(?b2l(Name), DocId, VBucket),
                        {ok, {0, "deleted"}};
                    _ ->
                        throw(conflict)
                end
            end, db_from_vbucket(Name, VBucket), UserCtx)
    end;

%% No revision specified, create a new document, ADD via memcached
%% sync and fetch revision from couch
update_doc(#db{name = Name, user_ctx = UserCtx},
           #doc{id = DocId, body = Body, revs = {0, []}}, Options, _Type) ->

    {VBucket, _} = cb_util:vbucket_from_id(Name, DocId),

    {ok, Header, Entry, _}
        = ns_memcached:add(?b2l(Name), DocId, VBucket, ?JSON_ENCODE(Body)),

    case Header#mc_header.status of
        % CouchDB strips invalid rev data from request
        ?KEY_EEXISTS ->
            throw(conflict);
        _ ->
            #mc_entry{cas = CAS} = Entry,
            _ = ns_memcached:sync(?b2l(Name), DocId, VBucket, CAS),
            NDb = db_from_vbucket(Name, VBucket),
            {ok, get_doc_rev(NDb, UserCtx, DocId, Options)}
    end;

%% Sync document then check couch version, if it matches update the
%% document and resync
update_doc(#db{name = Name, user_ctx = UserCtx},
           #doc{id = DocId, revs = {NRevNo, [Rev|_]}, body = Body},
           Options, _Type) ->

    {VBucket, _} = cb_util:vbucket_from_id(Name, DocId),

    {ok, _Header, Entry, _} = ns_memcached:get(?b2l(Name), DocId, VBucket),
    _ = ns_memcached:sync(?b2l(Name), DocId, VBucket, Entry#mc_entry.cas),

    open_db( fun(Db) ->
        {ok, NewDoc} = couch_db:open_doc(Db, DocId, Options),
        case get_latest_rev(NewDoc) of
            {NRevNo, Rev} ->
                Json = ?JSON_ENCODE(Body),
                {ok, CAS} = set_doc(?b2l(Name), DocId, VBucket, Json),
                _ = ns_memcached:sync(?b2l(Name), DocId, VBucket, CAS);
            _ ->
                throw(conflict)
        end
    end, db_from_vbucket(Name, VBucket), UserCtx),

    {ok, get_doc_rev(db_from_vbucket(Name, VBucket), UserCtx, DocId, Options)}.


%% TODO: Check CAS value and retry if failed
delete_doc(Name, DocId, VBucket) ->
    {ok, _Entry, _Header, _} = ns_memcached:delete(Name, DocId, VBucket),
    ok.


%% TODO: Check CAS value and retry if failed
set_doc(Name, DocId, VBucket, Json) ->
    {ok, _, #mc_entry{cas = CAS}, _}
        = ns_memcached:set(Name, DocId, VBucket, Json),
    {ok, CAS}.


%% read the current revision of a document
-spec get_doc_rev(#db{}, #user_ctx{}, binary(), list()) ->
    {integer(), binary()}.
get_doc_rev(Db, UserCtx, DocId, Options) ->
    open_db( fun(VDb) ->
        {ok, Doc} = couch_db:open_doc(VDb, DocId, Options),
        get_latest_rev(Doc)
    end, Db, UserCtx).


-spec get_latest_rev(#doc{}) -> {integer(), binary()}.
get_latest_rev(#doc{revs = {RevNo, [Rev|_]}}) ->
    {RevNo, Rev}.


%% Generate the name of the vbucket database
-spec db_from_vbucket(binary(), integer()) -> binary().
db_from_vbucket(Name, VBucket) ->
    VBucketStr = ?l2b(?i2l(VBucket)),
    <<Name/binary, "/", VBucketStr/binary>>.
