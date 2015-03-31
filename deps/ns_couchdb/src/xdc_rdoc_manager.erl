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

-module(xdc_rdoc_manager).
-include("couch_db.hrl").
-include("ns_common.hrl").

-behaviour(gen_server).

-export([start_link_remote/1,
         update_doc/1,
         foreach_doc/2,
         foreach_doc/3,
         get_doc/1]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {rdoc_replicator :: pid(),
                rep_manager :: pid(),
                local_docs = [] :: [#doc{}]}).

-define(DB_NAME, <<"_replicator">>).

start_link_remote(Node) ->
    ReplicationSrvr = erlang:whereis(doc_replication_srv:proxy_server_name(xdcr)),
    Replicator = erlang:whereis(doc_replicator:server_name(xdcr)),
    RepManager = erlang:whereis(xdc_rep_manager),

    ?log_debug("Starting xdc_rdoc_manager on ~p with following links: ~p",
               [Node, [Replicator, ReplicationSrvr, RepManager]]),
    true = is_pid(ReplicationSrvr),
    true = is_pid(Replicator),
    true = is_pid(RepManager),

    misc:start_link(Node, misc, turn_into_gen_server,
                    [{local, ?MODULE},
                     ?MODULE,
                     {Replicator, ReplicationSrvr, RepManager}, []]).

%% Callbacks

init({Replicator, ReplicationSrvr, RepManager}) ->
    Self = self(),

    ns_couchdb_api:register_doc_manager(Replicator),
    ns_couchdb_api:register_doc_manager(ReplicationSrvr),
    ns_couchdb_api:register_doc_manager(RepManager),

    proc_lib:init_ack({ok, Self}),

    ok = misc:wait_for_local_name(couch_server, 10000),

    {ok, Db} = open_or_create_replicator_db(),
    Docs = try
               {ok, ADocs} = load_local_docs(Db),
               ADocs
           after
               ok = couch_db:close(Db)
           end,
    Self ! replicate_newnodes_docs,

    ?log_debug("Loaded the following docs:~n~p", [Docs]),
    gen_server:enter_loop(?MODULE, [],
                          #state{local_docs=Docs,
                                 rdoc_replicator = Replicator,
                                 rep_manager = RepManager}).

handle_call({interactive_update, #doc{id=Id}=Doc}, _From, State) ->
    #state{local_docs=Docs}=State,
    Rand = crypto:rand_uniform(0, 16#100000000),
    RandBin = <<Rand:32/integer>>,
    NewRev = case lists:keyfind(Id, #doc.id, Docs) of
                 false ->
                     {1, RandBin};
                 #doc{rev = {Pos, _DiskRev}} ->
                     {Pos + 1, RandBin}
             end,
    NewDoc = Doc#doc{rev=NewRev},
    try
        ?log_debug("Writing interactively saved ddoc ~p", [Doc]),
        NewState = save_doc(NewDoc, State),
        NewState#state.rdoc_replicator ! {replicate_change, NewDoc},
        {reply, ok, NewState}
    catch throw:{invalid_design_doc, _} = Error ->
            ?log_debug("Document validation failed: ~p", [Error]),
            {reply, Error, State}
    end;
handle_call({foreach_doc, Fun}, _From, #state{local_docs = Docs} = State) ->
    Res = [{Id, (catch Fun(Doc))} || #doc{id = Id} = Doc <- Docs],
    {reply, Res, State};
handle_call({get_doc, Id}, _From, #state{local_docs = Docs} = State) ->
    R = case lists:keyfind(Id, #doc.id, Docs) of
            false ->
                {not_found, no_db_file};
            Doc0 ->
                Doc = couch_doc:with_ejson_body(Doc0),
                {ok, Doc}
        end,
    {reply, R, State};
handle_call(get_all_docs, _From, #state{local_docs = Docs} = State) ->
    {reply, Docs, State};
handle_call(sync, _From, State) ->
    {reply, ok, State}.

save_doc(#doc{id = Id} = Doc,
         #state{local_docs = Docs,
                rep_manager = RepManager}=State) ->
    RepManager ! {rep_db_update, Doc},

    {ok, Db} = open_replicator_db(),
    try
        ok = couch_db:update_doc(Db, Doc)
    after
        ok = couch_db:close(Db)
    end,
    State#state{local_docs = lists:keystore(Id, #doc.id, Docs, Doc)}.

handle_cast({replicated_update, #doc{id=Id, rev=Rev}=Doc}, State) ->
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
    end.


handle_info(replicate_newnodes_docs, #state{local_docs = Docs} = State) ->
    State#state.rdoc_replicator ! {replicate_newnodes_docs, Docs},
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


update_doc(Doc) ->
    gen_server:call(?MODULE,
                    {interactive_update, Doc}, infinity).

-spec get_doc(binary()) -> {ok, #doc{}} | {not_found, atom()}.
get_doc(Id) ->
    gen_server:call(?MODULE, {get_doc, Id}, infinity).

-spec foreach_doc(fun ((#doc{}) -> any()),
                  non_neg_integer() | infinity) -> [{binary(), any()}].
foreach_doc(Fun, Timeout) ->
    gen_server:call(?MODULE, {foreach_doc, Fun}, Timeout).

-spec foreach_doc(pid(), fun ((#doc{}) -> any()),
                  non_neg_integer() | infinity) -> [{binary(), any()}].
foreach_doc(Pid, Fun, Timeout) ->
    gen_server:call(Pid, {foreach_doc, Fun}, Timeout).

load_local_docs(Db) ->
    {ok,_, Docs} = couch_db:enum_docs(
                     Db,
                     fun(DocInfo, _Reds, AccDocs) ->
                             {ok, Doc} = couch_db:open_doc_int(Db, DocInfo, []),
                             {ok, [Doc | AccDocs]}
                     end,
                     [], []),
    {ok, Docs}.

maybe_cleanup_replicator_db() ->
    case open_replicator_db() of
        {ok, Db} ->
            {ok, Info} = couch_db:get_db_info(Db),
            couch_db:close(Db),

            case couch_util:get_value(doc_count, Info) > 0 of
                true ->
                    ?log_debug("Replicator db is a leftover from the previous installation. Delete."),
                    couch_server:delete(?DB_NAME, []);
                false ->
                    ok
            end;
        _ ->
            ok
    end.

open_replicator_db() ->
    couch_db:open_int(?DB_NAME, []).

%% make sure the replication db exists in couchdb
%% and it is not a leftover from the previous installation
open_or_create_replicator_db() ->
    case ns_config_auth:is_system_provisioned() of
        true ->
            ok;
        false ->
            ok = maybe_cleanup_replicator_db()
    end,

    case open_replicator_db() of
        {ok, Db} ->
            Db;
        _Error ->
            ?log_debug("Replicator db did not exist, create a new one"),
            {ok, Db} = couch_db:create(?DB_NAME, [])
    end,
    {ok, Db}.
