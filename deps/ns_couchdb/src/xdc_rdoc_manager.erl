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
-include("pipes.hrl").

-behaviour(replicated_storage).

-export([start_link_remote/1,
         start_replicator/0,
         update_doc/1,
         foreach_doc/2,
         foreach_doc/3,
         get_doc/1,
         pull_docs/1]).

-export([init/1, init_after_ack/1, handle_call/3,
         get_id/1, find_doc/2, find_doc_rev/2, all_docs/1,
         get_revision/1, set_revision/2, is_deleted/1, save_docs/2]).

-record(state, {rep_manager :: pid(),
                local_docs = [] :: [#doc{}]}).

-define(DB_NAME, <<"_replicator">>).

start_link_remote(Node) ->
    ReplicationSrvr = erlang:whereis(doc_replication_srv:proxy_server_name(xdcr)),
    Replicator = erlang:whereis(replicator_name()),
    RepManager = erlang:whereis(xdc_rep_manager),

    ?log_debug("Starting xdc_rdoc_manager on ~p with following links: ~p",
               [Node, [Replicator, ReplicationSrvr, RepManager]]),
    true = is_pid(ReplicationSrvr),
    true = is_pid(Replicator),
    true = is_pid(RepManager),

    replicated_storage:start_link_remote(Node, ?MODULE, ?MODULE,
                                         {Replicator, ReplicationSrvr, RepManager}, Replicator).

replicator_name() ->
    xdcr_doc_replicator.

start_replicator() ->
    GetRemoteNodes =
        fun () ->
                ns_node_disco:nodes_actual_other()
        end,
    doc_replicator:start_link(?MODULE, replicator_name(), GetRemoteNodes,
                              doc_replication_srv:proxy_server_name(xdcr)).

pull_docs(Nodes) ->
    Timeout = ns_config:read_key_fast(goxdcr_upgrade_timeout, 60000),
    gen_server:call(replicator_name(), {pull_docs, Nodes, Timeout}, infinity).

%% replicated_storage callbacks

init({Replicator, ReplicationSrvr, RepManager}) ->
    replicated_storage:anounce_startup(Replicator),
    replicated_storage:anounce_startup(ReplicationSrvr),
    replicated_storage:anounce_startup(RepManager),
    #state{rep_manager = RepManager}.

init_after_ack(State) ->
    ok = misc:wait_for_local_name(couch_server, 10000),

    {ok, Db} = open_or_create_replicator_db(),
    Docs = try
               {ok, ADocs} = load_local_docs(Db),
               ADocs
           after
               ok = couch_db:close(Db)
           end,
    ?log_debug("Loaded the following docs:~n~p", [Docs]),
    State#state{local_docs = Docs}.

get_id(#doc{id = Id}) ->
    Id.

find_doc(Id, #state{local_docs = Docs}) ->
    lists:keyfind(Id, #doc.id, Docs).

find_doc_rev(Id, State) ->
    case find_doc(Id, State) of
        false ->
            false;
        #doc{rev = Rev} ->
            Rev
    end.

all_docs(Pid) ->
    ?make_producer(?yield(gen_server:call(Pid, get_all_docs, infinity))).

get_revision(#doc{rev = Rev}) ->
    Rev.

set_revision(Doc, NewRev) ->
    Doc#doc{rev = NewRev}.

is_deleted(_) ->
    false.

save_docs([#doc{id = Id} = Doc],
          #state{local_docs = Docs,
                 rep_manager = RepManager}=State) ->
    RepManager ! {rep_db_update, Doc},

    {ok, Db} = open_replicator_db(),
    try
        ok = couch_db:update_doc(Db, Doc)
    after
        ok = couch_db:close(Db)
    end,
    {ok, State#state{local_docs = lists:keystore(Id, #doc.id, Docs, Doc)}}.

handle_call({foreach_doc, Fun}, _From, #state{local_docs = Docs} = State) ->
    Res = [{Id, Fun(Doc)} || #doc{id = Id} = Doc <- Docs],
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

%% internal

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
