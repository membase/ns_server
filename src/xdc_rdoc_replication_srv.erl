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

-module(xdc_rdoc_replication_srv).
-include("couch_db.hrl").
-include("ns_common.hrl").

-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {remote_nodes = [],
                local_docs = [] :: [#doc{}]}).

start_link() ->
    gen_server:start_link({local, ?MODULE},
                          ?MODULE, [], []).


force_update(Srv) ->
    Srv ! replicate_newnodes_docs.

nodeup_monitoring_loop(Parent) ->
    receive
        {nodeup, _} ->
            ?log_debug("got nodeup event. Considering rdocs replication"),
            force_update(Parent);
        _ ->
            ok
    end,
    nodeup_monitoring_loop(Parent).

%% Callbacks

init([]) ->
    Self = self(),
    {ok, Db} = open_local_db(),
    Docs = try
               {ok, ADocs} = load_local_docs(Db),
               ADocs
           after
               ok = couch_db:close(Db)
           end,
    %% anytime we disconnect or reconnect, force a replicate event.
    erlang:spawn_link(
      fun () ->
              ok = net_kernel:monitor_nodes(true),
              nodeup_monitoring_loop(Self)
      end),
    Self ! replicate_newnodes_docs,

    %% Explicitly ask all available nodes to send their documents to us
    [{?MODULE, N} ! replicate_newnodes_docs ||
        N <- get_remote_nodes()],

    ?log_debug("Loaded the following docs:~n~p", [Docs]),

    {ok, #state{local_docs=Docs}}.


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
        SavedDocState = save_doc(NewDoc, State),
        replicate_change(SavedDocState, NewDoc),
        {reply, ok, SavedDocState}
    catch throw:{invalid_design_doc, _} = Error ->
            ?log_debug("Document validation failed: ~p", [Error]),
            {reply, Error, State}
    end;
handle_call({foreach_doc, Fun}, _From, #state{local_docs = Docs} = State) ->
    Res = [{Id, (catch Fun(Doc))} || #doc{id = Id} = Doc <- Docs],
    {reply, Res, State};
handle_call({get_full_replicator_doc, Id}, _From, #state{local_docs = Docs} = State) ->
    R = case lists:keyfind(Id, #doc.id, Docs) of
            false ->
                not_found;
            Doc0 ->
                Doc = couch_doc:with_ejson_body(Doc0),
                {ok, Doc}
        end,
    {reply, R, State}.

replicate_change(#state{remote_nodes=Nodes}, Doc) ->
    [replicate_change_to_node(Node, Doc) || Node <- Nodes],
    ok.

save_doc(#doc{id = Id} = Doc,
         #state{local_docs=Docs}=State) ->
    {ok, Db} = open_local_db(),
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


handle_info({'DOWN', _Ref, _Type, {Server, RemoteNode}, Error},
            #state{remote_nodes = RemoteNodes} = State) ->
    ?log_warning("Remote server node ~p process down: ~p",
                 [{Server, RemoteNode}, Error]),
    {noreply, State#state{remote_nodes=RemoteNodes -- [RemoteNode]}};
handle_info(replicate_newnodes_docs, State) ->
    ?log_debug("doing replicate_newnodes_docs"),
    {noreply, replicate_newnodes_docs(State)}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


replicate_newnodes_docs(State) ->
    #state{remote_nodes=OldNodes,
           local_docs = Docs} = State,
    AllNodes = get_remote_nodes(),
    NewNodes = AllNodes -- OldNodes,
    case NewNodes of
        [] ->
            ok;
        _ ->
            [monitor(process, {?MODULE, Node}) || Node <- NewNodes],
            [replicate_change_to_node(S, D) || S <- NewNodes,
                                               D <- Docs]
    end,
    State#state{remote_nodes=AllNodes}.

replicate_change_to_node(Node, Doc) ->
    ?log_debug("Sending ~s to ~s", [Doc#doc.id, Node]),
    gen_server:cast({?MODULE, Node}, {replicated_update, Doc}).


get_remote_nodes() ->
    ns_node_disco:nodes_wanted() -- [node()].


load_local_docs(Db) ->
    {ok,_, Docs} = couch_db:enum_docs(
                     Db,
                     fun(DocInfo, _Reds, AccDocs) ->
                             {ok, Doc} = couch_db:open_doc_int(Db, DocInfo, []),
                             {ok, [Doc | AccDocs]}
                     end,
                     [], []),
    {ok, Docs}.

open_local_db() ->
    couch_db:open_int(<<"_replicator">>, []).
