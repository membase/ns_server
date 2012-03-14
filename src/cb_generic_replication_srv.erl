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

-module(cb_generic_replication_srv).


-include("couch_db.hrl").
-include("ns_common.hrl").

-export([start_link/2,force_update/1]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {module, module_state, server_name,
                remote_nodes = [], local_doc_infos=[]}).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [{init, 1}, {get_remote_nodes, 1}, {server_name, 1}, {load_local_docs, 2},
     {open_local_db, 1}].

start_link(Mod, Args) ->
    ServerName = Mod:server_name(Args),
    gen_server:start_link({local, ServerName},
                          ?MODULE, [ServerName, Mod, Args], []).


force_update(Srv) ->
    Srv ! replicate_newnodes_docs.


%% Callbacks

init([ServerName, Mod, Args]) ->
    Self = self(),
    {ok, ModState} = Mod:init(Args),
    case Mod:open_local_db(ModState) of
        {ok, Db} ->
            {ok, Docs} = Mod:load_local_docs(Db, ModState),
            DocInfos = [{Id,Rev} || #doc{id=Id,rev=Rev} <- Docs],
            couch_db:close(Db)
    end,
    %% anytime we disconnect or reconnect, force a replicate event.
    ns_pubsub:subscribe_link(
      ns_node_disco_events,
      fun ({ns_node_disco_events, _Old, _New}, _) ->
              cb_generic_replication_srv:force_update(Self)
      end,
      empty),
    Self ! replicate_newnodes_docs,

    %% Explicitly ask all available nodes to send their documents to us
    [{ServerName, N} ! replicate_newnodes_docs ||
        N <- Mod:get_remote_nodes(ModState)],

    {ok, #state{module=Mod, module_state=ModState, local_doc_infos=DocInfos,
                server_name=ServerName}}.


handle_call({interactive_update, #doc{id=Id}=Doc}, _From, State) ->
    #state{module=Mod, module_state=ModState, local_doc_infos=DocInfos}=State,
    Rand = crypto:rand_uniform(0, 16#100000000),
    RandBin = <<Rand:32/integer>>,
    case proplists:get_value(Id, DocInfos) of
        undefined ->
            NewRev = {1, RandBin};
        {Pos, _DiskRev} ->
            NewRev = {Pos + 1, RandBin}
    end,
    NewDoc = Doc#doc{rev=NewRev},
    {ok, Db} = Mod:open_local_db(ModState),
    ok = couch_db:update_doc(Db, NewDoc),
    ok = couch_db:close(Db),
    replicate_change(State, NewDoc),
    DocInfos2 = lists:keystore(Id, 1, DocInfos, {Id,NewRev}),
    {reply, ok, State#state{local_doc_infos=DocInfos2}}.


handle_cast({replicated_update, #doc{id=Id, rev=Rev}=Doc}, State) ->
    %% this is replicated from another node in the cluster. We only accept it
    %% if it doesn't exist or the rev is higher than what we have.
    #state{module=Mod, module_state=ModState, local_doc_infos=DocInfos} =
        State,
    case proplists:get_value(Id, DocInfos) of
        undefined ->
            Proceed = true;
        DiskRev when Rev > DiskRev ->
            Proceed = true;
        _ ->
            Proceed = false
    end,
    if Proceed ->
            {ok, Db} = Mod:open_local_db(ModState),
            ok = couch_db:update_doc(Db, Doc),
            ok = couch_db:close(Db),
            DocInfos2 = lists:keyreplace(Id, 1, DocInfos, {Id,Rev});
       true ->
            DocInfos2 = DocInfos
    end,
    {noreply, State#state{local_doc_infos=DocInfos2}}.


handle_info({'DOWN', _Ref, _Type, {Server, RemoteNode}, Error},
            #state{remote_nodes = RemoteNodes} = State) ->
    ?log_warning("Remote server node ~p process down: ~p",
                 [{Server, RemoteNode}, Error]),
    {noreply, State#state{remote_nodes=RemoteNodes -- [RemoteNode]}};
handle_info(replicate_newnodes_docs, State) ->
    {noreply, replicate_newnodes_docs(State)}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


replicate_newnodes_docs(State) ->
    #state{remote_nodes=OldNodes, module=Mod, module_state=ModState,
           server_name=ServerName} = State,
    AllNodes = Mod:get_remote_nodes(ModState),
    NewNodes = AllNodes -- OldNodes,
    case NewNodes of
        [] ->
            ok;
        _ ->
            [monitor(process, {ServerName, Node}) || Node <- NewNodes],
            {ok, Db} = Mod:open_local_db(ModState),
            {ok, Docs} = Mod:load_local_docs(Db, ModState),
            [replicate_change_to_node(ServerName, S, D)
                                      || S <- NewNodes, D <- Docs],
            ok = couch_db:close(Db)
    end,
    State#state{remote_nodes=AllNodes}.


replicate_change(#state{remote_nodes=Nodes,
                        server_name=ServerName}, Doc) ->
    [replicate_change_to_node(ServerName, Node, Doc) || Node <- Nodes].


replicate_change_to_node(ServerName, Node, Doc) ->
    gen_server:cast({ServerName, Node}, {replicated_update, Doc}).

