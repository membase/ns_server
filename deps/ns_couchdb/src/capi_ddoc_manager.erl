%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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

-module(capi_ddoc_manager).

-behaviour(gen_server).

-export([start_link/3,
         start_link_event_manager/1,
         subscribe_link/2,
         update_doc/2,
         foreach_doc/3,
         reset_master_vbucket/1]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-include("ns_common.hrl").
-include("couch_db.hrl").

-record(state, { bucket :: bucket_name(),
                 event_manager :: pid(),
                 ddoc_replicator :: pid(),
                 local_docs :: [#doc{}]
               }).

start_link(Bucket, Replicator, ReplicationSrv) ->
    gen_server:start_link({local, server(Bucket)}, ?MODULE,
                          [Bucket, Replicator, ReplicationSrv], []).

start_link_event_manager(Bucket) ->
    gen_event:start_link({local, event_manager(Bucket)}).

subscribe_link(Bucket, Body) ->
    Self = self(),
    Ref = make_ref(),

    %% we only expect to be called by capi_set_view_manager that doesn't trap
    %% exits
    {trap_exit, false} = erlang:process_info(self(), trap_exit),

    Pid = ns_pubsub:subscribe_link(
            event_manager(Bucket),
            fun (Event, false) ->
                    case Event of
                        {snapshot, Docs} ->
                            Self ! {Ref, Docs},
                            true;
                        _ ->
                            %% we haven't seen snapshot yet; so we ignore
                            %% spurious notifications
                            false
                    end;
                (Event, true) ->
                    case Event of
                        {snapshot, _} ->
                            error(unexpected_snapshot);
                        _ ->
                            Body(Event)
                    end,
                    true
            end, false),
    gen_server:cast(server(Bucket), request_snapshot),

    receive
        {Ref, Docs} ->
            {Pid, Docs}
    end.

-spec foreach_doc(ext_bucket_name(),
                  fun ((#doc{}) -> any()),
                  non_neg_integer() | infinity) -> [{binary(), any()}].
foreach_doc(Bucket, Fun, Timeout) ->
    gen_server:call(server(Bucket), {foreach_doc, Fun}, Timeout).

update_doc(Bucket, Doc) ->
    gen_server:call(server(Bucket), {interactive_update, Doc}, infinity).

reset_master_vbucket(Bucket) ->
    gen_server:call(server(Bucket), reset_master_vbucket, infinity).

%% gen_server callbacks
init([Bucket, Replicator, ReplicationSrv]) ->
    Self = self(),

    ns_couchdb_api:register_doc_manager(Replicator),
    ns_couchdb_api:register_doc_manager(ReplicationSrv),

    EventManager = whereis(event_manager(Bucket)),
    true = is_pid(EventManager) andalso is_process_alive(EventManager),

    ns_pubsub:subscribe_link(
      ns_config_events,
      fun ({buckets, _}) ->
              Self ! replicate_newnodes_docs;
          ({{node, _, membership}, _}) ->
              Self ! replicate_newnodes_docs;
          ({{node, _, services}, _}) ->
              Self ! replicate_newnodes_docs;
          (_) ->
              ok
      end),

    Self ! replicate_newnodes_docs,

    proc_lib:init_ack({ok, Self}),

    ok = misc:wait_for_local_name(couch_server, 10000),

    Docs = load_local_docs(Bucket),
    State = #state{bucket = Bucket,
                   event_manager = EventManager,
                   ddoc_replicator = Replicator,
                   local_docs = Docs},

    gen_server:enter_loop(?MODULE, [], State).

handle_call({interactive_update, #doc{id = Id} = Doc}, _From,
            #state{local_docs = Docs} = State) ->
    Rand = crypto:rand_uniform(0, 16#100000000),
    RandBin = <<Rand:32/integer>>,
    {NewRev, FoundType} =
        case lists:keyfind(Id, #doc.id, Docs) of
            false ->
                {{1, RandBin}, missing};
            #doc{rev = {Pos, _DiskRev}, deleted = Deleted} ->
                FoundType0 = case Deleted of
                                 true ->
                                     deleted;
                                 false ->
                                     existent
                             end,
                {{Pos + 1, RandBin}, FoundType0}
        end,

    case Doc#doc.deleted andalso FoundType =/= existent of
        true ->
            {reply, {not_found, FoundType}, State};
        false ->
            NewDoc = Doc#doc{rev = NewRev},
            try
                ?log_debug("Writing interactively saved ddoc ~p", [Doc]),
                NewState = save_doc(NewDoc, State),
                NewState#state.ddoc_replicator ! {replicate_change, NewDoc},
                {reply, ok, NewState}
            catch throw:{invalid_design_doc, _} = Error ->
                    ?log_debug("Document validation failed: ~p", [Error]),
                    {reply, Error, State}
            end
    end;
handle_call({foreach_doc, Fun}, _From, #state{local_docs = Docs} = State) ->
    Res = [{Id, (catch Fun(Doc))} || #doc{id = Id} = Doc <- Docs],
    {reply, Res, State};
handle_call(reset_master_vbucket, _From, #state{bucket = Bucket,
                                                local_docs = LocalDocs} = State) ->
    MasterVBucket = master_vbucket(Bucket),
    ok = couch_server:delete(MasterVBucket, []),
    [save_doc(Doc, State) || Doc <- LocalDocs],
    {reply, ok, State}.

handle_cast({replicated_update, #doc{id = Id, rev = Rev} = Doc}, State) ->
    %% this is replicated from another node in the cluster. We only accept it
    %% if it doesn't exist or the rev is higher than what we have.
    #state{local_docs=Docs} = State,
    Proceed = case lists:keyfind(Id, #doc.id, Docs) of
                  false ->
                      true;
                  #doc{rev = DiskRev} when Rev > DiskRev ->
                      true;
                  _ ->
                      false
              end,
    if Proceed ->
            ?log_debug("Writing replicated ddoc ~p", [Doc]),
            {noreply, save_doc(Doc, State)};
       true ->
            {noreply, State}
    end;
handle_cast(request_snapshot,
            #state{event_manager = EventManager,
                   local_docs = Docs} = State) ->
    gen_event:notify(EventManager, {snapshot, Docs}),
    {noreply, State}.

handle_info(replicate_newnodes_docs, #state{local_docs = Docs,
                                            ddoc_replicator = Replicator} = State) ->
    Replicator ! {replicate_newnodes_docs, Docs},
    {noreply, State};
handle_info(Info, State) ->
    ?log_info("Ignoring unexpected message: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal
server(Bucket) when is_binary(Bucket) ->
    server(binary_to_list(Bucket));
server(Bucket) when is_list(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

event_manager(Bucket) ->
    list_to_atom("capi_ddoc_manager_events-" ++ Bucket).

master_vbucket(Bucket) ->
    iolist_to_binary([Bucket, <<"/master">>]).

open_local_db(Bucket) ->
    MasterVBucket = master_vbucket(Bucket),
    case couch_db:open(MasterVBucket, []) of
        {ok, Db} ->
            {ok, Db};
        {not_found, _} ->
            couch_db:create(MasterVBucket, [])
    end.

load_local_docs(Bucket) ->
    {ok, Db} = open_local_db(Bucket),
    try
        {ok, Docs} = couch_db:get_design_docs(Db, deleted_also),
        Docs
    after
        ok = couch_db:close(Db)
    end.

save_doc(#doc{id = Id} = Doc,
         #state{bucket = Bucket,
                event_manager = EventManager,
                local_docs = Docs} = State) ->

    Ref = make_ref(),
    gen_event:sync_notify(EventManager, {suspend, Ref}),

    {ok, Db} = open_local_db(Bucket),
    try
        ok = couch_db:update_doc(Db, Doc)
    after
        ok = couch_db:close(Db)
    end,

    gen_event:sync_notify(EventManager, {resume, Ref, Doc}),

    State#state{local_docs = lists:keystore(Id, #doc.id, Docs, Doc)}.
